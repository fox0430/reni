## How Oniguruma reshapes a look-behind body before it compiles it
## (``tune_look_behind``).  [tuneLookBehinds] gives every look-behind the
## shape Oniguruma leaves it in, innermost first: the body's leading repeats
## pinned to their lower bound ([reduceBody]), then the positive look-behind
## dropped, divided into one look-behind per branch (``lookDivided``, which
## the matcher retries), or kept whole, on the lengths of that reduced body
## ([tuneLookBehind]).
##
## The decisions read a model of Oniguruma's tree -- lengths in characters,
## ``min_is_sure``, the possessive rewrite and the case-fold unravelling that
## run before its reduction -- which nothing else in the compiler reads.  Its
## own module for that reason.

import std/unicode

import types, unicode_utils, stackguard

proc isSimpleRepeatBody(node: Node): bool {.inline.} =
  ## Repeat bodies the look-behind reduction handles: strings, char types,
  ## char classes and backreferences.  Captures and alternations do not
  ## reduce.
  ##
  ## ``\X`` and ``\R`` are char types here but not ones Oniguruma reduces: it
  ## expands both into a subexpression while parsing, and its table reads the
  ## node kind.  Neither has a fixed length, so dropping a repeat over one
  ## would take from ``(?<=\X*\b)`` the window that makes it refuse at
  ## offset 0.
  if node == nil:
    return false
  if node.kind == nkCharType:
    return node.charType notin {ctGraphemeCluster, ctNewlineSeq}
  node.kind in {
    nkLiteral, nkEscapedLiteral, nkString, nkCharClass, nkBackreference, nkNamedBackref
  }

type
  CharSpan = object
    ## How many characters a node consumes, counted as Oniguruma's
    ## ``node_char_len`` counts them: one per pattern character, whatever its
    ## width in bytes.  [lengthBounds] counts bytes and cannot stand in.
    ## ``hi`` is -1 when nothing bounds it.  ``sure`` is ``min_is_sure``:
    ## whether some way through consumes ``lo`` characters and nothing on it
    ## can fail but what it reads.  A look-behind whose body is ``lo == 0``
    ## and sure holds everywhere, so Oniguruma drops it.
    lo, hi: int
    sure: bool

  GroupSpans* = object
    ## What [charSpan] reads beyond the node it measures: the group bodies a
    ## backreference or a call is measured through, each group's span once
    ## measured, and the groups the pattern refers to anywhere.  Collected
    ## when the first group is measured; most patterns never get there.  The
    ## compiler's empty-check pass measures through one too, on the numbered
    ## final tree (see [initGroupSpans]).
    root: Node
    names: seq[(string, int)]
    bodies: seq[Node]
    spans: seq[CharSpan]
    measured: seq[bool]
    visiting: seq[bool]
    referenced: seq[bool]
    ready: bool
    open: int ## How many groups are being measured; see [repeatBodySpan].
    bodySpans: seq[CharSpan]
    bodyKnown: seq[bool]
      ## By [NodeId]: a repeat's body span, once measured; see
      ## [repeatBodySpan].  Empty unless [initGroupSpans] was given the
      ## numbering.
    stackBase: int ## Where measuring began, for [charSpan]'s stack check.

const CharSpanCap = 1 shl 30
  ## Where a count saturates, as Oniguruma's ``distance_add`` and
  ## ``distance_multiply`` saturate to infinity: past it ``lo`` stays put and
  ## ``hi`` becomes unbounded.

proc spanOf(n: int, sure = true): CharSpan {.inline.} =
  CharSpan(lo: n, hi: n, sure: sure)

proc fixed(s: CharSpan): bool {.inline.} =
  s.hi >= 0 and s.lo == s.hi

proc `+`(a, b: CharSpan): CharSpan =
  CharSpan(
    lo: min(a.lo + b.lo, CharSpanCap),
    hi:
      if a.hi < 0 or b.hi < 0 or a.hi + b.hi > CharSpanCap:
        -1
      else:
        a.hi + b.hi,
    sure: a.sure and b.sure,
  )

proc either(a, b: CharSpan): CharSpan =
  ## ``a`` or else ``b``, as an alternation consumes (``mmcl_alt_merge``):
  ## the shorter minimum brings its own ``sure``, and a tie is sure if either
  ## side is.
  CharSpan(
    lo: min(a.lo, b.lo),
    hi:
      if a.hi < 0 or b.hi < 0:
        -1
      else:
        max(a.hi, b.hi),
    sure:
      if a.lo < b.lo:
        a.sure
      elif b.lo < a.lo:
        b.sure
      else:
        a.sure or b.sure,
  )

