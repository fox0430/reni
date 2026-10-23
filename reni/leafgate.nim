## What a repeat entry needs to know about its body, as a function of the node
## and the flags alone.  ``compiler`` derives it once per pattern into
## ``Regex.leafGates``; ``engine`` reads that table, and falls back to these
## procedures where a scoped ``(?i:...)`` has moved the flags out from under
## it.  Its own module because neither of those two can import the other.

import std/unicode
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

static:
  doAssert MultiCharFolds.len <= 32, "ClassFold.folds holds one bit per fold"

proc classFoldExhaustive(node: Node, flags: RegexFlags): ClassFold =
  ## [ClassFold] of class ``node`` under ``flags``.  Each answer runs the
  ## matcher's own test: ``classHasByte``'s atom walk for every byte below
  ## 0x80, and the membership test a fold variant of ``classAdvance`` opens
  ## with for every source in ``MultiCharFolds``.  [classFoldOf] answers
  ## from it where its shortcut does not reach, and the tests hold the
  ## shortcut to it.
  result = ClassFold(flags: flags, derived: true)
  for b in 0'u8 .. 0x7F'u8:
    let r = Rune(int32(b))
    for atom in node.atoms:
      if (
        if node.bracketClass:
          matchCcAtomWithFold(r, atom, flags)
        else:
          matchCcAtom(r, atom, flags)
      ):
        result.ascii.incl b
        break
  for i, f in MultiCharFolds:
    let src = Rune(f.source)
    for atom in node.atoms:
      if matchCcAtomWithFold(src, atom, flags):
        result.folds = result.folds or (1'u32 shl i)
        break

type FoldSourceRunes = object
  runes: array[4, int32] ## The source first, then what shares its fold.
  len: int

proc foldSourceRunesOf(): array[MultiCharFolds.len, FoldSourceRunes] =
  ## Each source in ``MultiCharFolds`` with the code points sharing its
  ## simple case fold.
  for i, f in MultiCharFolds:
    result[i].runes[0] = f.source
    result[i].len = 1
    for v in caseFoldVariants(Rune(f.source)):
      doAssert int32(v) >= 0x80, "a fold source shares its fold with ASCII"
      if int32(v) != f.source:
        result[i].runes[result[i].len] = int32(v)
        inc result[i].len

const FoldSourceRunesTable = foldSourceRunesOf()

static:
  # [classFoldOf]'s ASCII half rests on this: the simple fold class of an
  # ASCII byte is its case pair, plus K (U+212A) for k and ſ (U+017F) for s.
  for b in 0'i32 .. 0x7F'i32:
    var want = @[b]
    if b >= ord('a') and b <= ord('z'):
      want.add b - 32
    elif b >= ord('A') and b <= ord('Z'):
      want.add b + 32
    if b == ord('k') or b == ord('K'):
      want.add 0x212A
    elif b == ord('s') or b == ord('S'):
      want.add 0x017F
    var got: seq[int32]
    for v in caseFoldVariants(Rune(b)):
      got.add int32(v)
    for w in want:
      doAssert w in got, "the fold class of byte " & $b & " moved"
    doAssert got.len == want.len, "the fold class of byte " & $b & " moved"

proc foldsByClosure(node: Node): bool =
  ## Whether ``node`` accepts a character under ``(?i)`` exactly when some
  ## character of its fold class is a plain member, with ``asciiSet`` exact
  ## for the plain members below U+0080.  Every atom kind but two folds that
  ## way inside ``[...]``: a literal and a range fold themselves, and
  ## ``matchCcAtomWithFold`` tries every variant on the rest, none of which
  ## reads ``rfIgnoreCase``.  A nested class and an intersection fold their
  ## parts one by one, under a negation of their own.
  if not node.bracketClass or not node.asciiSetOk:
    return false
  for atom in node.atoms:
    if atom.kind in {ccNestedClass, ccIntersection}:
      return false
  true

proc plainMember(node: Node, r: Rune, flags: RegexFlags): bool =
  ## Whether an atom of ``node`` accepts ``r`` under ``flags``, which hold
  ## no case folding.
  for atom in node.atoms:
    if matchCcAtom(r, atom, flags):
      return true
  false

proc classFoldOf(node: Node, flags: RegexFlags): ClassFold =
  ## [classFoldExhaustive]'s answer, read off ``asciiSet`` where
  ## [foldsByClosure] holds instead of asking every atom about every byte.
  ## That walk re-folds each byte for each atom and doubled ``re()`` on
  ## ``(?i)[a-z]``; this asks the atoms about two dozen characters, and
  ## only for a class that reaches above U+007F.
  if not foldsByClosure(node):
    return classFoldExhaustive(node, flags)
  result = ClassFold(flags: flags, derived: true, ascii: node.asciiSet)
  for c in uint8('a') .. uint8('z'):
    if c in node.asciiSet or (c - 32) in node.asciiSet:
      result.ascii.incl c
      result.ascii.incl c - 32
  # Everything left to ask about is above U+007F.
  if not atomsReachNonAscii(node.atoms):
    return
  let plain = flags - {rfIgnoreCase, rfIgnoreCaseAscii}
  # ``(?I)`` folds nothing above U+007F: no byte reaches K or ſ, and a fold
  # source is held only as itself.
  let asciiOnly = rfIgnoreCaseAscii in flags
  if not asciiOnly:
    if plainMember(node, Rune(0x212A), plain):
      result.ascii.incl uint8('k')
      result.ascii.incl uint8('K')
    if plainMember(node, Rune(0x017F), plain):
      result.ascii.incl uint8('s')
      result.ascii.incl uint8('S')
  for i, src in FoldSourceRunesTable:
    let n = if asciiOnly: 1 else: src.len
    for k in 0 ..< n:
      if plainMember(node, Rune(src.runes[k]), plain):
        result.folds = result.folds or (1'u32 shl i)
        break

proc deriveClassFolds(node: Node, flags: RegexFlags, folds: var seq[ClassFold]) =
  ## Fill ``folds`` for every class under ``node`` read under ``(?i)``,
  ## tracking flags as ``annotateLookaroundBounds`` does.
  if node == nil:
    return
  case node.kind
  of nkCharClass:
    if rfIgnoreCase in flags:
      folds[node.id.int] = classFoldOf(node, flags)
  of nkConcat:
    var current = flags
    for child in node.children.view:
      # A bare flag group applies to the rest of the concat.
      if child.kind == nkFlagGroup and child.flagBody == nil:
        current = current + child.flagsOn - child.flagsOff
        continue
      deriveClassFolds(child, current, folds)
  of nkFlagGroup:
    if node.flagBody != nil:
      deriveClassFolds(node.flagBody, flags + node.flagsOn - node.flagsOff, folds)
  else:
    for child in node.childNodes:
      deriveClassFolds(child, flags, folds)

proc buildClassFolds*(ast: Node, nodes: seq[Node], flags: RegexFlags): seq[ClassFold] =
  ## One [ClassFold] slot per slot of ``nodes``, filled for each class read
  ## under ``(?i)``; empty when there is none, so a pattern without one
  ## carries no table.
  # Only ``flags`` and a flag group's ``flagsOn`` put ``(?i)`` in force, so
  # one pass over the flat table turns a pattern without it away before the
  # walk.  The walk and the table it fills cost about 1% of compiling the
  # grammar corpus, where nineteen patterns in twenty hold no ``(?i)`` class.
  var foldOn = rfIgnoreCase in flags
  var anyClass = false
  for i in 1 ..< nodes.len:
    let node {.cursor.} = nodes[i]
    case node.kind
    of nkCharClass:
      anyClass = true
    of nkFlagGroup:
      if rfIgnoreCase in node.flagsOn:
        foldOn = true
    else:
      discard
    if foldOn and anyClass:
      break
  if not (foldOn and anyClass):
    return
  result = newSeq[ClassFold](nodes.len)
  deriveClassFolds(ast, flags, result)
  for f in result:
    if f.derived:
      return
  result.setLen(0)

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
