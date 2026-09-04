import std/[unittest, unicode]
import reni
import reni/unicode_utils

suite "POSIX property Oniguruma alignment":
  test "OtherAlphabeticRanges contains U+05B0":
    check inRangeTable(0x05B0'i32, OtherAlphabeticRanges)
    check isAlphaChar(Rune(0x05B0))
    check matchPosixClass(Rune(0x05B0), pcAlpha, false)

  test "Alpha is L ∪ Nl ∪ Other_Alphabetic":
    check search("a", re("\\p{Alpha}")).found
    check search($Rune(0x00AA), re("\\p{Alpha}")).found # Lo
    check search($Rune(0x2160), re("\\p{Alpha}")).found # Nl
    check search($Rune(0x05B0), re("\\p{Alpha}")).found # Other_Alphabetic
    check search($Rune(0x24B6), re("\\p{Alpha}")).found # Other_Alphabetic (So)
    check not search("1", re("\\p{Alpha}")).found
    check not search($Rune(0x00B2), re("\\p{Alpha}")).found

  test "Alpha spellings agree":
    let s = $Rune(0x05B0)
    check search(s, re("\\p{Alpha}")).found
    check search(s, re("[[:alpha:]]")).found
    check search(s, re("\\p{PosixAlpha}")).found

  test "Alnum is Alpha ∪ Nd":
    check search("1", re("\\p{Alnum}")).found
    check search($Rune(0x05B0), re("\\p{Alnum}")).found
    check not search($Rune(0x00B2), re("\\p{Alnum}")).found # No, not Nd

  test "Word adds marks, Nd, Pc, and six Latin-1 No digits":
    check search($Rune(0x05B0), re("\\w")).found
    check search("_", re("\\w")).found
    check search($Rune(0x00B2), re("\\w")).found
    check search($Rune(0x00BC), re("\\w")).found
    check not search($Rune(0x2070), re("\\w")).found # other Digit No
    check search($Rune(0x00B2), re("\\p{Word}")).found

  test "[[:word:]] omits the Latin-1 No digits that \\w adds":
    # Oniguruma's ISO-8859-1 ctype override reaches a bare \w / \p{Word} only.
    check not search($Rune(0x00B2), re("[[:word:]]")).found
    check not search($Rune(0x00BE), re("[[:word:]]")).found
    check not matchPosixClass(Rune(0x00B2), pcWord, false)
    check search($Rune(0x05B0), re("[[:word:]]")).found
    check search("_", re("[[:word:]]")).found

  test "inside [...] every word spelling drops the Latin-1 No digits":
    check not search($Rune(0x00B2), re("[\\w]")).found
    check not search($Rune(0x00B2), re("[a\\w]")).found
    check not search($Rune(0x00B2), re("[\\p{Word}]")).found
    check search($Rune(0x00B2), re("[\\W]")).found
    check search($Rune(0x00B2), re("[^\\w]")).found
    check search($Rune(0x05B0), re("[\\w]")).found

  test "Graph includes Cf and Co, excludes Z and Cn":
    check search($Rune(0x00AD), re("\\p{Graph}")).found # Cf
    check search($Rune(0xE000), re("\\p{Graph}")).found # Co
    check not search($Rune(0x0378), re("\\p{Graph}")).found # Cn
    check not search($Rune(0x00A0), re("\\p{Graph}")).found # Zs
    check not search(" ", re("\\p{Graph}")).found

  test "Print includes Zs and Cf, excludes Zl/Zp/Cn":
    check search($Rune(0x00A0), re("\\p{Print}")).found
    check search(" ", re("\\p{Print}")).found
    check search($Rune(0x00AD), re("\\p{Print}")).found
    check not search($Rune(0x2028), re("\\p{Print}")).found # Zl
    check not search($Rune(0x0378), re("\\p{Print}")).found

  test "Blank is Zs ∪ tab":
    check search("\t", re("\\p{Blank}")).found
    check search(" ", re("\\p{Blank}")).found
    check search($Rune(0x00A0), re("[[:blank:]]")).found
    check search($Rune(0x2000), re("\\p{Blank}")).found
    check not search("\n", re("\\p{Blank}")).found

  test "(?P) restricts Blank to space and tab":
    check search(" ", re("(?P)[[:blank:]]")).found
    check search("\t", re("(?P)[[:blank:]]")).found
    check not search($Rune(0x00A0), re("(?P)[[:blank:]]")).found
    check not search($Rune(0x2000), re("(?P)[[:blank:]]")).found
    check not search($Rune(0x3000), re("(?P)\\p{Blank}")).found
    check not matchPosixClass(Rune(0x00A0), pcBlank, true)

  test "(?P) restricts the other POSIX classes to ASCII":
    check not search($Rune(0x05B0), re("(?P)[[:alpha:]]")).found
    check not search($Rune(0x05B0), re("(?P)[[:alnum:]]")).found
    check not search($Rune(0x00AD), re("(?P)[[:graph:]]")).found
    check not search($Rune(0x00A0), re("(?P)[[:print:]]")).found
    check not search($Rune(0x00A1), re("(?P)[[:punct:]]")).found
    check not search($Rune(0x05B0), re("(?P)\\w")).found
    check not search($Rune(0x05B0), re("(?W)\\w")).found

  test "(?P) reaches \\w/\\d/\\s inside a character class":
    check not search($Rune(0x05B0), re("(?P)[\\w]")).found
    check not search($Rune(0x0660), re("(?P)[\\d]")).found # Arabic-Indic digit
    check not search($Rune(0x2028), re("(?P)[\\s]")).found
    check search("a", re("(?P)[\\w]")).found
    check search("1", re("(?P)[\\d]")).found
    check search(" ", re("(?P)[\\s]")).found

  test "(?W) narrows word chars only, not alpha/alnum":
    # ONIG_OPTION_WORD_IS_ASCII covers the WORD ctype; alpha/alnum need (?P).
    check search($Rune(0x05B0), re("(?W)[[:alpha:]]")).found
    check search($Rune(0x05B0), re("(?W)[[:alnum:]]")).found
    check search($Rune(0x05B0), re("(?W)\\p{Alpha}")).found
    check not search($Rune(0x05B0), re("(?W)[[:word:]]")).found

  test "(?P) leaves \\p{Punct} alone but narrows \\p{PosixPunct}":
    # \p{Punct} is the General_Category; only the ctype spellings follow (?P).
    check search($Rune(0x00A1), re("(?P)\\p{Punct}")).found
    check not search($Rune(0x00A2), re("(?P)\\p{PosixPunct}")).found
    check search($Rune(0x00A2), re("\\p{PosixPunct}")).found # Sc
    check not search($Rune(0x00A1), re("(?P)[[:punct:]]")).found

  test "\\p{Posix*} aliases follow the same flags as their brackets":
    check not search($Rune(0x05B0), re("(?P)\\p{PosixAlpha}")).found
    check not search($Rune(0x00A0), re("(?P)\\p{PosixBlank}")).found
    check not search($Rune(0x05B0), re("(?P)\\p{PosixWord}")).found
    check not search($Rune(0x05B0), re("(?W)\\p{PosixWord}")).found
    check not search($Rune(0x0660), re("(?D)\\p{PosixDigit}")).found
    check not search($Rune(0x2028), re("(?S)\\p{PosixSpace}")).found
    check search($Rune(0x05B0), re("(?W)\\p{PosixAlpha}")).found

  test "Punct is P ∪ S and excludes marks":
    check search("!", re("[[:punct:]]")).found
    check search("!", re("\\p{Punct}")).found # \p{Punct} is P only
    check search("+", re("[[:punct:]]")).found # Sm
    check search($Rune(0x00A2), re("[[:punct:]]")).found # Sc
    check not search($Rune(0x0300), re("[[:punct:]]")).found # Mn
    check not search($Rune(0x0903), re("[[:punct:]]")).found # Mc
    check not search($Rune(0x0488), re("[[:punct:]]")).found # Me
    check not search(" ", re("[[:punct:]]")).found
    check not search("a", re("[[:punct:]]")).found
