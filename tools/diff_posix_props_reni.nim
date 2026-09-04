## List every code point matched by a reni pattern (same format as the onig driver).
##
## Usage: nim c -r -d:release tools/diff_posix_props_reni.nim '<pattern>'

import std/[os, strutils, unicode]
import reni

proc main() =
  if paramCount() != 1:
    stderr.writeLine("usage: diff_posix_props_reni <pattern>")
    quit(2)
  let rx = re(paramStr(1))
  var cp = 0
  while cp <= 0x10FFFF:
    if cp < 0xD800 or cp > 0xDFFF:
      # Encode as UTF-8 the same way the subject path will see it.
      let s = $Rune(cp)
      if search(s, rx).found:
        echo toHex(cp, 6)
    inc cp

main()
