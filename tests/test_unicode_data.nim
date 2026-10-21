import std/[unittest, unicode]
import pkg/unicodedb/[properties, scripts]
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
