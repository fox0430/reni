import std/[unittest, unicode]
import pkg/unicodedb/properties
import reni/unicode_utils

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