proc repeated(s: CharSpan, lo, hi: int): CharSpan =
  ## ``s`` repeated ``lo`` to ``hi`` times (-1: unbounded).  An unbounded
  ## repeat is unbounded even over a zero-width body, as Oniguruma counts it.
  proc times(n, m: int, unbounded: int): int =
    if m == 0:
      0
    elif n < 0:
      -1
    elif n > CharSpanCap div m:
      unbounded
    else:
      n * m

  if lo == hi:
    if lo == 0:
      return spanOf(0)
    return
      CharSpan(lo: times(s.lo, lo, CharSpanCap), hi: times(s.hi, lo, -1), sure: s.sure)
  CharSpan(
    lo: times(s.lo, lo, CharSpanCap),
    hi:
      if hi < 0:
        -1
      else:
        times(s.hi, hi, -1),
    sure: s.sure,
  )

proc ensureGroups(g: var GroupSpans) =
  ## Collect the group bodies, and mark every group a backreference, a
  ## conditional or a call names -- Oniguruma's ``check_backrefs`` and call
  ## tuning.  Must run before the first look-behind is dropped: a reference
  ## written only in a dropped one still counts.
  if g.ready:
    return
  g.ready = true
  var flags: seq[RegexFlags]
  collectGroupBodies(g.root, g.bodies, flags)
  g.spans = newSeq[CharSpan](g.bodies.len)
  g.measured = newSeq[bool](g.bodies.len)
  g.visiting = newSeq[bool](g.bodies.len)
  g.referenced = newSeq[bool](g.bodies.len)
  proc mark(g: var GroupSpans, idx: int) =
    if idx >= 0 and idx < g.referenced.len:
      g.referenced[idx] = true

  proc markName(g: var GroupSpans, name: string, scope: int32) =
    for idx in g.names.namedGroupsRead(name, scope):
      mark(g, idx)

  proc walk(g: var GroupSpans, node: Node) =
    if node == nil:
      return
    case node.kind
    of nkBackreference:
      mark(g, node.backrefIndex - 1)
    of nkNamedBackref:
      markName(g, node.backrefName, node.backrefScope)
    of nkSubexpCall:
      if node.callIndex > 0:
        mark(g, node.callIndex - 1)
      elif node.callName.len > 0:
        markName(g, node.callName, EveryNamedGroup)
    of nkConditional:
      case node.condKind
      of ckBackref:
        mark(g, node.condRefIndex - 1)
      of ckNamedRef:
        markName(g, node.condRefName, node.condScope)
      else:
        discard
    else:
      discard
    for child in node.childNodes:
      walk(g, child)

  walk(g, g.root)

proc charSpan(node: Node, g: var GroupSpans): CharSpan

proc groupSpan(g: var GroupSpans, idx: int): CharSpan =
  ## The span of group ``idx`` (0-based), unbounded when the group is unknown
  ## or being measured already -- a reference back into itself, which
  ## Oniguruma reads as unbounded too.  Never sure: a group is not.  Measured
  ## once and kept, as Oniguruma keeps it on the group node (``FIXED_CLEN``);
  ## measured afresh through every reference, each group of
  ## ``(a)(\1\1)(\2\2)...`` would cost twice the one before it.
  ensureGroups(g)
  if idx < 0 or idx >= g.bodies.len or g.bodies[idx] == nil or g.visiting[idx]:
    return CharSpan(lo: 0, hi: -1)
  if not g.measured[idx]:
    g.visiting[idx] = true
    inc g.open
    var s = charSpan(g.bodies[idx], g)
    dec g.open
    g.visiting[idx] = false
    s.sure = false
    g.spans[idx] = s
    g.measured[idx] = true
  g.spans[idx]

proc namedGroupSpan(g: var GroupSpans, name: string, scope: int32): CharSpan =
  ## Any of the groups called ``name`` that a reference in ``scope`` reads
  ## ([namedGroupsRead]), as a backreference to a name that several groups
  ## share reads any one of them.
  ensureGroups(g)
  var first = true
  for idx in g.names.namedGroupsRead(name, scope):
    let s = groupSpan(g, idx)
    result =
      if first:
        s
      else:
        either(result, s)
    first = false
  if first:
    result = CharSpan(lo: 0, hi: -1)

