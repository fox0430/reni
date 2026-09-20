## Generated differential for the compile-time leaf gate: prints every answer
## so two builds can be diffed.  Deterministic in the seed; the generator draws
## from its own LCG, not std/random, so both builds agree on the corpus
## whatever their Nim versions do.
##
## The shapes are the ones whose answer the table could get wrong: a repeat
## over a leaf under a scoped `(?i:...)` or an isolated `(?i)`, which move
## `ctx.flags` away from the ones the table was derived under; `.` under
## `(?y{g})` and `(?y{w})`, which the compiler cannot have derived since the
## table is read with grapheme mode off; and the same body reached through a
## subroutine call from a different flag scope.
##
## One ``MatchContext`` drives the whole sweep, and each case also re-runs an
## *earlier* pattern on it, so the tree-switch path -- where one pattern's
## table would answer under another's node ids -- is exercised on every case.
## Reusing the context is the point: the public ``search`` allocates a fresh
## one per call, where a stale ``ctx.gates`` could never be observed.
##
## Usage: fuzz_leaf_gate <seed> <cases>
import std/[os, strutils]
import reni

type Rand = object
  state: uint64

proc next(r: var Rand): uint64 =
  r.state = r.state * 6364136223846793005'u64 + 1442695040888963407'u64
  result = r.state xor (r.state shr 31)

proc below(r: var Rand, n: int): int =
  int(r.next() mod uint64(n))

const Leaves = [
  r"\w", r"\d", r"\s", r"\W", r"[a-z]", r"[^a-z]", r"[a-zA-Z0-9_]", r"[\w.]", r".",
  r"\X", r"\R", r"\h", r"[[:alpha:]]", r"a", r"漢", r"[漢字]", r"\p{L}",
]
const Quants = ["*", "+", "?", "{2,4}", "*?", "+?", "*+", "++", "{1,}"]
const Scopes = [
  "", "(?i:%)", "(?i)%", "(?-i:%)", "(?y{g}:%)", "(?y{w}:%)", "(?m:%)", "(?s:%)",
  "(?x:%)", "(?a:%)",
]
const Tails = ["", r"\b", "x", r"\s", r"$", r"(?=\w)"]
const Alpha = [
  "a", "b", "z", "A", "Z", "0", "9", "_", " ", "\t", "\n", ".", ",", "x", "漢", "字",
  "é", "\u0301", "\r\n", "\xE0", "\xC3",
]

proc genPattern(r: var Rand): string =
  let leaf = Leaves[r.below(Leaves.len)]
  let quant = Quants[r.below(Quants.len)]
  let inner =
    case r.below(4)
    of 0:
      leaf & quant
    of 1:
      "(" & leaf & ")" & quant
    of 2:
      "(?:" & leaf & quant & ")" & Quants[r.below(Quants.len)]
    else:
      leaf & quant & Leaves[r.below(Leaves.len)] & Quants[r.below(Quants.len)]
  let scope = Scopes[r.below(Scopes.len)]
  let body =
    if scope.len == 0:
      inner
    else:
      scope.replace("%", inner)
  case r.below(8)
  of 0:
    # The body reached through a subroutine call, i.e. from whatever flags the
    # call site runs under rather than the ones the bind walked it with.
    "(?<b>" & body & ")(?i:\\g<b>)"
  of 1:
    "(?i)" & body & Tails[r.below(Tails.len)]
  else:
    body & Tails[r.below(Tails.len)]

proc genSubject(r: var Rand): string =
  let n = r.below(18)
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

proc report(ctx: MatchContext, p, s: string, rx: Regex) =
  var m: Match
  for start in 0 .. s.len:
    # Through the shared ``ctx``, not the public ``search``: the latter would
    # hand every call a context that has never seen another pattern.
    echo p,
      " | ",
      s.toHex,
      " | ",
      start,
      " | ",
      answer(
        block:
          searchIntoCtx(ctx, s, rx, m, start)
          m
      )
  var all = ""
  try:
    for m in findAll(s, rx):
      all.add spans(m) & " ; "
  except CatchableError as e:
    all.add "!! " & e.msg
  echo p, " | ", s.toHex, " | all | ", all

proc main() =
  if paramCount() != 2:
    stderr.writeLine("usage: fuzz_leaf_gate <seed> <cases>")
    quit(2)
  var r = Rand(state: uint64(parseInt(paramStr(1))) * 2862933555777941757'u64 + 1)
  let cases = parseInt(paramStr(2))
  # One context for the whole sweep, so every pattern binds over the last
  # one's leftovers.
  let ctx = newMatchContext()
  var prevPat = ""
  var prevRx: Regex
  var prevSubj = ""
  for _ in 1 .. cases:
    let p = genPattern(r)
    let s = genSubject(r)
    var rx: Regex
    try:
      rx = re(p)
    except CatchableError as e:
      echo p, " !! ", e.msg
      continue
    report(ctx, p, s, rx)
    if prevPat.len > 0:
      # Back to the previous tree on the same context: a table left over from
      # this pattern would answer under the other one's node ids.
      report(ctx, prevPat, prevSubj, prevRx)
    prevPat = p
    prevRx = rx
    prevSubj = s

main()
