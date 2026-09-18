## Generated differential for the leading look-behind scan: prints every
## answer so two builds can be diffed.  Deterministic in the seed; the
## generator draws from its own LCG, not std/random, so both builds agree
## on the corpus whatever their Nim versions do.
##
## Usage: fuzz_leadbehind <seed> <cases>
import std/[os, strutils]
import reni

type Rand = object
  state: uint64

proc next(r: var Rand): uint64 =
  r.state = r.state * 6364136223846793005'u64 + 1442695040888963407'u64
  result = r.state xor (r.state shr 31)

proc below(r: var Rand, n: int): int =
  int(r.next() mod uint64(n))

const Lits = ["\\.", "a", "ab", "x\\.", "\\.\\.", ";", "_", "abc", "\\$", "\\+"]
const Bodies = [
  r"\w+", r"\w", r"\d+", r"[a-z]+", r"[^\s]*", r"a*", r"漢+", r".", r".+?", r"\w+;",
  r"(\w)(\w+)", r"\w+(?=;)", r"x|y", r"(?:ab)+", r"\S{2,}", r"",
]
const Pre = ["", r"\b", r"^", r"(?!q)", r"(?=\w)", r"\K", r"(?<!z)", r"\A"]
const Post = ["", r"\b", r"$", r"(?=\s)", r"\K", r"(?!;)", r"\z"]
const Alpha =
  ["a", "b", "x", ".", ";", " ", "_", "\n", "é", "漢", "\xE0", "\xC3", "$", "+"]

proc genPattern(r: var Rand): string =
  let shape = r.below(10)
  let lit = Lits[r.below(Lits.len)]
  let body = Bodies[r.below(Bodies.len)]
  case shape
  of 0 .. 3:
    Pre[r.below(Pre.len)] & "(?<=" & lit & ")" & body & Post[r.below(Post.len)]
  of 4:
    "(?:(?<=" & lit & ")" & body & ")+"
  of 5:
    "((?<=" & lit & ")" & body & ")" & Post[r.below(Post.len)]
  of 6:
    "(?<!" & lit & ")(?<=" & lit & ")" & body
  of 7:
    "(?<=" & lit & ")(?<=" & lit & ")" & body
  of 8:
    "(?<=" & lit & ")?" & body
  else:
    body & "(?<=" & lit & ")" & Post[r.below(Post.len)]

proc genSubject(r: var Rand): string =
  let n = r.below(14)
  for _ in 0 .. n:
    result.add Alpha[r.below(Alpha.len)]

proc spans(m: Match): string =
  if not m.found:
    return "-"
  result = $m.matchSpan.a & "-" & $m.matchSpan.b & " sc=" & $m.startChar
  for g in 1 ..< m.groupCount:
    result.add " " & $m.captureSpan(g).a & "-" & $m.captureSpan(g).b

template answer(call: untyped): string =
  ## A limit is an answer the two builds must still agree on: report it, do
  ## not end the sweep.
  block:
    var res: string
    try:
      res = spans(call)
    except CatchableError as e:
      res = "!! " & e.msg
    res

proc main() =
  if paramCount() != 2:
    stderr.writeLine("usage: fuzz_leadbehind <seed> <cases>")
    quit(2)
  var r = Rand(state: uint64(parseInt(paramStr(1))) * 2862933555777941757'u64 + 1)
  let cases = parseInt(paramStr(2))
  for _ in 1 .. cases:
    let p = genPattern(r)
    let s = genSubject(r)
    var rx: Regex
    try:
      rx = re(p)
    except CatchableError as e:
      echo p, " !! ", e.msg
      continue
    for start in 0 .. s.len:
      echo p, " | ", s.toHex, " | ", start, " | ", answer(search(s, rx, start))
    echo p, " | ", s.toHex, " | back | ", answer(searchBackward(s, rx))
    var all = ""
    try:
      for m in findAll(s, rx):
        all.add spans(m) & " ; "
    except CatchableError as e:
      all.add "!! " & e.msg
    echo p, " | ", s.toHex, " | all | ", all

main()