proc repeatBodySpan(q: Node, g: var GroupSpans): CharSpan =
  ## [charSpan] of repeat ``q``'s body, kept by [NodeId] when
  ## [initGroupSpans] was given the numbering.  A repeat inside another is
  ## then measured once, not again for every repeat around it.  Nothing is
  ## kept or read while a group is being measured: a reference back into
  ## that group reads as unbounded there (see [groupSpan]), and the same
  ## body measured from outside it reads it in full.
  let id = q.id.int
  let keep = g.open == 0 and id > 0 and id < g.bodyKnown.len
  if keep and g.bodyKnown[id]:
    return g.bodySpans[id]
  result = charSpan(q.quantBody, g)
  if keep:
    g.bodySpans[id] = result
    g.bodyKnown[id] = true

proc charSpan(node: Node, g: var GroupSpans): CharSpan =
  ## Oniguruma's ``node_char_len1`` over this tree.  ``\R`` and ``\X`` are
  ## subexpressions there, of one to two characters and of one or more.
  ## Where the two trees part ways, the answer leans to ``sure == false``,
  ## which keeps a look-behind rather than dropping it.
  if node == nil:
    return spanOf(0)
  # A group is measured through the calls and references in it, and a chain
  # of those is as long as the pattern.
  if nearStackEnd(g.stackBase):
    raise newException(RegexLimitError, "compile stack budget exceeded")
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkCharClass:
    spanOf(1)
  of nkString:
    spanOf(node.runes.len)
  of nkCharType:
    case node.charType
    of ctGraphemeCluster:
      CharSpan(lo: 1, hi: -1)
    of ctNewlineSeq:
      CharSpan(lo: 1, hi: 2, sure: true)
    else:
      spanOf(1)
  of nkConcat:
    var s = spanOf(0)
    for child in node.children.view:
      s = s + charSpan(child, g)
    s
  of nkAlternation:
    var s = spanOf(0)
    for i, alt in node.alternatives.view:
      let a = charSpan(alt, g)
      s =
        if i == 0:
          a
        else:
          either(s, a)
    s
  of nkQuantifier:
    let (lo, hi) = effectiveQuantBounds(node.quantMin, node.quantMax)
    if lo == 0 and hi == 0:
      spanOf(0)
    else:
      repeatBodySpan(node, g).repeated(lo, hi)
  of nkCapture:
    groupSpan(g, node.captureIndex)
  of nkNamedCapture:
    groupSpan(g, node.namedCaptureIndex)
  of nkGroup:
    charSpan(node.groupBody, g)
  of nkFlagGroup:
    charSpan(node.flagBody, g)
  of nkAtomicGroup:
    charSpan(node.atomicBody, g)
  of nkAnchor:
    # ``\K`` is no anchor there but a marker, which consumes nothing surely.
    spanOf(0, sure = node.anchor == akKeep)
  of nkLookaround:
    spanOf(0, sure = false)
  of nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    spanOf(0, sure = false)
  of nkBackreference:
    if node.backrefLevel != 0:
      CharSpan(lo: 0, hi: -1)
    else:
      groupSpan(g, node.backrefIndex - 1)
  of nkNamedBackref:
    if node.namedBackrefLevel != 0:
      CharSpan(lo: 0, hi: -1)
    else:
      namedGroupSpan(g, node.backrefName, node.backrefScope)
  of nkSubexpCall:
    if node.callIndex > 0:
      groupSpan(g, node.callIndex - 1)
    elif node.callName.len > 0:
      namedGroupSpan(g, node.callName, EveryNamedGroup)
    else:
      CharSpan(lo: 0, hi: -1) # ``\g<0>``: the whole pattern, recursively
  of nkConditional:
    let test =
      if node.condKind == ckRegexCond:
        charSpan(node.condBody, g)
      else:
        spanOf(0, sure = false)
    let bare =
      node.condNo == nil and (
        node.condYes == nil or
        (node.condYes.kind == nkConcat and node.condYes.children.len == 0)
      )
    if bare:
      # ``(?(1))``: Oniguruma keeps the test alone, an assertion.
      test
    else:
      # The test runs before the yes branch only, as in ``BAG_IF_ELSE``.
      either(test + charSpan(node.condYes, g), charSpan(node.condNo, g))
  of nkAbsent:
    case node.absentKind
    of abClear, abRange:
      spanOf(0, sure = false)
    of abFunction, abExpression:
      CharSpan(lo: 0, hi: -1)

proc initGroupSpans*(root: Node, names: seq[(string, int)], nodeCount = 0): GroupSpans =
  ## Measure through the groups of ``root``; ``names`` maps each capture
  ## name to its group.  With ``nodeCount``, the size of the table ``root``
  ## was numbered into, [repeatBodySpan] keeps what it measures.  Leave it 0
  ## on a tree a pass is still reshaping, as [tuneLookBehinds] does.
  GroupSpans(
    root: root,
    names: names,
    bodySpans: newSeq[CharSpan](nodeCount),
    bodyKnown: newSeq[bool](nodeCount),
    stackBase: currentStackAddr(),
  )

