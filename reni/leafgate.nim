## What a repeat entry needs to know about its body, as a function of the node
## and the flags alone.  ``compiler`` derives it once per pattern into
## ``Regex.leafGates``; ``engine`` reads that table, and falls back to these
## procedures where a scoped ``(?i:...)`` has moved the flags out from under
## it.  Its own module because neither of those two can import the other.

import types, unicode_utils

proc classFoldsApply*(node: Node, flags: RegexFlags): bool {.inline.} =
  ## Whether multi-char folds can apply: positive bracket class under ``(?i)``.
  rfIgnoreCase in flags and node.bracketClass and not node.negated

proc singleWayLeaf*(node: Node, flags: RegexFlags): bool =
  ## Whether ``node`` matches at most one way. Single-way bodies allow greedy
  ## repeats as a forward scan (one int per rep); they also leave nothing
  ## behind but ``pos`` (no captures, ``\K``, or flags).
  case node.kind
  of nkCharType:
    true
  of nkString:
    # An empty string would repeat zero-width, which the general path handles
    # with a subloop of its own; every other string consumes what it matched.
    node.runes.len > 0
  of nkLiteral, nkEscapedLiteral:
    # The second way a literal can match is the multi-character fold, which
    # only exists under ``(?i)`` and only for a character that has one.
    let r = if node.kind == nkLiteral: node.rune else: node.escapedRune
    rfIgnoreCase notin flags or getMultiCharFold(r).len == 0
  of nkCharClass:
    not classFoldsApply(node, flags)
  else:
    false

proc leafRunGraphemeDep*(node: Node): bool {.inline.} =
  ## Whether [leafRunAccepts]'s answer depends on grapheme mode, which is off
  ## where this is derived.  ``.`` alone: it runs as a cluster under
  ## ``(?y{g})`` and ``(?y{w})``, so no byte set decides it there.
  node.kind == nkCharType and node.charType == ctDot

proc leafRunAccepts*(node: Node, flags: RegexFlags, accept: var set[uint8]): bool =
  ## The ASCII bytes ``node`` accepts under ``flags`` with grapheme mode off,
  ## or false when no byte set decides it. Gives what ``classAdvance`` and
  ## ``charTypeAdvance`` give on their ASCII fast paths, without the call.
  ## Nothing at or above 0x80 is ever admitted, so the run loop can test
  ## membership alone.
  case node.kind
  of nkCharClass:
    # ``classBitmapAnswers``'s gate, minus the ``b < 0x80`` half the loop holds.
    if not node.asciiSetOk or rfIgnoreCase in flags:
      return false
    accept =
      if node.negated:
        AllAsciiBytes - node.asciiSet
      else:
        node.asciiSet
    true
  of nkCharType:
    # ``\X`` runs as a cluster and ``\R`` can take two bytes, so neither is
    # one byte per repetition. Every other type reads the same below U+0080
    # whatever the ASCII-restriction flags say -- see ``buildAsciiCharTypeSets``.
    case node.charType
    of ctGraphemeCluster, ctNewlineSeq:
      false
    of ctDot:
      # Grapheme and word mode are [leafRunGraphemeDep]'s business; outside
      # them ``.`` is the byte set ``charTypeAdvance``'s fast path reads
      # ``rfMultiLine`` for, fixed for the repeat.
      accept =
        if rfMultiLine in flags:
          AllAsciiBytes
        else:
          AsciiCharTypeSets[ctDot]
      true
    else:
      accept = AsciiCharTypeSets[node.charType]
      true
  else:
    # A literal is single-way too, but a run of them is ``literalAdvance``'s
    # business.
    false

proc gateWorthy(node: Node): bool {.inline.} =
  ## Whether the derivations above can answer anything but false for ``node``.
  ## Every other kind -- a group, an alternation, the repeat entry itself --
  ## keeps the all-false slot the table starts with.
  node.kind in {nkCharType, nkString, nkLiteral, nkEscapedLiteral, nkCharClass}

proc buildLeafGates*(nodes: seq[Node], flags: RegexFlags): seq[LeafGate] =
  ## One ``LeafGate`` per slot of ``nodes``, derived under ``flags``.  Slot 0
  ## is reserved and stays all-false, as does every slot [gateWorthy] turns
  ## down; all-false only ever costs a reader speed.
  result = newSeq[LeafGate](nodes.len)
  for i in 1 ..< nodes.len:
    let node {.cursor.} = nodes[i]
    if not gateWorthy(node):
      continue
    var gate = LeafGate(
      singleWay: singleWayLeaf(node, flags), graphemeDep: leafRunGraphemeDep(node)
    )
    gate.runnable = leafRunAccepts(node, flags, gate.accept)
    result[i] = gate

const MaxSeqRunElems* = 8
  ## Ceiling so the matcher copies elements onto its frame.  Eight covers
  ## every shape the corpus holds (the widest is two).

proc seqRunPassThrough*(node: Node): Node =
  ## Groups the matcher steps straight into.  A capture is not one: it writes
  ## a span per iteration, which a sequence of runs records nowhere.
  result = node
  while result != nil and result.kind == nkGroup and result.groupBodyKeepsFlags:
    result = result.groupBody

proc seqRunShape*(node: Node, elems: var array[MaxSeqRunElems, SeqRunElem]): int =
  ## Elements of ``node``'s body as a sequence of leaf runs, or 0 where it
  ## is not one in shape.  Structure only; what each leaf accepts is
  ## ``Node.quantSeqOk``'s business.
  let body {.cursor.} = seqRunPassThrough(node.quantBody)
  if body == nil or body.kind != nkConcat:
    return 0
  let k = body.children.len
  if k < 2 or k > MaxSeqRunElems:
    return 0
  for j in 0 ..< k:
    let child {.cursor.} = seqRunPassThrough(body.children[j])
    if child == nil:
      return 0
    var leaf {.cursor.} = child
    var emin = 1
    var emax = 1
    var poss = false
    if child.kind == nkQuantifier:
      # Lazy hands repetitions back in the other order; the walk does not.
      if child.quantKind notin {qkGreedy, qkPossessive}:
        return 0
      poss = child.quantKind == qkPossessive
      emin = child.quantMin
      emax = child.quantMax
      leaf = seqRunPassThrough(child.quantBody)
      if leaf == nil:
        return 0
    elems[j] = SeqRunElem(
      elem: child.id, leaf: leaf.id, emin: int32(emin), emax: int32(emax), eposs: poss
    )
  k

proc buildSeqRuns*(nodes: seq[Node], flags: RegexFlags) =
  ## Raise ``Node.quantSeqOk`` on every greedy repeat whose body is a
  ## sequence of leaf runs under ``flags``.  Needs the numbered tree:
  ## [seqRunShape] names nodes by [NodeId].  At least two elements (one
  ## is the leaf-run scan already), and one must consume so an iteration
  ## moves.
  var elems: array[MaxSeqRunElems, SeqRunElem]
  for i in 1 ..< nodes.len:
    let node {.cursor.} = nodes[i]
    if node.kind != nkQuantifier or node.quantKind != qkGreedy:
      continue
    let k = seqRunShape(node, elems)
    if k == 0:
      continue
    var ok = true
    var consumes = false
    for j in 0 ..< k:
      let leaf {.cursor.} = nodes[elems[j].leaf.int]
      var accept: set[uint8]
      if elems[j].emin < 0 or not singleWayLeaf(leaf, flags) or leafRunGraphemeDep(leaf) or
          not leafRunAccepts(leaf, flags, accept):
        ok = false
        break
      if elems[j].emin >= 1:
        consumes = true
    node.quantSeqOk = ok and consumes
