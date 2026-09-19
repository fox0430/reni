## Generated differential for the literal-alternation trie: prints every
## answer so two builds can be diffed.  Deterministic in the seed; the
## generator draws from its own LCG, not std/random, so both builds agree on
## the corpus whatever their Nim versions do.
##
## The shapes are the ones ``buildAltTrie`` accepts and the ones just outside
## it: shared prefixes, branches that are prefixes of each other (``int``
## before ``int8``), duplicate spellings, multi-byte literals, and fan-outs on
## either side of the transition-row threshold.  The empty branch and one at
## ``AltTrieMaxWordLen`` are refused, so the alternations that take no trie
## and fall back to the hints come from the same corpus.
##
## Usage: fuzz_alt_trie <seed> <cases>
import std/[os, strutils]
import reni

type Rand = object
  state: uint64

proc next(r: var Rand): uint64 =
  r.state = r.state * 6364136223846793005'u64 + 1442695040888963407'u64
  result = r.state xor (r.state shr 31)

proc below(r: var Rand, n: int): int =
  int(r.next() mod uint64(n))

const Words = [
  "a", "ab", "abc", "abcd", "b", "ba", "int", "int8", "int16", "float", "f", "proc",
  "pro", "p", "x", "xy", "漢", "漢字", "é", "éa", "\xE0\xB8\x81", "_", "A", "Ab",
  "Z", "0", "01",
  # Refused by ``buildAltTrie``: an empty branch, and one at the length bound.
  "", "abcdabcdabcdabcd",
]
const Alpha = [
  "a", "b", "c", "d", "i", "n", "t", "8", "1", "6", "f", "l", "o", "p", "r", "x", "y",
  "_", "A", "Z", "0", " ", "\n", "漢", "字", "é", "\xE0", "\xC3",
]
const Pre = ["", r"\b", r"^", r"(?=\w)", r"(?<!z)", r"\K", r"\A"]
const Post = ["", r"\b", r"$", r"(?=\s)", r"\z", r"(?!x)"]
const Wrap = [0, 1, 2, 3, 4, 5]
  ## 0 bare group, 1 non-capturing, 2 repeated, 3 lazy repeat, 4 atomic,
  ## 5 optional: same arms, different callers of the trie.

proc genAlternation(r: var Rand): string =
  ## Two to twelve literal branches, drawing both sides of the
  ## transition-row threshold and of the root fan-out.
  let arms = 2 + r.below(11)
  for i in 0 ..< arms:
    if i > 0:
      result.add "|"
    result.add Words[r.below(Words.len)]

proc genPattern(r: var Rand): string =
  let alt = genAlternation(r)
  let body =
    case Wrap[r.below(Wrap.len)]
    of 0:
      "(" & alt & ")"
    of 1:
      "(?:" & alt & ")"
    of 2:
      "(?:" & alt & ")+"
    of 3:
      "(?:" & alt & ")+?"
    of 4:
      "(?>" & alt & ")"
    else:
      "(?:" & alt & ")?"
  Pre[r.below(Pre.len)] & body & Post[r.below(Post.len)]

proc genSubject(r: var Rand): string =
  let n = r.below(16)
  for _ in 0 .. n:
    result.add Alpha[r.below(Alpha.len)]

proc spans(m: Match): string =
  if not m.found:
    return "-"
  result = $m.matchSpan.a & "-" & $m.matchSpan.b & " sc=" & $m.startChar
  for g in 1 .. m.groupCount:
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
    stderr.writeLine("usage: fuzz_alt_trie <seed> <cases>")
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