proc repeatBodyMayBeEmpty*(q: Node, g: var GroupSpans): bool =
  ## Whether repeat ``q``'s body may match empty: what Oniguruma's
  ## ``node_min_byte_len(body) == 0`` decides for the repeat's
  ## ``emptiness``.  That counts bytes and [charSpan] characters, but the two
  ## minimums are zero together outside three corners: ``(*FAIL)``,
  ## infinitely long there and the empty ``(?!)`` it parses to here; a
  ## reference inside the group it names, empty there (``ND_IS_RECURSION``)
  ## and measured through the group here; and a reference with a level other
  ## than 0, empty here wherever it stands.  An iteration through the first,
  ## or through a plain reference into its own open group
  ## (``Regex.opensUnset``), always fails, so no empty check reads those.
  repeatBodySpan(q, g).lo == 0

const AsciiWordBytes =
  {'0'.uint8 .. '9'.uint8, 'A'.uint8 .. 'Z'.uint8, '_'.uint8, 'a'.uint8 .. 'z'.uint8}

proc foldVariants(r: Rune, flags: RegexFlags): seq[Rune] =
  ## The class Oniguruma turns ``r`` into inside a look-behind under case
  ## folding (``unravel_cf_look_behind_add``): ``r`` and every character it
  ## folds with one for one, whatever their width -- ``ſ`` brings ``s`` and
  ## ``S`` -- or nothing when it has none and stays a string.  Under ``(?I)``,
  ## which on its own folds nothing, only ASCII folds with ASCII.
  if rfIgnoreCase notin flags:
    return
  let ascii = rfIgnoreCaseAscii in flags
  for v in caseFoldVariants(r):
    if v != r and not (ascii and (int32(v) >= 0x80 or int32(r) >= 0x80)):
      result.add v
  if result.len > 0:
    result.add r

proc foldSegments(node: Node, flags: RegexFlags): int =
  ## How many nodes Oniguruma unravels a string into inside a look-behind:
  ## one class per character with case variants, one string per run of the
  ## rest.  More than one makes a sequence -- not a repeat body the
  ## look-behind reduction pins.
  if node.kind != nkString:
    return 1
  var inRun = false
  for r in node.runes:
    if foldVariants(r, flags).len > 0:
      inc result
      inRun = false
    elif not inRun:
      inc result
      inRun = true

type
  HeadKind = enum
    hkNone
    hkString ## a string: ``bytes``
    hkVariants ## one character's case variants: ``variants``
    hkNode ## a class or a character type: ``node``, under ``flags``

  HeadLit = object
    ## A head literal as Oniguruma's ``is_exclusive`` sees it once
    ## ``tune_tree`` has unravelled the strings of a look-behind.
    kind: HeadKind
    bytes: string
    variants: seq[Rune]
    node: Node
    flags: RegexFlags

proc stringHead(runes: openArray[Rune], flags: RegexFlags): HeadLit =
  ## The first node of a string once unravelled: its first character's
  ## variants, or the run of characters that have none.
  let first = foldVariants(runes[0], flags)
  if first.len > 0:
    return HeadLit(kind: hkVariants, variants: first)
  var bytes = ""
  for r in runes:
    if foldVariants(r, flags).len > 0:
      break
    bytes.add $r
  HeadLit(kind: hkString, bytes: bytes)

proc onigHeadLiteral(node: Node, flags: RegexFlags): HeadLit =
  ## Oniguruma's ``get_tree_head_literal`` (inexact): the one-character node
  ## every match of ``node`` begins with, or ``hkNone``.  Any character
  ## (``.``) and the shapes it does not look through give none.
  if node == nil:
    return HeadLit(kind: hkNone)
  case node.kind
  of nkLiteral:
    stringHead([node.rune], flags)
  of nkEscapedLiteral:
    stringHead([node.escapedRune], flags)
  of nkString:
    if node.runes.len > 0:
      stringHead(node.runes, flags)
    else:
      HeadLit(kind: hkNone)
  of nkCharClass:
    HeadLit(kind: hkNode, node: node, flags: flags)
  of nkCharType:
    if node.charType in {
      ctDot, ctAnyChar, ctNotNewline, ctNewlineSeq, ctGraphemeCluster
    }:
      HeadLit(kind: hkNone)
    else:
      HeadLit(kind: hkNode, node: node, flags: flags)
  of nkConcat:
    if node.children.len > 0:
      onigHeadLiteral(node.children[0], flags)
    else:
      HeadLit(kind: hkNone)
  of nkQuantifier:
    if effectiveQuantBounds(node.quantMin, node.quantMax).lo > 0:
      onigHeadLiteral(node.quantBody, flags)
    else:
      HeadLit(kind: hkNone)
  of nkGroup:
    onigHeadLiteral(node.groupBody, flags)
  of nkCapture:
    onigHeadLiteral(node.captureBody, flags)
  of nkNamedCapture:
    onigHeadLiteral(node.namedCaptureBody, flags)
  of nkAtomicGroup:
    onigHeadLiteral(node.atomicBody, flags)
  of nkFlagGroup:
    onigHeadLiteral(node.flagBody, flags + node.flagsOn - node.flagsOff)
  of nkLookaround:
    if node.lookKind == lkAhead:
      onigHeadLiteral(node.lookBody, flags)
    else:
      HeadLit(kind: hkNone)
  else:
    HeadLit(kind: hkNone)

