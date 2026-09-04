#!/usr/bin/env bash
# Differential sweep: reni vs libonig over all code points for POSIX-style props.
# Exit 0 only when every compared pattern has identical match sets.
#
# Oniguruma's final release, 6.9.10, carries Unicode 16.0.0 tables, while
# reni follows the UCD release of its unicodedb dependency (UnicodeDataVersion
# in reni/unicode_utils.nim).  Against the system libonig every code point
# assigned or reclassified since 16.0.0 shows up as a difference.  For an
# exact comparison build a reference Oniguruma on reni's UCD release with
# tools/build_onig_reference.sh and point ONIG_PREFIX at it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

onig_bin="$root/tools/diff_posix_props_onig"
reni_bin="$root/tools/diff_posix_props_reni"

reni_ucd=$(sed -n 's/^  UnicodeDataVersion\* = "\(.*\)"/\1/p' reni/unicode_utils.nim)
if [[ -n "${ONIG_PREFIX:-}" ]]; then
  onig_cflags="-I$ONIG_PREFIX/include"
  onig_libs="-L$ONIG_PREFIX/lib -lonig -Wl,-rpath,$ONIG_PREFIX/lib"
  onig_ucd=$(cat "$ONIG_PREFIX/UCD_VERSION" 2>/dev/null || echo unknown)
  echo "reni: UCD $reni_ucd; reference: Oniguruma at $ONIG_PREFIX, UCD $onig_ucd"
else
  onig_cflags=$(onig-config --cflags)
  onig_libs=$(onig-config --libs)
  echo "reni: UCD $reni_ucd; reference: system Oniguruma $(onig-config --version) (UCD 16.0.0 in 6.9.10)"
fi

cc -O2 tools/diff_posix_props_onig.c $onig_cflags $onig_libs -o "$onig_bin"
# nimble picks up the local package; plain `nim c` may use a stale install.
nimble --silent c -d:release --hints:off --out:"$reni_bin" tools/diff_posix_props_reni.nim

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

patterns=(
  '[[:alpha:]]'
  '\p{Alpha}'
  '[[:alnum:]]'
  '\p{Alnum}'
  '[[:graph:]]'
  '\p{Graph}'
  '[[:print:]]'
  '\p{Print}'
  '[[:blank:]]'
  '\p{Blank}'
  '\w'
  '\p{Word}'
  '[[:word:]]'
  # Inside [...] Oniguruma drops the Latin-1 ctype extras that bare \w keeps.
  '[\w]'
  '[\p{Word}]'
  '[\W]'
  '[[:upper:]]'
  '\p{Upper}'
  '[[:lower:]]'
  '\p{Lower}'
  '[[:punct:]]'
  '\p{Punct}'
  # ASCII-restricted modes: (?P) for POSIX brackets, (?W) for \w.
  '(?P)[[:alpha:]]'
  '(?P)[[:alnum:]]'
  '(?P)[[:blank:]]'
  '(?P)[[:graph:]]'
  '(?P)[[:print:]]'
  '(?P)[[:punct:]]'
  '(?P)\p{Blank}'
  '(?P)\w'
  '(?W)\w'
  # (?W) is WORD-only in Oniguruma: it must not narrow alpha/alnum.
  '(?W)[[:alpha:]]'
  '(?W)[[:alnum:]]'
  # (?P) has to reach \w/\d/\s inside a character class too.
  '(?P)[\w]'
  '(?P)[\d]'
  '(?P)[\s]'
  # \p{Punct} is a category and ignores (?P); \p{PosixPunct} is a ctype.
  '(?P)\p{Punct}'
  '(?P)\p{^Punct}'
  '\p{PosixPunct}'
  '(?P)\p{PosixPunct}'
)

fail=0
for pat in "${patterns[@]}"; do
  safe=${pat//[^A-Za-z0-9]/_}
  echo "== $pat"
  # Most \p{Posix*} aliases are reni extensions libonig rejects; under
  # `set -e` a bare call would abort the sweep instead of skipping the pattern.
  if ! "$onig_bin" "$pat" >"$tmpdir/onig_$safe.txt" 2>"$tmpdir/err_$safe.txt"; then
    echo "SKIP ($pat): onig rejects it: $(head -1 "$tmpdir/err_$safe.txt")"
    continue
  fi
  "$reni_bin" "$pat" >"$tmpdir/reni_$safe.txt"
  if ! diff -u "$tmpdir/onig_$safe.txt" "$tmpdir/reni_$safe.txt" >"$tmpdir/diff_$safe.txt"; then
    echo "DIFFERS: $pat"
    # Count only added/removed code-point lines
    only_onig=$(grep -c '^-[0-9A-F]' "$tmpdir/diff_$safe.txt" || true)
    only_reni=$(grep -c '^+[0-9A-F]' "$tmpdir/diff_$safe.txt" || true)
    echo "  only in onig: $only_onig  only in reni: $only_reni"
    head -40 "$tmpdir/diff_$safe.txt"
    fail=1
  else
    echo "OK ($pat): $(wc -l <"$tmpdir/onig_$safe.txt") code points"
  fi
done

exit "$fail"
