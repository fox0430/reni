#!/usr/bin/env python3
"""Regenerate the UCD-derived tables in ``reni/unicode_utils.nim``,
``reni/unicode_props_data.nim`` and ``tests/unicode_sets_data.nim``.

Reads a Unicode Character Database directory laid out like
https://www.unicode.org/Public/<version>/ucd/ and writes whole:

  reni/unicode_props_data.nim  every ``\\p{...}`` name Oniguruma 6.9.10 knows,
                               read by the rules of its
                               src/make_unicode_property_data.py, with the
                               ranges of the blocks and binary properties
                               reni does not read from ``unicodedb``
  tests/unicode_sets_data.nim  the ranges of the sets it does (the scripts and
                               ``UNICODEDB_SETS``), to check ``unicodedb`` by

and rewrites, in place in ``reni/unicode_utils.nim``:

  UnicodeDataVersion         UCD version taken from the file headers
  UnicodeAssignedCodePoints  code points whose General_Category is not Cn
                             (extracted/DerivedGeneralCategory.txt)
  ControlRanges              Grapheme_Cluster_Break=Control
  ExtendRanges               Grapheme_Cluster_Break=Extend
  PrependRanges              Grapheme_Cluster_Break=Prepend
  SpacingMarkRanges          Grapheme_Cluster_Break=SpacingMark
  HangulLRanges              Grapheme_Cluster_Break=L
  HangulVRanges              Grapheme_Cluster_Break=V
  HangulTRanges              Grapheme_Cluster_Break=T
                             (all seven from auxiliary/GraphemeBreakProperty.txt)

The UCD version must be the one the ``unicodedb`` dependency's own tables
were built from (see the bound in reni.nimble); ``UnicodeAssignedCodePoints``
is the fingerprint tests/test_unicode_data.nim uses to detect drift.

Examples::

    # Download the needed files for one UCD release, then regenerate.
    python3 tools/gen_unicode_tables.py --download 17.0.0 /tmp/ucd-17.0.0

    # Regenerate from an existing UCD checkout.
    python3 tools/gen_unicode_tables.py /path/to/ucd
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

UCD_FILES = (
    "PropList.txt",
    "emoji/emoji-data.txt",
    "auxiliary/GraphemeBreakProperty.txt",
    "extracted/DerivedGeneralCategory.txt",
    "DerivedCoreProperties.txt",
    "Scripts.txt",
    "Blocks.txt",
    "PropertyAliases.txt",
    "PropertyValueAliases.txt",
)

# (Nim const name, UCD file, property value to collect)
TABLES = (
    ("ControlRanges", "auxiliary/GraphemeBreakProperty.txt", "Control"),
    ("ExtendRanges", "auxiliary/GraphemeBreakProperty.txt", "Extend"),
    ("PrependRanges", "auxiliary/GraphemeBreakProperty.txt", "Prepend"),
    ("SpacingMarkRanges", "auxiliary/GraphemeBreakProperty.txt", "SpacingMark"),
    ("HangulLRanges", "auxiliary/GraphemeBreakProperty.txt", "L"),
    ("HangulVRanges", "auxiliary/GraphemeBreakProperty.txt", "V"),
    ("HangulTRanges", "auxiliary/GraphemeBreakProperty.txt", "T"),
)

MAX_CODE_POINT = 0x10FFFF

Range = tuple[int, int]


def download(version: str, dest: Path) -> None:
    base = f"https://www.unicode.org/Public/{version}/ucd/"
    for rel in UCD_FILES:
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        print(f"fetching {base}{rel}")
        with urllib.request.urlopen(base + rel) as resp:
            target.write_bytes(resp.read())


def data_lines(path: Path):
    """Yield (code point range, fields[1:]) for every data line in a UCD file."""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        cps = fields[0]
        if ".." in cps:
            lo, hi = cps.split("..")
            yield (int(lo, 16), int(hi, 16)), fields[1:]
        else:
            cp = int(cps, 16)
            yield (cp, cp), fields[1:]


def merge(ranges: list[Range]) -> list[Range]:
    out: list[Range] = []
    for lo, hi in sorted(ranges):
        if out and out[-1][1] + 1 >= lo:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def collect(path: Path, value: str) -> list[Range]:
    return merge([rng for rng, fields in data_lines(path) if fields and fields[0] == value])


def assigned_count(derived_gc: Path) -> int:
    cn = sum(hi - lo + 1 for lo, hi in collect(derived_gc, "Cn"))
    return MAX_CODE_POINT + 1 - cn


def ucd_version(ucd: Path) -> str:
    """Read the version from the file headers and insist they all agree."""
    seen: dict[str, str] = {}
    for rel in UCD_FILES:
        head = (ucd / rel).read_text(encoding="utf-8").splitlines()[:20]
        text = "\n".join(head)
        m = re.search(r"-(\d+\.\d+\.\d+)\.txt", text) or re.search(r"Version:\s*(\d+\.\d+(?:\.\d+)?)", text)
        if not m:
            sys.exit(f"{rel}: cannot find a UCD version in its header")
        seen[rel] = m.group(1)
    # emoji-data.txt carries only major.minor.
    majors = {tuple(v.split(".")[:2]) for v in seen.values()}
    if len(majors) != 1:
        sys.exit("UCD files disagree on their version: " + ", ".join(f"{k}={v}" for k, v in seen.items()))
    full = [v for v in seen.values() if v.count(".") == 2]
    return full[0] if full else next(iter(seen.values())) + ".0"


def format_table(name: str, export: str, ranges: list[Range]) -> str:
    lines = [f"  {name}{export}: array[{len(ranges)}, (int32, int32)] = ["]
    lines += [f"    (0x{lo:04X}'i32, 0x{hi:04X}'i32)," for lo, hi in ranges]
    lines.append("  ]")
    return "\n".join(lines)


def replace_table(text: str, name: str, ranges: list[Range]) -> str:
    # nph folds a short table onto one line after the ``=``; format_table
    # writes the long form, and ``main`` runs nph over the result.
    pat = re.compile(
        rf"^  {name}(\*?): array\[\d+, \(int32, int32\)\] =(?: \[\n(?:    .*\n)*?  \]|\n    \[[^\]]*\])",
        re.M,
    )
    m = pat.search(text)
    if not m:
        sys.exit(f"{name} const not found")
    return text[: m.start()] + format_table(name, m.group(1), ranges) + text[m.end():]


def replace_scalar(text: str, name: str, value: str) -> str:
    pat = re.compile(rf"^(  {name}\* = ).*$", re.M)
    if not pat.search(text):
        sys.exit(f"{name} const not found")
    return pat.sub(lambda m: m.group(1) + value, text, count=1)


# Oniguruma's POSIX names (first in its table) and general categories
# (UnicodeData.txt's, plus Cn and LC).  reni reads these, Any and Assigned from
# ``unicodedb`` (``resolvePropBody``), so only their names go into the table;
# NEWLINE is a set like the rest.
ONIG_POSIX = (
    "NEWLINE", "Alpha", "Blank", "Cntrl", "Digit", "Graph", "Lower", "Print",
    "PosixPunct", "Space", "Upper", "XDigit", "Word", "Alnum", "ASCII",
)
ONIG_CATEGORIES = (
    "C", "Cc", "Cf", "Cn", "Co", "Cs", "L", "LC", "Ll", "Lm", "Lo", "Lt", "Lu",
    "M", "Mc", "Me", "Mn", "N", "Nd", "Nl", "No", "P", "Pc", "Pd", "Pe", "Pf",
    "Pi", "Po", "Ps", "S", "Sc", "Sk", "Sm", "So", "Z", "Zl", "Zp", "Zs",
)
BUILTIN = set(ONIG_POSIX[1:]) | set(ONIG_CATEGORIES) | {"Any", "Assigned"}
# The binary properties with the members of a POSIX name.  reni matches them
# with that name's matcher, without its ASCII restriction: ``unicodedb``
# answers in fewer loads than a search of their hundreds of ranges.
UNICODEDB_SETS = {"Alphabetic", "Uppercase", "Lowercase"}

# The patterns make_unicode_property_data.py reads the files with, quirks
# included: PR_LINE keeps only the first word after the ``;``, so the three
# ``InCB`` values of DerivedCoreProperties.txt make one set, and PVA_LINE reads
# ``L&`` as ``L``.
PR_LINE = re.compile(r"([0-9A-Fa-f]+)(?:..([0-9A-Fa-f]+))?\s*;\s*(\w+)")
PA_LINE = re.compile(r"(\w+)\s*;\s*(\w+)")
PVA_LINE = re.compile(r"(sc|gc)\s*;\s*(\w+)\s*;\s*(\w+)(?:\s*;\s*(\w+))?")
BL_LINE = re.compile(r"([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\s*;\s*(.*)")


def onig_normalize(name: str) -> str:
    """The key Oniguruma stores a name under; its lookup also drops ``-``."""
    return re.sub(r"[ _]", "", name).lower()


def inverse(ranges: list[Range]) -> list[Range]:
    """The code points ``ranges`` leave out, as Oniguruma's ``inverse_ranges``
    finds them: when the last range ends at U+10FFFE, U+10FFFF is left out
    too."""
    out: list[Range] = []
    nxt = 0
    for lo, hi in merge(ranges):
        if lo > nxt:
            out.append((nxt, lo - 1))
        nxt = hi + 1
    if nxt < MAX_CODE_POINT:
        out.append((nxt, MAX_CODE_POINT))
    return out


def onig_merge(ranges: list[Range]) -> list[Range]:
    """Oniguruma's ``normalize_ranges`` without sorting: a range that starts at
    or below the end of the last one is folded into it.  That is ``merge`` for
    a sorted list, but ``InCB`` lists its Linker, Consonant and Extend ranges
    one value after another, so every range below the last Linker folds into
    it: Oniguruma's ``\\p{InCB}`` holds the Linkers and the Consonant and
    Extend code points past the last one.  That Linker moves between UCD
    versions (U+0D4D in 16, U+11F42 in 17), so the set changes far more than
    the data does: 6 Linkers + 1,711 in 16, 20 + 700 in 17.  The result is
    sorted either way."""
    out: list[Range] = []
    for lo, hi in ranges:
        if out and out[-1][1] >= lo - 1:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def onig_sets(path: Path) -> dict[str, list[Range]]:
    sets: dict[str, list[Range]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = PR_LINE.match(line.strip())
        if m:
            lo = int(m.group(1), 16)
            hi = int(m.group(2), 16) if m.group(2) else lo
            sets.setdefault(m.group(3), []).append((lo, hi))
    return {k: onig_merge(v) for k, v in sets.items()}


def add_name(names: dict[str, str], name: str) -> None:
    """Enter ``name`` under its key.  Oniguruma's gperf table cannot hold a key
    twice either, so a second name for one key stops the run rather than hide
    the first."""
    key = onig_normalize(name)
    if key in names:
        sys.exit(f"{name} and {names[key]} share the key {key}")
    names[key] = name


def onig_properties(ucd: Path) -> tuple[dict[str, list[Range]], dict[str, str], set[str]]:
    """The sets reni matches by ranges, every name to the set it names, and
    which of the sets are scripts."""
    sets: dict[str, list[Range]] = {"NEWLINE": [(0x0A, 0x0A)]}
    sets.update(onig_sets(ucd / "DerivedCoreProperties.txt"))
    scripts = onig_sets(ucd / "Scripts.txt")
    sets.update(scripts)
    sets["Unknown"] = inverse([r for rs in scripts.values() for r in rs])
    script_names = set(scripts) | {"Unknown"}
    sets.update(onig_sets(ucd / "PropList.txt"))
    sets.update(onig_sets(ucd / "emoji/emoji-data.txt"))

    names: dict[str, str] = {}
    for name in list(ONIG_POSIX) + sorted(BUILTIN.union(sets).difference(ONIG_POSIX)):
        add_name(names, name)

    aliases: dict[str, str] = {}
    for line in (ucd / "PropertyAliases.txt").read_text(encoding="utf-8").splitlines():
        m = PA_LINE.match(line.strip())
        if m and m.group(1) != m.group(2):
            aliases[m.group(1)] = m.group(2)
    for line in (ucd / "PropertyValueAliases.txt").read_text(encoding="utf-8").splitlines():
        m = PVA_LINE.match(line.strip())
        if not m:
            continue
        cat, x2, x3, x4 = m.groups()
        # A script's long name is the property; a category's short one is.
        canon, others = (x3, (x2, x4)) if cat == "sc" else (x2, (x3, x4))
        for other in others:
            if other and other != canon:
                aliases[other] = canon

    blocks: list[Range] = []
    for line in (ucd / "Blocks.txt").read_text(encoding="utf-8").splitlines():
        m = BL_LINE.match(line.strip())
        if m:
            rng = (int(m.group(1), 16), int(m.group(2), 16))
            name = "In_" + re.sub(r"[- ]+", "_", m.group(3))
            sets[name] = [rng]
            add_name(names, name)
            blocks.append(rng)
    sets["In_No_Block"] = inverse(blocks)
    add_name(names, "In_No_Block")

    # An alias never replaces a name, and names nothing Oniguruma lacks.  Two
    # aliases under one key must name the same set, as in add_name.
    entered: dict[str, tuple[str, str]] = {}
    for alias, target in aliases.items():
        key, name = onig_normalize(alias), names.get(onig_normalize(target))
        if key in names or name is None:
            continue
        if key in entered and entered[key][1] != name:
            sys.exit(f"{alias} and {entered[key][0]} share the key {key}")
        entered[key] = (alias, name)
    names.update((key, name) for key, (_, name) in entered.items())
    return sets, names, script_names


def format_ranges(ranges: list[Range]) -> list[str]:
    return [f"    (0x{lo:04X}'i32, 0x{hi:04X}'i32)," for lo, hi in ranges]


def script_code_point(name: str, ranges: list[Range]) -> int:
    """The code point reni asks ``unicodedb`` the script of: the script's first.
    Unknown's first is only unassigned, and a later UCD may give it a script;
    U+10FFFF is a noncharacter, which stays Unknown for good."""
    if name != "Unknown":
        return ranges[0][0]
    if ranges[-1][1] != MAX_CODE_POINT:
        sys.exit("Unknown does not hold U+10FFFF")
    return MAX_CODE_POINT


def format_props_module(
    version: str, sets: dict[str, list[Range]], names: dict[str, str], scripts: set[str]
) -> str:
    order = sorted(sets.keys() - scripts - UNICODEDB_SETS, key=onig_normalize)
    index = {name: i for i, name in enumerate(order)}
    ranges: list[str] = []
    slices: list[str] = []
    for name in order:
        first = len(ranges)
        ranges += format_ranges(sets[name])
        slices.append(f"    ({first}'i32, {len(ranges)}'i32),")
    entries = []
    for key in sorted(names):
        canon = names[key]
        target = index.get(canon, -1) if canon not in BUILTIN else -1
        script = script_code_point(canon, sets[canon]) if canon in scripts else -1
        entries.append(f'    ("{key}", "{onig_normalize(canon)}", {target}\'i16, {script}\'i32),')
    return "\n".join(
        [
            f"## Generated by tools/gen_unicode_tables.py from UCD {version}; do not edit.",
            "##",
            "## Every ``\\p{...}`` name Oniguruma 6.9.10 knows, keyed as it keys them:",
            "## lower case, without ``_`` or `` ``.  [PropertyNames] maps a key to its",
            "## property's key, to its set in [PropertySets] (-1 for what reni matches",
            "## through ``unicodedb``) and, for a script, to the code point reni looks",
            "## it up by (-1 otherwise).  A set is the slice ``first ..< last`` of",
            "## [PropertyRanges].",
            "",
            "const",
            "  # UCD release the tables were built from.",
            f'  PropertyDataVersion* = "{version}"',
            f"  PropertyRanges*: array[{len(ranges)}, (int32, int32)] = [",
            *ranges,
            "  ]",
            f"  PropertySets*: array[{len(slices)}, tuple[first, last: int32]] = [",
            *slices,
            "  ]",
            f"  PropertyNames*: array[{len(entries)}, tuple[key, canon: string, set: int16, script: int32]] = [",
            *entries,
            "  ]",
            "",
        ]
    )


def format_sets_module(version: str, sets: dict[str, list[Range]], scripts: set[str]) -> str:
    ranges: list[str] = []
    slices: list[str] = []
    for name in sorted(scripts | UNICODEDB_SETS, key=onig_normalize):
        first = len(ranges)
        ranges += format_ranges(sets[name])
        script = "true" if name in scripts else "false"
        slices.append(f'    ("{name}", {first}\'i32, {len(ranges)}\'i32, {script}),')
    return "\n".join(
        [
            f"## Generated by tools/gen_unicode_tables.py from UCD {version}; do not edit.",
            "##",
            "## The ranges of the sets reni matches through ``unicodedb``: every script",
            "## of Scripts.txt, Unknown (the code points it leaves out), and Alphabetic,",
            "## Uppercase and Lowercase.  test_unicode_data checks that ``unicodedb``",
            "## agrees.  A set is the slice ``first ..< last`` of [SetRanges].",
            "",
            "const",
            "  # UCD release the tables were built from.",
            f'  SetDataVersion* = "{version}"',
            f"  SetRanges*: array[{len(ranges)}, (int32, int32)] = [",
            *ranges,
            "  ]",
            f"  Sets*: array[{len(slices)}, tuple[name: string, first, last: int32, script: bool]] = [",
            *slices,
            "  ]",
            "",
        ]
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ucd", type=Path, help="UCD directory (PropList.txt, emoji/, auxiliary/, extracted/)")
    ap.add_argument("--download", metavar="VERSION", help="fetch the needed UCD files for VERSION into the directory first")
    ap.add_argument("-o", "--output", type=Path, default=Path("reni/unicode_utils.nim"), help="Nim file to patch (default: reni/unicode_utils.nim)")
    ap.add_argument(
        "--props-output",
        type=Path,
        default=Path("reni/unicode_props_data.nim"),
        help="Nim module to write (default: reni/unicode_props_data.nim)",
    )
    ap.add_argument(
        "--sets-output",
        type=Path,
        default=Path("tests/unicode_sets_data.nim"),
        help="Nim module of the unicodedb sets' ranges to write (default: tests/unicode_sets_data.nim)",
    )
    args = ap.parse_args()

    if args.download:
        download(args.download, args.ucd)
    missing = [rel for rel in UCD_FILES if not (args.ucd / rel).is_file()]
    if missing:
        sys.exit("missing UCD files: " + ", ".join(missing) + " (try --download VERSION)")

    version = ucd_version(args.ucd)
    text = args.output.read_text(encoding="utf-8")
    text = replace_scalar(text, "UnicodeDataVersion", f'"{version}"')
    assigned = assigned_count(args.ucd / "extracted/DerivedGeneralCategory.txt")
    text = replace_scalar(text, "UnicodeAssignedCodePoints", str(assigned))
    print(f"UCD {version}: {assigned} assigned code points")
    for name, rel, value in TABLES:
        ranges = collect(args.ucd / rel, value)
        text = replace_table(text, name, ranges)
        cps = sum(hi - lo + 1 for lo, hi in ranges)
        print(f"{name}: {len(ranges)} ranges, {cps} code points ({value})")
    args.output.write_text(text, encoding="utf-8")
    print(f"wrote {args.output}")
    sets, names, scripts = onig_properties(args.ucd)
    args.props_output.write_text(format_props_module(version, sets, names, scripts), encoding="utf-8")
    checked = scripts | UNICODEDB_SETS
    print(f"wrote {args.props_output}: {len(names)} names, {len(sets) - len(checked)} sets, "
          f"{sum(len(r) for n, r in sets.items() if n not in checked)} ranges")
    args.sets_output.write_text(format_sets_module(version, sets, scripts), encoding="utf-8")
    print(f"wrote {args.sets_output}: {len(checked)} sets, "
          f"{sum(len(sets[n]) for n in checked)} ranges")
    outputs = [args.output, args.props_output, args.sets_output]
    nph = shutil.which("nph")
    if nph:
        subprocess.run([nph, *map(str, outputs)], check=True)
    else:
        print("nph not found: format the three files with it before committing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