proc isWordType(h: HeadLit): bool {.inline.} =
  h.kind == hkNode and h.node.kind == nkCharType and
    h.node.charType in {ctWord, ctNotWord}

proc accepts(h: HeadLit, r: Rune): bool =
  ## Whether the class-like head ``h`` accepts ``r``.  A class reads ``r`` as
  ## the matcher does, case folding and ``(?I)`` included.
  case h.kind
  of hkVariants:
    r in h.variants
  of hkNode:
    let flags = h.flags
    let node = h.node
    if node.kind == nkCharClass:
      var hit = false
      for atom in node.atoms:
        let atomHit =
          if node.bracketClass:
            matchCcAtomWithFold(r, atom, flags)
          else:
            matchCcAtom(r, atom, flags)
        if atomHit:
          hit = true
          break
      return hit != node.negated
    let ascii = rfAsciiPosix in flags
    case node.charType
    of ctWord:
      isWordChar(r, ascii or rfAsciiWord in flags)
    of ctNotWord:
      not isWordChar(r, ascii or rfAsciiWord in flags)
    of ctDigit:
      isDigitChar(r, ascii or rfAsciiDigit in flags)
    of ctNotDigit:
      not isDigitChar(r, ascii or rfAsciiDigit in flags)
    of ctSpace:
      isSpaceChar(r, ascii or rfAsciiSpace in flags)
    of ctNotSpace:
      not isSpaceChar(r, ascii or rfAsciiSpace in flags)
    of ctHexDigit:
      isHexDigitChar(r)
    of ctNotHexDigit:
      not isHexDigitChar(r)
    else:
      true
  else:
    true

proc asciiView(h: HeadLit, members: var set[uint8], plain: var bool): bool =
  ## The ASCII characters the class-like head ``h`` accepts, and whether it
  ## is ``plain`` -- not negated and nothing past ASCII, which Oniguruma's
  ## class test needs: it compares bitsets of ASCII members only.  False when
  ## out of reach.
  members = {}
  for c in 0'u8 .. 127'u8:
    if accepts(h, Rune(int32(c))):
      members.incl c
  case h.kind
  of hkVariants:
    plain = true
    for v in h.variants:
      if int32(v) >= 0x80:
        plain = false
    true
  of hkNode:
    let flags = h.flags
    let node = h.node
    if node.kind == nkCharClass:
      var ascii: set[uint8]
      var nonAscii, predicate: bool
      if not classAsciiMatches(node, ascii, nonAscii, predicate):
        return false
      plain = not node.negated and not nonAscii
      if plain and rfIgnoreCase in flags and rfIgnoreCaseAscii notin flags:
        # Folding adds a member's wider variants -- ``k`` brings U+212A.
        for c in members:
          for v in caseFoldVariants(Rune(int32(c))):
            if int32(v) >= 0x80:
              plain = false
      return true
    let ascii = rfAsciiPosix in flags
    plain =
      case node.charType
      of ctDigit:
        ascii or rfAsciiDigit in flags
      of ctSpace:
        ascii or rfAsciiSpace in flags
      of ctHexDigit:
        true
      else:
        false
    true
  else:
    false

