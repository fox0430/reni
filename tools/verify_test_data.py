#!/usr/bin/env python3
"""Comprehensive verification of generated test JSON data.

Checks:
1. Structural integrity (all required fields present)
2. Hex encoding validity (even length, valid hex chars)
3. Cross-reference with source files (test counts, line numbers)
4. Subject/pattern anomalies (suspicious content that suggests parse errors)
5. Capture group consistency
6. Byte-level sanity checks
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path

ISSUES = []

def issue(severity, msg):
    ISSUES.append((severity, msg))
    if severity == "ERROR":
        print(f"  !! {msg}")
    else:
        print(f"  ?  {msg}")

def valid_hex(s):
    return len(s) % 2 == 0 and all(c in "0123456789ABCDEFabcdef" for c in s)

def from_hex(s):
    return bytes.fromhex(s)

def verify_oniguruma(json_path, c_path, backward=False):
    print(f"\n=== {json_path.name} vs {c_path.name} {'(backward)' if backward else ''} ===")
    d = json.load(open(json_path))
    tests = d["tests"]
    print(f"  Tests: {d['count']}")
    assert len(tests) == d["count"], "count mismatch"

    # Count macros in C source
    c_lines = open(c_path).readlines()
    c_x2 = sum(1 for l in c_lines if l.strip().startswith("x2("))
    c_x3 = sum(1 for l in c_lines if l.strip().startswith("x3("))
    c_n = sum(1 for l in c_lines if l.strip().startswith("n("))
    c_e = sum(1 for l in c_lines if l.strip().startswith("e("))
    c_total = c_x2 + c_x3 + c_n + c_e

    j_counts = Counter(t["kind"] for t in tests)
    print(f"  C source: x2={c_x2} x3={c_x3} n={c_n} e={c_e} total={c_total}")
    print(f"  JSON:     x2={j_counts.get('x2',0)} x3={j_counts.get('x3',0)} "
          f"n={j_counts.get('n',0)} e={j_counts.get('e',0)} total={len(tests)}")

    if c_total != len(tests):
        issue("ERROR", f"Test count mismatch: C={c_total} JSON={len(tests)}")

    # Structural checks
    for i, t in enumerate(tests):
        # Required fields
        for f in ["kind", "pattern", "subject", "line"]:
            if f not in t:
                issue("ERROR", f"Test {i}: missing field '{f}'")
                continue

        # Hex validity
        if not valid_hex(t["pattern"]):
            issue("ERROR", f"Test {i} L{t['line']}: invalid hex in pattern: {t['pattern'][:20]}")
        if not valid_hex(t["subject"]):
            issue("ERROR", f"Test {i} L{t['line']}: invalid hex in subject: {t['subject'][:20]}")

        # Kind-specific checks
        if t["kind"] == "x2":
            for f in ["from", "to"]:
                if f not in t:
                    issue("ERROR", f"Test {i} L{t['line']}: x2 missing '{f}'")
        elif t["kind"] == "x3":
            for f in ["from", "to", "mem"]:
                if f not in t:
                    issue("ERROR", f"Test {i} L{t['line']}: x3 missing '{f}'")
        elif t["kind"] == "e":
            if "error" not in t:
                issue("ERROR", f"Test {i} L{t['line']}: e missing 'error'")
            elif not t["error"].startswith("ONIGERR_"):
                issue("WARN", f"Test {i} L{t['line']}: unusual error name: {t['error']}")

    # Line number checks: should be within C file range
    max_c_line = len(c_lines)
    for t in tests:
        if t["line"] < 1 or t["line"] > max_c_line:
            issue("ERROR", f"Test L{t['line']}: line number out of range (file has {max_c_line} lines)")

    # Check for suspicious patterns (literal \= or other parse artifacts)
    for i, t in enumerate(tests):
        pat = from_hex(t["pattern"])
        subj = from_hex(t["subject"])
        if b"\\=" in subj:
            issue("WARN", f"Test {i} L{t['line']}: subject contains literal '\\='")

    # Byte distribution sanity: patterns should not contain null bytes unless intended
    null_pats = sum(1 for t in tests if b"\x00" in from_hex(t["pattern"]))
    null_subjs = sum(1 for t in tests if b"\x00" in from_hex(t["subject"]))
    print(f"  Null bytes: {null_pats} patterns, {null_subjs} subjects")

    # Spot check: verify a few line numbers against C source
    spot_checks = 0
    for t in tests[:20]:
        line_idx = t["line"] - 1
        if 0 <= line_idx < len(c_lines):
            c_line = c_lines[line_idx].strip()
            if c_line.startswith(t["kind"] + "("):
                spot_checks += 1
    print(f"  Spot checks passed: {spot_checks}/20")
    if spot_checks < 15:
        issue("WARN", f"Only {spot_checks}/20 spot checks passed - line numbers may be off")


def verify_pcre2(json_path, out_path):
    print(f"\n=== {json_path.name} vs {out_path.name} ===")
    d = json.load(open(json_path))
    tests = d["tests"]
    print(f"  Tests: {d['count']}")
    assert len(tests) == d["count"], "count mismatch"

    kinds = Counter(t["kind"] for t in tests)
    print(f"  Match: {kinds.get('match',0)}, No match: {kinds.get('no_match',0)}")

    # Structural checks
    for i, t in enumerate(tests):
        for f in ["kind", "pattern", "flags", "subject", "line"]:
            if f not in t:
                issue("ERROR", f"Test {i}: missing field '{f}'")
                continue

        if not valid_hex(t["pattern"]):
            issue("ERROR", f"Test {i} L{t['line']}: invalid hex in pattern")
        if not valid_hex(t["subject"]):
            issue("ERROR", f"Test {i} L{t['line']}: invalid hex in subject")

        if t["kind"] == "match" and "groups" in t:
            for g in t["groups"]:
                if "index" not in g or "value" not in g:
                    issue("ERROR", f"Test {i} L{t['line']}: group missing index/value")
                elif not valid_hex(g["value"]):
                    issue("ERROR", f"Test {i} L{t['line']}: invalid hex in group {g['index']} value")

    # Check for \= artifacts in subjects
    eq_in_subj = sum(1 for t in tests if b"\\=" in from_hex(t["subject"]))
    if eq_in_subj > 0:
        issue("ERROR", f"{eq_in_subj} subjects contain literal '\\=' (modifier not stripped)")

    # Check for pcre2test output artifacts in subjects
    suspicious_subjs = 0
    for t in tests:
        subj = from_hex(t["subject"])
        s = subj.decode("utf-8", errors="replace")
        if s.startswith("0: ") or s.startswith("1: "):
            suspicious_subjs += 1
            if suspicious_subjs <= 3:
                pat = from_hex(t["pattern"]).decode("utf-8", errors="replace")[:30]
                issue("WARN", f"Test L{t['line']}: subject looks like capture output: '{s[:30]}' (pattern: /{pat}/)")
    if suspicious_subjs > 0:
        issue("ERROR" if suspicious_subjs > 5 else "WARN",
              f"{suspicious_subjs} subjects look like capture output lines")

    # Check capture group indices
    max_group_idx = 0
    for t in tests:
        if "groups" in t:
            for g in t["groups"]:
                max_group_idx = max(max_group_idx, g["index"])
    print(f"  Max capture group index: {max_group_idx}")

    # Check for group 0 always present in match tests with groups
    missing_group0 = 0
    for t in tests:
        if t["kind"] == "match" and "groups" in t and t["groups"]:
            indices = {g["index"] for g in t["groups"]}
            if 0 not in indices:
                missing_group0 += 1
    if missing_group0 > 0:
        issue("WARN", f"{missing_group0} match tests with groups but missing group 0")

    # Check for empty patterns
    empty_pats = sum(1 for t in tests if t["pattern"] == "")
    if empty_pats > 0:
        issue("WARN", f"{empty_pats} tests with empty pattern")

    # Byte distribution
    null_subjs = sum(1 for t in tests if b"\x00" in from_hex(t["subject"]))
    print(f"  Null bytes in subjects: {null_subjs}")

    # Line number range check
    out_lines = open(out_path, encoding="latin-1").readlines()
    max_line = len(out_lines)
    out_of_range = sum(1 for t in tests if t["line"] < 1 or t["line"] > max_line)
    if out_of_range > 0:
        issue("ERROR", f"{out_of_range} tests with line numbers out of range")

    # Flag analysis
    all_flags = Counter()
    for t in tests:
        if t["flags"]:
            for part in t["flags"].split(","):
                all_flags[part.strip()] += 1
    print(f"  Flags used: {dict(all_flags.most_common(15))}")


def main():
    base = Path(".")

    # Oniguruma
    verify_oniguruma(
        base / "tests/data/oniguruma_utf8.json",
        base / "vendor/oniguruma/test/test_utf8.c",
    )
    verify_oniguruma(
        base / "tests/data/oniguruma_back.json",
        base / "vendor/oniguruma/test/test_back.c",
        backward=True,
    )

    # PCRE2
    for f in [1, 2, 4, 7]:
        verify_pcre2(
            base / f"tests/data/pcre2_test{f}.json",
            base / f"vendor/pcre2/testdata/testoutput{f}",
        )

    # Summary
    errors = [i for i in ISSUES if i[0] == "ERROR"]
    warns = [i for i in ISSUES if i[0] == "WARN"]
    print(f"\n{'='*60}")
    print(f"TOTAL: {len(errors)} errors, {len(warns)} warnings")
    if errors:
        print("\nERRORS:")
        for _, msg in errors:
            print(f"  - {msg}")
    if warns:
        print("\nWARNINGS:")
        for _, msg in warns:
            print(f"  - {msg}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
