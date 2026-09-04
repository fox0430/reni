#!/usr/bin/env bash
# Differential sweep: reni vs libonig over the positions the scans start at.
#
# For every concatenation of 1..MAXLEN alphabet tokens, compare where a
# forward and a backward search find their match.  This is the oracle for the
# candidate-start-position rules in reni/engine.nim: the forward scan steps
# along the `encLen` chain, the backward scan steps back with `prevCharHead`,
# and Oniguruma does the same two things -- including disagreeing with itself
# about which positions exist when the subject is not well-formed UTF-8.
#
# The default alphabet is well-formed characters, where reni owes Oniguruma an
# exact match: any difference is a bug and the script exits non-zero.
#
# Sweeping malformed input is opt-in through ALPHABET.  There Oniguruma is
# partly undefined -- it reads past the end of the subject (with a lone 0xC0 as
# the whole subject, `[^q]` reports the span 0-2), and those lines are set
# aside rather than counted.  Differences that remain are worth reading one by
# one, not gating on: a truncated sequence at the end of the subject is a
# character to Oniguruma and no character at all to `decodeAt`, so patterns
# that can match one (`\S`, `\w`, `.`) differ there by design.
#
# Usage:  tools/run_diff_scan_positions.sh [pattern ...]
#         MAXLEN=5 ALPHABET=0A,61,80,C0,C2,E0,F0 tools/run_diff_scan_positions.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Keep both small: the corpus is |alphabet|^1 + ... + |alphabet|^MAXLEN
# subjects per pattern.
maxlen=${MAXLEN:-4}
alphabet=${ALPHABET:-0A,61,30,20,C3A9,E38182,F09F9880}

onig_bin="$root/tools/diff_scan_positions_onig"
reni_bin="$root/tools/diff_scan_positions_reni"

if [[ -n "${ONIG_PREFIX:-}" ]]; then
  onig_cflags="-I$ONIG_PREFIX/include"
  onig_libs="-L$ONIG_PREFIX/lib -lonig -Wl,-rpath,$ONIG_PREFIX/lib"
else
  onig_cflags=$(onig-config --cflags)
  onig_libs=$(onig-config --libs)
fi

cc -O2 tools/diff_scan_positions_onig.c $onig_cflags $onig_libs -o "$onig_bin"
# nimble picks up the local package; plain `nim c` may use a stale install.
nimble --silent c -d:release --hints:off --out:"$reni_bin" tools/diff_scan_positions_reni.nim

if [[ $# -gt 0 ]]; then
  patterns=("$@")
else
  patterns=(
    # Plain steps: what the scan does between attempts.
    '.' '\N' '\X' '\S' '\w' '[^q]' '.+' 'a' '[a]' '(?:a|\N\N)'
    # Prefilter jumps: the first-byte hints pick the position, not the walk.
    '^.' '^[^q]' '(?m)^a' '\ba'
    # The end anchors, and the \Z jump that skips to the last newline.
    '$' '\z' '\Z' '[^q]$' '[^q]\z' '.\Z' '\N\Z' '\X\Z' '\S\Z' '\w\Z'
    '[a]\Z' 'a\Z' '..\Z' '\N{0,3}\Z'
  )
fi

echo "alphabet: $alphabet   subjects: 1..$maxlen tokens"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail=0
for pat in "${patterns[@]}"; do
  safe=${pat//[^A-Za-z0-9]/_}
  if ! "$onig_bin" "$maxlen" "$alphabet" "$pat" >"$tmpdir/onig_$safe.txt" \
      2>"$tmpdir/err_$safe.txt"; then
    echo "SKIP ($pat): onig rejects it: $(head -1 "$tmpdir/err_$safe.txt")"
    continue
  fi
  "$reni_bin" "$maxlen" "$alphabet" "$pat" >"$tmpdir/reni_$safe.txt"

  # Compare line by line, setting aside the lines where Oniguruma reports a
  # span that runs past the end of the subject.
  read -r total differ oob < <(paste -d' ' "$tmpdir/onig_$safe.txt" \
      "$tmpdir/reni_$safe.txt" | awk '
    function inside(field,   parts) {
      # field is "f=<beg>-<end>" or "f=-"
      sub(/^[fb]=/, "", field)
      if (field == "-") return 1
      split(field, parts, "-")
      return parts[2] <= length($1) / 2
    }
    {
      n++
      if (!inside($2) || !inside($3)) { oob++; next }
      if ($2 != $5 || $3 != $6) {
        differ++
        if (differ <= 5)
          print "  " $1 "  onig " $2 " " $3 "  reni " $5 " " $6 > "/dev/stderr"
      }
    }
    END { print n, differ + 0, oob + 0 }')

  skipped=""
  [[ $oob -gt 0 ]] && skipped="  [$oob skipped: onig span out of bounds]"
  if [[ $differ -gt 0 ]]; then
    echo "DIFFERS ($pat): $differ of $total subjects$skipped"
    fail=1
  else
    echo "OK ($pat): $total subjects$skipped"
  fi
done

exit "$fail"
