#!/usr/bin/env bash
# Build a local Oniguruma 6.9.10 whose Unicode tables come from a newer UCD.
#
# Oniguruma development ended with 6.9.10 on Unicode 16.0.0, while reni
# follows the UCD release its unicodedb dependency ships.  To keep
# tools/run_diff_posix_props.sh an exact oracle, rebuild the final Oniguruma
# with its own table generators fed the UCD release reni uses
# (UnicodeDataVersion in reni/unicode_utils.nim).  Its semantics stay 6.9.10;
# only the data moves.
#
# Usage:  tools/build_onig_reference.sh <ucd-version> <prefix>
#         ONIG_PREFIX=<prefix> tools/run_diff_posix_props.sh
# e.g.    tools/build_onig_reference.sh 17.0.0 ~/.local/onig-ucd17
#
# Needs git, curl, python3, cmake, a C compiler and gperf (set GPERF to a
# gperf binary that is not on PATH).  Builds a static libonig so the sweep
# binary cannot pick up the system library at run time.
set -euo pipefail

ucd=${1:?usage: $0 <ucd-version> <prefix>}
prefix=$(realpath -m "${2:?usage: $0 <ucd-version> <prefix>}")
gperf=${GPERF:-gperf}
command -v "$gperf" >/dev/null || { echo "gperf not found (install it or set GPERF=/path/to/gperf)" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q --branch v6.9.10 --depth 1 https://github.com/kkos/oniguruma "$work/oniguruma"
cd "$work/oniguruma/src"

# The generators read the UCD files from the current directory.
for f in Blocks.txt CaseFolding.txt DerivedCoreProperties.txt PropertyAliases.txt \
    PropertyValueAliases.txt PropList.txt Scripts.txt UnicodeData.txt \
    auxiliary/GraphemeBreakProperty.txt auxiliary/WordBreakProperty.txt emoji/emoji-data.txt; do
  curl -sSf -o "$(basename "$f")" "https://www.unicode.org/Public/$ucd/ucd/$f"
done

# emoji-data.txt 17.0 states its version as "# Version: 17.0"; the 6.9.10
# generator only knows the older "Emoji Version 16.0" wording.
sed -i 's|EMOJI_VERSION_REG   = re.compile("(?i)#.+Version\\s+(\\d+)\\.(\\d+)")|EMOJI_VERSION_REG   = re.compile("(?i)#.+Version:?\\s+(\\d+)\\.(\\d+)")|' \
  make_unicode_property_data.py
grep -q 'Version:?' make_unicode_property_data.py || { echo "failed to patch EMOJI_VERSION_REG" >&2; exit 1; }

# The upstream scripts call a bare "gperf" and always exit 0, so probe the
# generator that can fail on a header change and check every output exists.
PATH="$(dirname "$(command -v "$gperf")"):$PATH"
export PYTHONWARNINGS=ignore
python3 make_unicode_property_data.py >/dev/null
for s in make_unicode_property.sh make_unicode_wb.sh make_unicode_egcb.sh make_unicode_fold.sh; do
  sh "$s" >/dev/null
done
for f in unicode_property_data.c unicode_property_data_posix.c unicode_wb_data.c     unicode_egcb_data.c unicode_fold_data.c unicode_fold1_key.c unicode_fold2_key.c     unicode_fold3_key.c unicode_unfold_key.c; do
  test -s "$f" || { echo "generator left $f empty" >&2; exit 1; }
done

test "$(wc -c <unicode_property_data.c)" -gt 100000 || { echo "unicode_property_data.c looks truncated" >&2; exit 1; }

# The upstream gperf_fold_key_conv.py and gperf_unfold_key_conv.py rewrite the
# lookup gperf generates to take an OnigCodePoint array, and for the fold keys
# to return an int index rather than a pointer.  Both were written against an
# older gperf and have no rule for two lines newer versions emit:
#
#   (void) len;              silences the parameter the rewrite just removed
#   return (short int *) 0;  the not-found tail, now cast to the old type
#
# The first names an identifier that no longer exists and the second returns a
# pointer from a function the rewrite made return int, so the key files do not
# compile (seen with gperf 3.3).  Fix them the way the conv scripts fix the
# spellings they do recognise, and fail loudly if the shape changes again.
key_files="unicode_fold1_key.c unicode_fold2_key.c unicode_fold3_key.c unicode_unfold_key.c"
fold_files="unicode_fold1_key.c unicode_fold2_key.c unicode_fold3_key.c"
# shellcheck disable=SC2086
sed -i '/^[[:space:]]*(void)[[:space:]]*len;[[:space:]]*$/d' $key_files
# shellcheck disable=SC2086
sed -i 's|^\([[:space:]]*\)return (short int \*) 0;$|\1return -1;|' $fold_files
# shellcheck disable=SC2086
if grep -nE '\blen\b|\(short int \*\) 0' $key_files; then
  echo "gperf output changed shape; the key files need a new fixup" >&2
  exit 1
fi

cd "$work/oniguruma"
cmake -Wno-dev -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
cmake --install build >/dev/null
echo "$ucd" >"$prefix/UCD_VERSION"
echo "installed Oniguruma 6.9.10 with UCD $ucd into $prefix"
echo "run: ONIG_PREFIX=$prefix tools/run_diff_posix_props.sh"