proc onigExclusive(x, y: HeadLit): bool =
  ## Oniguruma's ``is_exclusive``: whether no character can begin both ``x``
  ## and ``y``.  Two classes are compared through their ASCII members, and
  ## only where that settles it; anything else counts as overlapping, which
  ## leaves the repeat to the reduction.
  if x.kind == hkString and y.kind == hkString:
    # Byte by byte over the shorter string, as Oniguruma compares them.
    for i in 0 ..< min(x.bytes.len, y.bytes.len):
      if x.bytes[i] != y.bytes[i]:
        return true
    return false
  if x.kind == hkString or y.kind == hkString:
    let (lit, other) =
      if x.kind == hkString:
        (x, y)
      else:
        (y, x)
    return not accepts(other, lit.bytes.runeAt(0))
  if isWordType(x) and isWordType(y):
    # Opposites, and only when both read words the same way.
    proc asciiWord(h: HeadLit): bool =
      (h.flags * {rfAsciiWord, rfAsciiPosix}).card > 0

    return x.node.charType != y.node.charType and asciiWord(x) == asciiWord(y)
  var members: set[uint8]
  var plain: bool
  if isWordType(x) or isWordType(y):
    let (cls, word) =
      if isWordType(y):
        (x, y)
      else:
        (y, x)
    if not asciiView(cls, members, plain) or not plain:
      return false
    return
      if word.node.charType == ctWord:
        (members * AsciiWordBytes).card == 0
      else:
        members <= AsciiWordBytes
  var others: set[uint8]
  var otherPlain: bool
  if not asciiView(x, members, plain) or not asciiView(y, others, otherPlain):
    return false
  (plain or otherPlain) and (members * others).card == 0

proc onigPossessifies(q, next: Node, flags: RegexFlags): bool =
  ## Oniguruma's ``tune_next``: a greedy unbounded repeat with a lower bound of
  ## at most one, over one character or a string, followed by something it can
  ## never be the start of, becomes ``(?>x*)`` -- before the look-behind
  ## reduction runs, and an atomic group is not a repeat the reduction pins.
  ## So ``(?<=a*b)`` keeps its ``a*`` there.
  if next == nil or q.quantKind != qkGreedy:
    return false
  let (lo, hi) = effectiveQuantBounds(q.quantMin, q.quantMax)
  if hi >= 0 or lo > 1:
    return false
  let body = peelBareGroups(q.quantBody)
  if body == nil or
      body.kind notin {nkLiteral, nkEscapedLiteral, nkString, nkCharClass, nkCharType}:
    return false
  let x = onigHeadLiteral(body, flags)
  let y = onigHeadLiteral(next, flags)
  x.kind != hkNone and y.kind != hkNone and onigExclusive(x, y)

proc pinsRepeat(q, next: Node, flags: RegexFlags, fastPath: bool): bool =
  ## Whether the reduction pins repeat ``q`` to its lower bound, ``next``
  ## being what follows it in the sequence: ``node_reduce_in_look_behind``
  ## pins a repeat over a simple body ([isSimpleRepeatBody]) unless
  ## ``tune_next`` has made it possessive ([onigPossessifies]) or case
  ## folding has unravelled the body ([foldSegments]).  ``fastPath`` pins
  ## those too; see [tuneLookBehind] for why that changes no answer.
  let body = peelBareGroups(q.quantBody)
  if q.quantKind == qkPossessive or not isSimpleRepeatBody(body) or
      foldSegments(body, flags) != 1:
    return false
  fastPath or not onigPossessifies(q, next, flags)

proc reduceFront(list, follow: Node, flags: RegexFlags, fastPath: bool): bool =
  ## ``list_reduce_in_look_behind`` over the sequence ``list``: pin its
  ## leading repeats ([pinsRepeat]) up to the first that does not empty, and
  ## answer whether every element emptied.  Oniguruma's parser splices a
  ## ``(?:...)`` sequence into the one it stands in except as the first
  ## element, and keeps an empty group as a node of its own, so the walk
  ## stops at either -- ``a*(?:b*c)`` pins both repeats, ``(?:b*c)a*``
  ## neither.  ``follow`` is what comes after a spliced sequence, for its
  ## last element's ``next``.
  for i in 0 ..< list.children.len:
    let next =
      if i + 1 < list.children.len:
        list.children[i + 1]
      else:
        follow
    let peeled = peelBareGroups(list.children[i])
    if peeled == nil:
      return false
    case peeled.kind
    of nkConcat:
      if i == 0 or peeled.children.len == 0 or
          not reduceFront(peeled, next, flags, fastPath):
        return false
    of nkQuantifier:
      if not pinsRepeat(peeled, next, flags, fastPath):
        return false
      peeled.quantMax = peeled.quantMin
      if peeled.quantMin != 0:
        return false
    else:
      return false
  true

