import std/[strutils, unittest, unicode]
import pkg/unicodedb/[casing, properties, scripts]
import reni/[types, unicode_utils, unicode_props_data]
import ./unicode_sets_data

suite "Unicode data alignment":
  test "unicodedb was built from the same UCD release as reni's tables":
    # The range tables in reni/unicode_utils.nim come from
    # tools/gen_unicode_tables.py for one UCD release (UnicodeDataVersion),
    # while categories, scripts and case folding come from unicodedb.  If the
    # two releases differ, \p{...} answers become inconsistent.  Whenever the
    # unicodedb bound in reni.nimble is raised past a UCD update, regenerate
    # the tables against that release.
    var assigned = 0
    for cp in 0 .. 0x10FFFF:
      if properties.unicodeCategory(Rune(cp)) != ctgCn:
        inc assigned
    checkpoint(
      "reni tables: UCD " & UnicodeDataVersion & " with " & $UnicodeAssignedCodePoints &
        " assigned code points; unicodedb reports " & $assigned &
        ". Regenerate with: python3 tools/gen_unicode_tables.py " &
        "--download <unicodedb's UCD version> <dir>"
    )
    check assigned == UnicodeAssignedCodePoints

  test "the property tables come from the same UCD release":
    # All three files come out of one run of tools/gen_unicode_tables.py.
    check PropertyDataVersion == UnicodeDataVersion
    check SetDataVersion == UnicodeDataVersion

  test "unicodedb's scripts are the ones Scripts.txt lists":
    # reni looks a script up in unicodedb by one of its code points: every
    # code point of its ranges must have it, and no two scripts the same id.
    var seen: seq[int32]
    for s in Sets:
      if not s.script:
        continue
      checkpoint(s.name)
      let p = resolveUnicodeProp(s.name)
      check p.kind == upScript
      check p.scriptId notin seen
      seen.add p.scriptId
      var agree = true
      for i in s.first ..< s.last:
        for cp in SetRanges[i][0] .. SetRanges[i][1]:
          if int32(unicodeScript(Rune(cp))) != p.scriptId:
            agree = false
      check agree

  test "a fold expansion's characters can stand at the bytes their masks name":
    # ``MultiCharFoldLeadMasks`` and ``MultiCharFoldNextMasks`` are derived
    # from ``caseFoldVariants`` and the lead byte's payload bits; the matcher's
    # expansion loop reads a character with ``nextCharAt`` and compares with
    # ``simpleFold``.  Ask the loop's question of every lead byte, alone and
    # followed by every run of continuation payloads, which is every character
    # ``nextCharAt`` can read.
    for (k, masks) in [(0, MultiCharFoldLeadMasks), (1, MultiCharFoldNextMasks)]:
      checkpoint("expansion character " & $k)
      var chars: array[MultiCharFolds.len, Rune]
      for i, f in MultiCharFolds:
        chars[i] = simpleFold(Rune(f.expansion[k]))
      var want: array[256, uint32]
      proc note(want: var array[256, uint32], s: openArray[char]) =
        var p = 0
        var r: Rune
        nextCharAt(s, p, r)
        let folded = simpleFold(r)
        for i, f in MultiCharFolds:
          if int32(r) == f.expansion[k] or folded == chars[i]:
            want[s[0].uint8] = want[s[0].uint8] or (1'u32 shl i)

      var buf: array[MaxCharByteLen, char]
      for b in 0 .. 255:
        let n = encLen(uint8(b))
        buf[0] = char(b)
        want.note(buf.toOpenArray(0, 0))
        if n > 1:
          for tail in 0 ..< 1 shl (6 * (n - 1)):
            for j in 1 ..< n:
              buf[j] = char(0x80 or ((tail shr (6 * (n - 1 - j))) and 0x3F))
            want.note(buf.toOpenArray(0, n - 1))
      check want == masks

  test "unicodedb's Alphabetic, Uppercase and Lowercase are the UCD's":
    # reni matches them with the matchers of Alpha, Upper and Lower.
    for s in Sets:
      if s.script:
        continue
      checkpoint(s.name)
      let p = resolveUnicodeProp(s.name)
      check p.kind != upRanges
      var agree = true
      for cp in 0'i32 .. 0x10FFFF'i32:
        let member = inRangeTable(cp, SetRanges.toOpenArray(s.first, s.last - 1))
        if matchUnicodeProp(Rune(cp), p) != member:
          agree = false
      check agree

  test "AllMultiCharFoldSources is every character with a multi-character fold":
    # Oniguruma splits a ``(?i)`` class on each of them.  The parser asks the
    # class's atoms with their simple folds, which answers as Oniguruma's
    # plain membership only while no character outside the list shares a
    # simple fold with one inside.
    var agree = true
    for cp in 0'i32 .. 0x10FFFF'i32:
      if cp >= 0xD800 and cp <= 0xDFFF:
        continue
      var n = 0
      for _ in casing.caseFold(Rune(cp)):
        inc n
      let listed = inRangeTable(cp, AllMultiCharFoldSources)
      if listed != (n > 1):
        checkpoint("U+" & toHex(cp, 4))
        agree = false
      if listed:
        for v in caseFoldVariants(Rune(cp)):
          if not inRangeTable(int32(v), AllMultiCharFoldSources):
            checkpoint(
              "U+" & toHex(int32(v), 4) & " shares a fold with U+" & toHex(cp, 4)
            )
            agree = false
    check agree
    for f in MultiCharFolds:
      check inRangeTable(f.source, AllMultiCharFoldSources)
