## Word-boundary differential probe: prints every match span for a set of
## ``\b`` / ``\B`` shapes over subjects that cross U+007F, carry truncated
## UTF-8, and clip the window with a look-behind. Build it in both trees and
## diff the output; the ASCII path in [matchWordBoundary] may move nothing.

import std/strutils

import ../reni

const Patterns = [
  r"\bresult\b", r"\b\w+\b", r"\B\w+\B", r"\w+\b", r"\b", r"\B", r"(?W)\b\w+\b",
  r"(?W)\B", r"(?i)\bRESULT\b", r"\b[[:alpha:]]+\b", r"(?<=\b)\w+", r"(?<=\w)\b\w",
  r"\b(?!proc)\w+\b", r"\b(int|let|var)\b", r"(?a)\b\w+\b", r"\b.\b", r"\B.\B",
  r"\b\d+\b", r"\p{L}+\b", r"\b\p{L}+",
]

const Subjects = [
  "result = proc(x: int)",
  "日本語のテキスト abc 漢字123",
  "aえb え aéb",
  "\xE6\x97\xA5\xE6\x9C", # truncated tail
  "\x80\x80abc\x80",
  "café_naïve 123 ² ½",
  "",
  "a",
  " ",
  "ｆｕｌｌｗｉｄｔｈ ascii",
  "é́x ý",
  "one\ntwo\tthree",
]

proc main() =
  for p in Patterns:
    for s in Subjects:
      var line = p & " | " & s.escape & " ->"
      try:
        let rx = re(p)
        var sc = initMatchScanner(s)
        let ctx = newMatchContext(8)
        var m: Match
        while scanNext(sc, ctx, s, rx, m):
          line.add " [" & $m.boundaries[0].a & "," & $m.boundaries[0].b & ")"
          for i in 1 ..< m.boundaries.len:
            line.add "{" & $m.boundaries[i].a & "," & $m.boundaries[i].b & "}"
      except CatchableError as e:
        line.add " ERR:" & e.msg
      echo line

main()