proc reduceBranch(branch: Node, flags: RegexFlags, fastPath: bool) =
  ## The reduction over one branch of a look-behind body: a repeat on its
  ## own, or the front of a sequence.  Not into an alternation, which only a
  ## look-behind of its own reduces, once Oniguruma has divided one off.
  let peeled = peelBareGroups(branch)
  if peeled == nil:
    return
  case peeled.kind
  of nkQuantifier:
    if pinsRepeat(peeled, nil, flags, fastPath):
      peeled.quantMax = peeled.quantMin
  of nkConcat:
    discard reduceFront(peeled, nil, flags, fastPath)
  else:
    discard

proc reduceBody(body: Node, flags: RegexFlags, fastPath: bool) =
  ## ``alt_reduce_in_look_behind``: [reduceBranch] over each branch of a body
  ## that is an alternation, or over the body as its one branch.  Must run
  ## after ``tuneRepeats``, whose shapes it reads, and before
  ## ``annotateContinuations``, whose possessives it would skip.
  let peeled = peelBareGroups(body)
  if peeled != nil and peeled.kind == nkAlternation:
    for alt in peeled.alternatives.view:
      reduceBranch(alt, flags, fastPath)
  else:
    reduceBranch(body, flags, fastPath)

proc usesCaptures(node: Node, g: var GroupSpans): bool =
  ## Oniguruma's ``used`` (``check_node_in_look_behind``): whether the body
  ## holds a group something refers to, a ``\K``, or a call.  A recursive call
  ## is what sets it there; any call counts here, which keeps the look-behind.
  if node == nil:
    return false
  case node.kind
  of nkCapture, nkNamedCapture:
    ensureGroups(g)
    let idx = if node.kind == nkCapture: node.captureIndex else: node.namedCaptureIndex
    if idx < g.referenced.len and g.referenced[idx]:
      return true
  of nkAnchor:
    return node.anchor == akKeep
  of nkSubexpCall:
    return true
  else:
    discard
  for child in node.childNodes:
    if usesCaptures(child, g):
      return true
  false

proc surelyEmpty(s: CharSpan, used: bool): bool {.inline.} =
  ## Whether Oniguruma drops a positive look-behind whose reduced body
  ## measures ``s``: one that surely matches empty and keeps nothing anyone
  ## reads always holds, so ``tune_look_behind`` replaces it with an empty
  ## node -- and a group in it is never set, though the body could have
  ## matched through it.
  s.lo == 0 and s.sure and not used

type Branches = object
  ## The branches of a reduced look-behind body that is an alternation, as
  ## ``tune_look_behind`` reads them: each one's [charSpan], and whether it
  ## holds anything anyone reads ([usesCaptures]).
  spans: seq[CharSpan]
  used: seq[bool]

proc measure(alt: Node, g: var GroupSpans): Branches =
  ## [Branches] of the alternation ``alt``, its branches reduced already.
  for branch in alt.alternatives.view:
    result.spans.add charSpan(branch, g)
    result.used.add usesCaptures(branch, g)

proc dropped(b: Branches): bool =
  ## [surelyEmpty] over the alternation as a whole.
  var whole = spanOf(0, sure = false)
  for i, s in b.spans:
    whole =
      if i == 0:
        s
      else:
        either(whole, s)
  surelyEmpty(whole, true in b.used)

proc divides(b: Branches): bool =
  ## Whether Oniguruma divides a look-behind whose body is this alternation
  ## into one look-behind per branch, ``(?<=A|B)`` into ``(?<=A)|(?<=B)``
  ## (``divide_look_behind_alternatives``).  It does when ``node_char_len``
  ## answers ``CHAR_LEN_TOP_ALT_FIXED``: every branch after the first has a
  ## fixed length, the first is not checked, and the lengths are not all the
  ## same.  Lengths are in characters, so ``a|é`` stays whole.
  if b.spans.len < 2:
    return false
  var all = b.spans[0]
  for i in 1 ..< b.spans.len:
    if not b.spans[i].fixed:
      return false
    all = either(all, b.spans[i])
  not all.fixed

proc addDivided(
    flat: var seq[Node],
    branch: Node,
    span: CharSpan,
    used: bool,
    g: var GroupSpans,
    flags: RegexFlags,
) =
  ## Add what ``branch`` of a divided look-behind ends as.  Oniguruma tunes
  ## each branch as a look-behind of its own, so one may be dropped
  ## ([surelyEmpty]) -- left here as an empty branch, which holds the same
  ## way -- or be reduced and divide again, its branches taking its place in
  ## the order they are tried.  Only the first branch can divide again: every
  ## later one has a fixed length.
  let inner = peelBareGroups(branch)
  if inner != nil and inner.kind == nkAlternation:
    # Its own branches were never reduced, so ``span`` is not what Oniguruma
    # measures it by now.
    reduceBody(inner, flags, fastPath = false)
    let b = measure(inner, g)
    if dropped(b):
      flat.add Node(kind: nkConcat, children: @[])
    elif divides(b):
      for k, alt in inner.alternatives.view:
        addDivided(flat, alt, b.spans[k], b.used[k], g, flags)
    else:
      flat.add branch
  elif surelyEmpty(span, used):
    flat.add Node(kind: nkConcat, children: @[])
  else:
    flat.add branch

