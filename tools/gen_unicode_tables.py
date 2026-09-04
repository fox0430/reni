#!/usr/bin/env python3
"""Regenerate the UCD-derived tables in ``reni/unicode_utils.nim``.

Reads a Unicode Character Database directory laid out like
https://www.unicode.org/Public/<version>/ucd/ and rewrites, in place:

  UnicodeDataVersion         UCD version taken from the file headers
  UnicodeAssignedCodePoints  code points whose General_Category is not Cn
                             (extracted/DerivedGeneralCategory.txt)
  EmojiRanges                Emoji                  (emoji/emoji-data.txt)
  ExtPictRanges              Extended_Pictographic  (emoji/emoji-data.txt)
  OtherAlphabeticRanges      Other_Alphabetic       (PropList.txt)
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
import sys
import urllib.request
from pathlib import Path

UCD_FILES = (
    "PropList.txt",
    "emoji/emoji-data.txt",
    "auxiliary/GraphemeBreakProperty.txt",
    "extracted/DerivedGeneralCategory.txt",
)

# (Nim const name, UCD file, property value to collect)
TABLES = (
    ("EmojiRanges", "emoji/emoji-data.txt", "Emoji"),
    ("ExtPictRanges", "emoji/emoji-data.txt", "Extended_Pictographic"),
    ("OtherAlphabeticRanges", "PropList.txt", "Other_Alphabetic"),
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
    pat = re.compile(
        rf"^  {name}(\*?): array\[\d+, \(int32, int32\)\] = \[\n(?:    .*\n)*?  \]",
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ucd", type=Path, help="UCD directory (PropList.txt, emoji/, auxiliary/, extracted/)")
    ap.add_argument("--download", metavar="VERSION", help="fetch the needed UCD files for VERSION into the directory first")
    ap.add_argument("-o", "--output", type=Path, default=Path("reni/unicode_utils.nim"), help="Nim file to patch (default: reni/unicode_utils.nim)")
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
