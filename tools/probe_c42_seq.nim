## C42's probe: which repeat bodies are a *sequence* of leaf repeats.
##
## The leaf-run scan covers a repeat whose body is one leaf
## (``OPTIMIZATION_LEAF_RUN_SCAN.md``, A1).  C42 asks what it would be worth
## to cover a body that is an ``nkConcat`` of leaf repeats -- the shape
## ``backtracking/repeated-group`` (``(?:\w+\s+){3,}``) has.  Before designing
## anything, count the shape: walk every compiled node table and report, per
## repeat, whether its body is such a sequence, and where it is not, the one
## reason it is not.
##
## Reads the benchmark suite's 29 patterns and, when a path is given on the
## command line, one pattern per line from that file.

import std/[os, strformat, strutils, tables]

import ../reni
import ../reni/types
import ../reni/leafgate
import ../bench/bench_common

type
  Verdict = enum
    vSeqRunnable ## every element is a repeat/leaf over an ASCII byte set
    vSeqLeaf ## every element is single-way, some not decided by a byte set
    vSingleLeaf ## one leaf or one leaf repeat: what the run scan already has
    vNotSeq ## something else

  Shape = object
    verdict: Verdict
    reason: string ## why it is not a sequence, for vNotSeq
    elems: int ## elements in the concatenation
    wrapped: bool ## the body sits inside a group

proc leafKindName(n: Node): string =
  case n.kind
  of nkCharType:
    "charType"
  of nkCharClass:
    "charClass"
  of nkString:
    "string"
  of nkLiteral, nkEscapedLiteral:
    "literal"
  else:
    $n.kind

var allowCapture = false
  ## Second pass: count the shapes a capture is the only thing keeping out.

proc unwrapGroup(n: Node, wrapped: var bool): Node =
  ## Groups the matcher steps straight into.  A capture is not one: it writes
  ## a span the sequence would have to record per iteration.
  result = n
  while result != nil:
    if result.kind == nkGroup and result.groupBodyKeepsFlags:
      wrapped = true
      result = result.groupBody
    elif allowCapture and result.kind == nkCapture:
      wrapped = true
      result = result.captureBody
    elif allowCapture and result.kind == nkNamedCapture:
      wrapped = true
      result = result.namedCaptureBody
    else:
      break

proc elemShape(n: Node, flags: RegexFlags, reason: var string): Verdict =
  ## Verdict for one element of the concatenation.
  var body {.cursor.} = n
  if n.kind == nkQuantifier:
    if n.quantKind notin {qkGreedy, qkPossessive, qkLazy}:
      reason = "quantKind"
      return vNotSeq
    body = n.quantBody
  if not singleWayLeaf(body, flags):
    reason =
      if body.kind in {nkCapture, nkNamedCapture}:
        "capture"
      elif body.kind == nkFlagGroup:
        "flagGroup"
      elif body.kind in {nkLookaround, nkAtomicGroup, nkAbsent}:
        "assertion"
      elif body.kind == nkBackreference or body.kind == nkNamedBackref:
        "backref"
      elif body.kind == nkAlternation:
        "alternation"
      elif body.kind == nkConcat:
        "nested concat"
      elif body.kind == nkAnchor:
        "anchor"
      elif body.kind == nkGroup:
        "group"
      else:
        "not single-way: " & leafKindName(body)
    return vNotSeq
  var accept: set[uint8]
  if leafRunAccepts(body, flags, accept) and not leafRunGraphemeDep(body):
    vSeqRunnable
  else:
    vSeqLeaf

proc shapeOf(q: Node, flags: RegexFlags): Shape =
  ## What C42's mechanism would find under repeat ``q``.
  var wrapped = false
  let body {.cursor.} = unwrapGroup(q.quantBody, wrapped)
  result.wrapped = wrapped
  if body == nil:
    result.verdict = vNotSeq
    result.reason = "empty"
    return
  if body.kind != nkConcat:
    var reason = ""
    let v = elemShape(body, flags, reason)
    result.elems = 1
    result.verdict =
      if v == vNotSeq:
        result.reason = reason
        vNotSeq
      else:
        vSingleLeaf
    return
  result.elems = body.children.len
  if result.elems == 0:
    # ``(?:)`` repeats zero-width; the general path owns it.
    result.verdict = vNotSeq
    result.reason = "empty concat"
    return
  var worst = vSeqRunnable
  for child in body.children:
    var reason = ""
    var sub = false
    let elem {.cursor.} = unwrapGroup(child, sub)
    if sub:
      result.wrapped = true
    let v = elemShape(elem, flags, reason)
    case v
    of vNotSeq:
      result.verdict = vNotSeq
      result.reason = reason
      return
    of vSeqLeaf:
      worst = vSeqLeaf
    else:
      discard
  result.verdict = worst