proc tuneLookBehind(node: Node, g: var GroupSpans, flags: RegexFlags) =
  ## Give the positive look-behind ``node`` the shape ``tune_look_behind``
  ## leaves it in: its body reduced ([reduceBody]), then dropped
  ## ([surelyEmpty]), divided ([divides], recorded as ``lookDivided``), or
  ## kept whole.
  ##
  ## Then the fast path: a repeat that ``tune_next`` made possessive is pinned
  ## too, where Oniguruma keeps it.  That changes no answer: what follows such
  ## a repeat can never begin where the repeat does, so the body matches from
  ## the same latest start with the same captures either way, and the pinned
  ## length only decides whether a window clips it -- which only a ``\b`` at
  ## the start of the subject could tell.  So ``(?<=\s*:)`` is a
  ## one-character body, with no start to scan for.
  ensureGroups(g)
  reduceBody(node.lookBody, flags, fastPath = false)
  let peeled = peelBareGroups(node.lookBody)
  if peeled != nil and peeled.kind == nkAlternation:
    let b = measure(peeled, g)
    if dropped(b):
      node[] = Node(kind: nkConcat, children: @[])[]
      return
    if divides(b):
      var flat: seq[Node]
      for k, alt in peeled.alternatives.view:
        addDivided(flat, alt, b.spans[k], b.used[k], g, flags)
      peeled.alternatives = flat
      node.lookDivided = true
      for alt in peeled.alternatives.view:
        reduceBody(alt, flags, fastPath = true)
      return
  elif surelyEmpty(charSpan(node.lookBody, g), usesCaptures(node.lookBody, g)):
    node[] = Node(kind: nkConcat, children: @[])[]
    return
  reduceBody(node.lookBody, flags, fastPath = true)

proc reduceNegLookBehind(body: Node, flags: RegexFlags) =
  ## The reduction over a negative look-behind's body, fast path included.
  ## No shape is decided here: dropping one fails it, which a body that
  ## surely matches empty does already, and the matcher runs each branch of
  ## one as a look-behind of its own (``negLookbehindHolds``), so a branch
  ## that is an alternation is reduced as a body in turn.
  reduceBody(body, flags, fastPath = true)
  let peeled = peelBareGroups(body)
  if peeled != nil and peeled.kind == nkAlternation:
    for alt in peeled.alternatives.view:
      let inner = peelBareGroups(alt)
      if inner != nil and inner.kind == nkAlternation:
        reduceNegLookBehind(inner, flags)

proc tuneLookBehindsIn(node: Node, g: var GroupSpans, flags: RegexFlags) =
  ## [tuneLookBehind] or [reduceNegLookBehind] over every look-behind under
  ## ``node``, innermost first: ``tune_look_behind`` tunes a body before it
  ## measures it, so a look-behind inside is dropped by then, and
  ## ``(?<=(b)|(?<=a*))`` is dropped whole.  ``flags`` are those in force
  ## where ``node`` sits, threaded as [annotateLookaroundBounds] threads
  ## them: they decide what Oniguruma's possessive rewrite compares and how
  ## it unravels a string.
  if node == nil:
    return
  case node.kind
  of nkLookaround:
    tuneLookBehindsIn(node.lookBody, g, flags)
    case node.lookKind
    of lkBehind:
      tuneLookBehind(node, g, flags)
    of lkNegBehind:
      reduceNegLookBehind(node.lookBody, flags)
    else:
      discard
  of nkFlagGroup:
    tuneLookBehindsIn(node.flagBody, g, flags + node.flagsOn - node.flagsOff)
  else:
    for child in node.childNodes:
      tuneLookBehindsIn(child, g, flags)

proc tuneLookBehinds*(ast: Node, names: seq[(string, int)], flags: RegexFlags) =
  ## Give every look-behind in ``ast`` the shape Oniguruma leaves it in (see
  ## the module documentation).  ``names`` maps each capture name to its
  ## group, for the references and calls a body is measured through.  Must
  ## run where [reduceBody] says: before every pass that reads a look-behind's
  ## bounds, since a reduced body may become fixed-length.
  var g = initGroupSpans(ast, names)
  tuneLookBehindsIn(ast, g, flags)
