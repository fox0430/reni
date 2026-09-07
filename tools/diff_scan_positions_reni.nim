## reni side of tools/run_diff_scan_positions.sh (same format as the onig driver).
##
## Usage: nim c -r -d:release tools/diff_scan_positions_reni.nim \
##          <maxlen> <alphabet> '<pattern>'
##
## The alphabet is a comma-separated list of hex tokens, one or more bytes
## each, so a sweep can be built from whole characters ("0A,61,C3A9") or from
## raw bytes ("0A,61,C0").

import std/[os, strutils]
import reni

const MaxLen = 8

proc span(m: Match): string =
  if m.found:
    $m.matchSpan.a & "-" & $m.matchSpan.b
  else:
    "-"

proc sweep(rx: Regex, alphabet: seq[string], remaining: int, subject: string) =
  if remaining == 0:
    echo subject.toHex,
      " f=", span(search(subject, rx)), " b=", span(searchBackward(subject, rx))
    return
  for token in alphabet:
    sweep(rx, alphabet, remaining - 1, subject & token)

proc parseAlphabet(spec: string): seq[string] =
  for token in spec.split(','):
    if token.len == 0 or token.len mod 2 != 0:
      stderr.writeLine("alphabet must be comma-separated hex tokens, e.g. 0A,61,C3A9")
      quit(2)
    var bytes = newString(token.len div 2)
    for i in 0 ..< bytes.len:
      bytes[i] = chr(parseHexInt(token[i * 2 .. i * 2 + 1]))
    result.add bytes

proc main() =
  if paramCount() != 3:
    stderr.writeLine("usage: diff_scan_positions_reni <maxlen> <alphabet> <pattern>")
    quit(2)
  let maxlen = parseInt(paramStr(1))
  if maxlen < 1 or maxlen > MaxLen:
    stderr.writeLine("maxlen must be 1.." & $MaxLen)
    quit(2)
  let alphabet = parseAlphabet(paramStr(2))
  let rx = re(paramStr(3))
  for n in 1 .. maxlen:
    sweep(rx, alphabet, n, "")

main()