proc walk(
    pattern: string,
    hits: var CountTable[Verdict],
    reasons: var CountTable[string],
    examples: var Table[Verdict, seq[string]],
    widths: var CountTable[int],
): bool =
  var regex: Regex
  try:
    regex = re(pattern)
  except CatchableError:
    return false
  let flags = regex.flags
  for node in regex.nodes():
    if node == nil or node.kind != nkQuantifier:
      continue
    let s = shapeOf(node, flags)
    hits.inc s.verdict
    if s.verdict == vNotSeq:
      reasons.inc s.reason
    else:
      if s.verdict in {vSeqRunnable, vSeqLeaf}:
        widths.inc s.elems
      var ex = examples.getOrDefault(s.verdict)
      if ex.len < 12 and pattern notin ex:
        ex.add pattern
        examples[s.verdict] = ex
  true

proc report(
    title: string,
    hits: CountTable[Verdict],
    reasons: CountTable[string],
    examples: Table[Verdict, seq[string]],
    widths: CountTable[int],
    patterns, failed: int,
) =
  echo ""
  echo fmt"== {title}: {patterns} patterns, {failed} did not compile"
  var total = 0
  for v in Verdict:
    total += hits.getOrDefault(v)
  echo fmt"   repeats: {total}"
  for v in Verdict:
    echo fmt"   {v:<14} {hits.getOrDefault(v)}"
  if widths.len > 0:
    var line = ""
    for w, n in widths.pairs:
      line.add fmt"{w}:{n} "
    echo fmt"   sequence widths: {line}"
  if reasons.len > 0:
    var rs = reasons
    rs.sort()
    var line = ""
    var shown = 0
    for r, n in rs.pairs:
      if shown >= 10:
        break
      line.add fmt"{r}={n} "
      inc shown
    echo fmt"   not-a-sequence reasons: {line}"
  for v in [vSeqRunnable, vSeqLeaf]:
    let ex = examples.getOrDefault(v)
    if ex.len > 0:
      echo fmt"   {v} examples: " & ex.join("  |  ")

proc main() =
  block suite:
    var hits: CountTable[Verdict]
    var reasons: CountTable[string]
    var examples: Table[Verdict, seq[string]]
    var widths: CountTable[int]
    var failed = 0
    for b in Benchmarks:
      if not walk(b.pattern, hits, reasons, examples, widths):
        inc failed
    report("benchmark suite", hits, reasons, examples, widths, Benchmarks.len, failed)
    # Per-item detail: the suite is small enough to name every hit.
    for b in Benchmarks:
      var regex: Regex
      try:
        regex = re(b.pattern)
      except CatchableError:
        continue
      for node in regex.nodes():
        if node == nil or node.kind != nkQuantifier:
          continue
        let s = shapeOf(node, regex.flags)
        if s.verdict in {vSeqRunnable, vSeqLeaf}:
          echo fmt"   {b.category}/{b.label}: {s.verdict} over {s.elems} elements" &
            (if s.wrapped: " (grouped)" else: "")

  if paramCount() >= 1:
    let path = paramStr(1)
    var hits: CountTable[Verdict]
    var reasons: CountTable[string]
    var examples: Table[Verdict, seq[string]]
    var widths: CountTable[int]
    var failed = 0
    var seen = 0
    for line in lines(path):
      if line.len == 0:
        continue
      inc seen
      if not walk(line, hits, reasons, examples, widths):
        inc failed
    report(path.extractFilename, hits, reasons, examples, widths, seen, failed)

    # Same walk with a capture treated as a pass-through, to price the one
    # exclusion that dominates the reasons above.
    allowCapture = true
    var hits2: CountTable[Verdict]
    var reasons2: CountTable[string]
    var examples2: Table[Verdict, seq[string]]
    var widths2: CountTable[int]
    var failed2 = 0
    for line in lines(path):
      if line.len == 0:
        continue
      if not walk(line, hits2, reasons2, examples2, widths2):
        inc failed2
    report(
      path.extractFilename & " (captures treated as pass-through)",
      hits2,
      reasons2,
      examples2,
      widths2,
      seen,
      failed2,
    )
    allowCapture = false

main()
