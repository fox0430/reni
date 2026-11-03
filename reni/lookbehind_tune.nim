## How Oniguruma reshapes a look-behind body before it compiles it
## (``tune_look_behind``).  [tuneLookBehinds] gives every look-behind the
## shape Oniguruma leaves it in, innermost first: the body's leading repeats
## pinned to their lower bound ([reduceBody]), then the positive look-behind
## dropped, divided into one look-behind per branch (``lookDivided``, which
## the matcher retries), or kept whole, on the lengths of that reduced body
## ([tuneLookBehind]).  A negative one is divided only where a window could
## tell ([tuneNegLookBehind]).  Either is rejected where that body may take
## more characters than Oniguruma steps back over, or where a piece it
## divides into may ([checkLength], [checkLengths]).
##
## The decisions read a model of Oniguruma's tree -- lengths in characters,
## ``min_is_sure``, the possessive rewrite and the case-fold unravelling that
## run before its reduction -- which nothing else in the compiler reads.  Its
## own module for that reason.

import std/unicode

import types, unicode_utils, stackguard, leafgate

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
    unravel: bool
      ## Whether a backreference or a call reads its group as unravelled
      ## ([refSpan]); set by [tuneLookBehinds] only, whose ``flags`` are
      ## ``rootFlags``.
    rootFlags: RegexFlags
    groupFlags: seq[RegexFlags]
    groupBehind: seq[bool]
      ## By group: the flags in force at it, which its body is measured
      ## under, and whether it sits in a look-behind.  Collected with the
      ## bodies.
    uneven: seq[int8] ## By group: whether it [unravels], 1 or 0, -1 until asked.
    clusterModes: bool
      ## Whether the pattern sets ``(?y{g})`` or ``(?y{w})`` anywhere, for
      ## [takesClusters].  Collected with the bodies.

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
  collectGroupBodies(g.root, g.bodies, g.groupFlags, g.rootFlags)
  g.spans = newSeq[CharSpan](g.bodies.len)
  g.measured = newSeq[bool](g.bodies.len)
  g.visiting = newSeq[bool](g.bodies.len)
  g.referenced = newSeq[bool](g.bodies.len)
  g.groupBehind = newSeq[bool](g.bodies.len)
  g.uneven = newSeq[int8](g.bodies.len)
  for u in g.uneven.mitems:
    u = -1
  proc mark(g: var GroupSpans, idx: int) =
    if idx >= 0 and idx < g.referenced.len:
      g.referenced[idx] = true

  proc markName(g: var GroupSpans, name: string, scope: int32) =
    for idx in g.names.namedGroupsRead(name, scope):
      mark(g, idx)

  proc walk(g: var GroupSpans, node: Node, behind: bool) =
    if node == nil:
      return
    var inner = behind
    case node.kind
    of nkCapture:
      g.groupBehind[node.captureIndex] = behind
    of nkNamedCapture:
      g.groupBehind[node.namedCaptureIndex] = behind
    of nkLookaround:
      inner = behind or node.lookKind in {lkBehind, lkNegBehind}
    of nkFlagGroup:
      if node.graphemeMode in {gmGrapheme, gmWord}:
        g.clusterModes = true
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
      walk(g, child, inner)

  walk(g, g.root, false)

proc charSpan(node: Node, g: var GroupSpans, flags: RegexFlags): CharSpan

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
    var s = charSpan(g.bodies[idx], g, g.groupFlags[idx])
    dec g.open
    g.visiting[idx] = false
    s.sure = false
    g.spans[idx] = s
    g.measured[idx] = true
  g.spans[idx]

proc unravels(node: Node, flags: RegexFlags, behind: bool): bool =
  ## Whether Oniguruma's case-fold unravelling turns something in ``node``
  ## into branches of different lengths: a ``(?i)`` string outside a
  ## look-behind that [foldsUnevenly].  One inside is unravelled one
  ## character for one (``unravel_cf_look_behind_add``), and a class its
  ## parser makes branches of [charSpan] measures already.  A look-around
  ## takes no characters, and a reference or a call is measured on its own.
  if node == nil:
    return false
  case node.kind
  of nkLiteral:
    not behind and foldsAboveAscii(flags) and foldsUnevenly([node.rune])
  of nkEscapedLiteral:
    not behind and foldsAboveAscii(flags) and foldsUnevenly([node.escapedRune])
  of nkString:
    not behind and foldsAboveAscii(flags) and foldsUnevenly(node.runes)
  of nkFlagGroup:
    unravels(node.flagBody, flags + node.flagsOn - node.flagsOff, behind)
  of nkConcat:
    var current = flags
    for child in node.children.view:
      if child.kind == nkFlagGroup and child.flagBody == nil:
        current = current + child.flagsOn - child.flagsOff
      elif unravels(child, current, behind):
        return true
    false
  of nkLookaround, nkBackreference, nkNamedBackref, nkSubexpCall:
    false
  else:
    for child in node.childNodes:
      if unravels(child, flags, behind):
        return true
    false

proc refSpan(g: var GroupSpans, idx: int): CharSpan =
  ## [groupSpan] as a backreference or a call reads group ``idx``: unbounded
  ## as well when the group [unravels], as Oniguruma measures it once its own
  ## tuning has made ``(?i)(ß)`` into ``(ß|ss)``.  Its text can then hold
  ## another number of characters than the group's pattern does, and a call
  ## runs the unravelled body: ``node_char_len1`` measures the group's node
  ## for either.
  result = groupSpan(g, idx)
  if not g.unravel or not result.fixed or idx < 0 or idx >= g.bodies.len:
    return
  if g.uneven[idx] < 0:
    g.uneven[idx] =
      if unravels(g.bodies[idx], g.groupFlags[idx], g.groupBehind[idx]): 1 else: 0
  if g.uneven[idx] == 1:
    result.hi = -1

proc namedGroupSpan(g: var GroupSpans, name: string, scope: int32): CharSpan =
  ## Any of the groups called ``name`` that a reference in ``scope`` reads
  ## ([namedGroupsRead]), each as [refSpan] measures it, as a backreference
  ## to a name that several groups share reads any one of them.
  ensureGroups(g)
  var first = true
  for idx in g.names.namedGroupsRead(name, scope):
    let s = refSpan(g, idx)
    result =
      if first:
        s
      else:
        either(result, s)
    first = false
  if first:
    result = CharSpan(lo: 0, hi: -1)

proc repeatBodySpan(q: Node, g: var GroupSpans, flags: RegexFlags): CharSpan =
  ## [charSpan] of repeat ``q``'s body, kept by [NodeId] when
  ## [initGroupSpans] was given the numbering.  A repeat inside another is
  ## then measured once, not again for every repeat around it.  Nothing is
  ## kept or read while a group is being measured: a reference back into
  ## that group reads as unbounded there (see [groupSpan]), and the same
  ## body measured from outside it reads it in full.  What is kept was
  ## measured under the ``flags`` of the first ask -- ``(?:(?i:[sß]*))*``
  ## keeps the inner repeat as measured under ``(?i)`` -- and only
  ## [repeatBodyMayBeEmpty] keeps any, which reads ``lo`` alone.
  let id = q.id.int
  let keep = g.open == 0 and id > 0 and id < g.bodyKnown.len
  if keep and g.bodyKnown[id]:
    return g.bodySpans[id]
  result = charSpan(q.quantBody, g, flags)
  if keep:
    g.bodySpans[id] = result
    g.bodyKnown[id] = true

proc charSpan(node: Node, g: var GroupSpans, flags: RegexFlags): CharSpan =
  ## Oniguruma's ``node_char_len1`` over this tree, which sits where
  ## ``flags`` are in force.  ``\R`` and ``\X`` are subexpressions there, of
  ## one to two characters and of one or more, and so is a ``(?i)`` class
  ## holding a character with a fold of several ([classHoldsFoldSource]):
  ## its parser makes ``[sß]`` the class or ``ss``, wherever it stands.
  ## Where the two trees part ways, the answer leans to ``sure == false``,
  ## which keeps a look-behind rather than dropping it.
  if node == nil:
    return spanOf(0)
  # A group is measured through the calls and references in it, and a chain
  # of those is as long as the pattern.
  if nearStackEnd(g.stackBase):
    raise newException(RegexLimitError, "compile stack budget exceeded")
  case node.kind
  of nkLiteral, nkEscapedLiteral:
    spanOf(1)
  of nkCharClass:
    if classHoldsFoldSource(node, flags):
      # ``hi`` is read only to ask whether a span is fixed and whether it
      # passes [LookBehindMaxChars], so the longest fold goes unmeasured, as
      # in [refSpan], and ``(?i)(?<=[ß]{40000})`` passes the cap there,
      # where Oniguruma measures 80,000.
      CharSpan(lo: 1, hi: -1, sure: true)
    else:
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
    var current = flags
    for child in node.children.view:
      # A bare flag group sets the flags for the rest, as in [unravels].
      if child.kind == nkFlagGroup and child.flagBody == nil:
        current = current + child.flagsOn - child.flagsOff
      else:
        s = s + charSpan(child, g, current)
    s
  of nkAlternation:
    var s = spanOf(0)
    for i, alt in node.alternatives.view:
      let a = charSpan(alt, g, flags)
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
      repeatBodySpan(node, g, flags).repeated(lo, hi)
  of nkCapture:
    groupSpan(g, node.captureIndex)
  of nkNamedCapture:
    groupSpan(g, node.namedCaptureIndex)
  of nkGroup:
    charSpan(node.groupBody, g, flags)
  of nkFlagGroup:
    charSpan(node.flagBody, g, flags + node.flagsOn - node.flagsOff)
  of nkAtomicGroup:
    charSpan(node.atomicBody, g, flags)
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
      refSpan(g, node.backrefIndex - 1)
  of nkNamedBackref:
    if node.namedBackrefLevel != 0:
      CharSpan(lo: 0, hi: -1)
    else:
      namedGroupSpan(g, node.backrefName, node.backrefScope)
  of nkSubexpCall:
    if node.callIndex > 0:
      refSpan(g, node.callIndex - 1)
    elif node.callName.len > 0:
      namedGroupSpan(g, node.callName, EveryNamedGroup)
    else:
      CharSpan(lo: 0, hi: -1) # ``\g<0>``: the whole pattern, recursively
  of nkConditional:
    let test =
      if node.condKind == ckRegexCond:
        charSpan(node.condBody, g, flags)
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
      either(test + charSpan(node.condYes, g, flags), charSpan(node.condNo, g, flags))
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
  ##
  ## Measured under no flags: they decide whether a class is fixed
  ## ([charSpan]), never ``lo``.
  repeatBodySpan(q, g, {}).lo == 0

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
      if plain and foldsAboveAscii(flags):
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

const LookBehindMaxChars = 65_535
  ## Oniguruma's ``LOOK_BEHIND_MAX_CHAR_LEN``, the most characters a
  ## look-behind body may take, so that ``onigenc_step_back`` cannot
  ## overflow.

proc checkLength(s: CharSpan) =
  ## Reject a look-behind whose reduced body measures ``s`` where that may
  ## run past [LookBehindMaxChars], as ``tune_look_behind`` does before it
  ## drops or divides one: ``(?<=a{65536})``, ``(?<=(?:a{65536})?)``, which
  ## would drop, and ``(?<=b|a{65536})``, which would divide.  Positive or
  ## negative alike.  A body that divides has each piece checked as well
  ## ([checkLengths]).
  if s.lo > LookBehindMaxChars or s.hi > LookBehindMaxChars:
    raise newException(RegexError, "invalid pattern in look-behind")

type Branches = object
  ## The branches of a reduced look-behind body that is an alternation, as
  ## ``tune_look_behind`` reads them: each one's [charSpan], and whether it
  ## holds anything anyone reads ([usesCaptures]).
  spans: seq[CharSpan]
  used: seq[bool]

proc measure(alt: Node, g: var GroupSpans, flags: RegexFlags): Branches =
  ## [Branches] of the alternation ``alt``, its branches reduced already.
  for branch in alt.alternatives.view:
    result.spans.add charSpan(branch, g, flags)
    result.used.add usesCaptures(branch, g)

proc whole(b: Branches): CharSpan =
  ## The [charSpan] of the alternation as a whole.
  result = spanOf(0, sure = false)
  for i, s in b.spans:
    result =
      if i == 0:
        s
      else:
        either(result, s)

proc dropped(b: Branches): bool =
  ## [surelyEmpty] over the alternation as a whole.
  surelyEmpty(b.whole, true in b.used)

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

proc checkLengths(alt: Node, b: Branches, g: var GroupSpans, flags: RegexFlags) =
  ## [checkLength] over the look-behind body ``alt``, an alternation measured
  ## ``b``, and over each look-behind ``tune_look_behind`` divides it into,
  ## as it tunes each again.  ``(?<=xy*|a{65536})`` passes as a whole, its
  ## first branch unbounded, and then fails as ``(?<=a{65536})``.  Only an
  ## unbounded whole can hide a piece that long, and a body that drops is
  ## never divided: ``(?<=xy*||a{65536})`` compiles.  A branch that is an
  ## alternation is reduced, measured and divided again, as [addDivided]
  ## does.
  checkLength(b.whole)
  if b.whole.hi >= 0 or dropped(b) or not divides(b):
    return
  for k, branch in alt.alternatives.view:
    let inner = peelBareGroups(branch)
    if inner != nil and inner.kind == nkAlternation:
      reduceBody(inner, flags, fastPath = false)
      checkLengths(inner, measure(inner, g, flags), g, flags)
    else:
      checkLength(b.spans[k])

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
    let b = measure(inner, g, flags)
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

proc divide(alt: Node, b: Branches, g: var GroupSpans, flags: RegexFlags) =
  ## Divide the look-behind body ``alt``, an alternation whose [Branches] are
  ## ``b`` ([divides]): each branch is replaced by what it ends as
  ## ([addDivided]).
  var flat: seq[Node]
  for k, branch in alt.alternatives.view:
    addDivided(flat, branch, b.spans[k], b.used[k], g, flags)
  alt.alternatives = flat

proc readsGroup(node: Node): bool =
  ## Whether a backreference or a call sits anywhere in ``node``: what
  ## [lengthBounds] gives no fixed width in bytes where Oniguruma's length in
  ## characters may be fixed, and what then shows the window apart (see
  ## ``charsBackStart`` in ``engine``).
  if node == nil:
    return false
  if node.kind in {nkBackreference, nkNamedBackref, nkSubexpCall}:
    return true
  for child in node.childNodes:
    if readsGroup(child):
      return true
  false

proc dotsIn(node: Node, g: var GroupSpans, seen: var seq[bool]): bool =
  ## [takesClusters]' walk, with ``seen`` holding a slot per group and a last
  ## one for the whole pattern.
  if node == nil:
    return false
  case node.kind
  of nkCharType:
    return node.charType == ctDot
  of nkLookaround:
    return false
  of nkBackreference, nkNamedBackref, nkSubexpCall:
    var targets: seq[int]
    case node.kind
    of nkBackreference:
      targets.add node.backrefIndex - 1
    of nkNamedBackref:
      for idx in g.names.namedGroupsRead(node.backrefName, node.backrefScope):
        targets.add idx
    else:
      if node.callIndex > 0:
        targets.add node.callIndex - 1
      elif node.callName.len > 0:
        for idx in g.names.namedGroupsRead(node.callName, EveryNamedGroup):
          targets.add idx
      else:
        targets.add g.bodies.len # ``\g<0>``
    for idx in targets:
      if idx < 0 or idx > g.bodies.len or seen[idx]:
        continue
      seen[idx] = true
      let body =
        if idx == g.bodies.len:
          g.root
        else:
          g.bodies[idx]
      if dotsIn(body, g, seen):
        return true
    return false
  else:
    discard
  for child in node.childNodes:
    if dotsIn(child, g, seen):
      return true
  false

proc takesClusters(piece: Node, g: var GroupSpans): bool =
  ## Whether a ``.`` may take a whole grapheme cluster where ``piece``
  ## counts it as one character: [charSpan] counts as Oniguruma does, and
  ## under ``(?y{g})`` and ``(?y{w})`` the matcher's ``.`` is a cluster
  ## (``charTypeAdvance`` in ``engine``).  It may be in ``piece``, or in a
  ## group whose text a reference reads or a call runs, under whatever mode
  ## the group ran in.  So in a pattern that sets either mode anywhere, any
  ## ``.`` reached counts, and such a piece keeps its window.  A look-around
  ## takes nothing.
  if not g.clusterModes:
    return false
  var seen = newSeq[bool](g.bodies.len + 1)
  dotsIn(piece, g, seen)

proc stepsBack(piece: Node, span: CharSpan, g: var GroupSpans): int =
  ## [fixedChars] of a ``piece`` that reads a group, measured ``span``:
  ## ``span.lo``, or -1 where that varies, or where a ``.`` may take a
  ## cluster ([takesClusters]) and step over more characters than counted.
  if span.fixed and not takesClusters(piece, g): span.lo else: -1

proc fixedChars(piece: Node, g: var GroupSpans, flags: RegexFlags): int =
  ## The length in characters of the look-behind ``piece``, which Oniguruma
  ## steps back over and runs with no window where the matcher would scan it
  ## under one (``charsBackStart`` in ``engine``), or -1.  Only a piece that
  ## reads a group ([readsGroup]) and whose length in characters is fixed
  ## has one, and only where the matcher steps over as many ([stepsBack]).
  if not readsGroup(piece):
    return -1
  stepsBack(piece, charSpan(piece, g, flags), g)

proc markBranch(node: Node, k, count, chars: int) =
  ## Record in ``lookAlts`` that the matcher runs branch ``k`` of the
  ## ``count`` in the body of look-behind ``node`` from ``chars`` characters
  ## back, with no window.  Nothing to record when ``chars`` is -1.
  if chars < 0:
    return
  if node.lookAlts.len == 0:
    node.lookAlts.setLen(count)
  node.lookAlts[k].unclipped = true
  node.lookAlts[k].chars = int32(chars)

proc markBody(node: Node, chars: int) =
  ## As [markBranch] for the whole body, in ``lookUnclipped`` and
  ## ``lookChars``, which holds any length [checkLength] lets through.
  if chars >= 0:
    node.lookUnclipped = true
    node.lookChars = uint16(chars)

proc tuneLookBehind(node: Node, g: var GroupSpans, flags: RegexFlags, reads: bool) =
  ## Give the positive look-behind ``node`` the shape ``tune_look_behind``
  ## leaves it in: its body reduced ([reduceBody]) and its length checked
  ## ([checkLength], [checkLengths]), then dropped ([surelyEmpty]), divided
  ## ([divides], recorded as ``lookDivided``), or kept whole.  With ``reads``
  ## (the pattern may read a group), each piece of it is measured for
  ## [fixedChars] before the fast path pins it further.
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
  var span: CharSpan
  if peeled != nil and peeled.kind == nkAlternation:
    let b = measure(peeled, g, flags)
    checkLengths(peeled, b, g, flags)
    if dropped(b):
      node[] = Node(kind: nkConcat, children: @[])[]
      return
    if divides(b):
      divide(peeled, b, g, flags)
      node.lookDivided = true
      for k, alt in peeled.alternatives.view:
        if reads:
          markBranch(node, k, peeled.alternatives.len, fixedChars(alt, g, flags))
        reduceBody(alt, flags, fastPath = true)
      return
    span = b.whole
  else:
    span = charSpan(node.lookBody, g, flags)
    checkLength(span)
    if surelyEmpty(span, usesCaptures(node.lookBody, g)):
      node[] = Node(kind: nkConcat, children: @[])[]
      return
  if reads and readsGroup(node.lookBody):
    markBody(node, stepsBack(node.lookBody, span, g))
  reduceBody(node.lookBody, flags, fastPath = true)

proc tuneNegLookBehind(node: Node, g: var GroupSpans, flags: RegexFlags, reads: bool) =
  ## Check the length of the negative look-behind ``node`` ([checkLength],
  ## [checkLengths] over the pieces Oniguruma would divide it into), its body
  ## reduced short of the fast path.  With ``reads``, a body that reads a
  ## group then has the pieces Oniguruma runs from a fixed number of
  ## characters back marked ([fixedChars]), divided as it divides them and
  ## flattened as a positive one is ([addDivided]), since the matcher runs
  ## each branch on its own: a first branch that divides again,
  ## ``(?<!(?:\1|bb)|c)``, gives a piece per branch, each fixed or not on its
  ## own.  An undivided body gives every branch the length of the whole.  A
  ## body that reads no group shows no window apart, and is left undivided,
  ## its pieces only checked.
  reduceBody(node.lookBody, flags, fastPath = false)
  let marks = reads and readsGroup(node.lookBody)
  if marks:
    ensureGroups(g)
  let peeled = peelBareGroups(node.lookBody)
  if marks and peeled != nil and peeled.kind == nkAlternation:
    let b = measure(peeled, g, flags)
    checkLengths(peeled, b, g, flags)
    if divides(b):
      divide(peeled, b, g, flags)
      for k, alt in peeled.alternatives.view:
        markBranch(node, k, peeled.alternatives.len, fixedChars(alt, g, flags))
    elif b.whole.fixed:
      for k, alt in peeled.alternatives.view:
        if readsGroup(alt):
          markBranch(node, k, peeled.alternatives.len, stepsBack(alt, b.whole, g))
  else:
    let span = charSpan(node.lookBody, g, flags)
    checkLength(span)
    if marks:
      markBody(node, stepsBack(node.lookBody, span, g))
    elif span.hi < 0 and peeled != nil and peeled.kind == nkAlternation:
      # Oniguruma divides it even so, and checks each piece.
      checkLengths(peeled, measure(peeled, g, flags), g, flags)

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

proc tuneLookBehindsIn(node: Node, g: var GroupSpans, flags: RegexFlags, reads: bool) =
  ## [tuneLookBehind], or [tuneNegLookBehind] and [reduceNegLookBehind], over
  ## every look-behind under ``node``, innermost first: ``tune_look_behind``
  ## tunes a body before it measures it, so a look-behind inside is dropped
  ## by then, and ``(?<=(b)|(?<=a*))`` is dropped whole.  ``flags`` are those
  ## in force where ``node`` sits, threaded as [annotateLookaroundBounds]
  ## threads them: they decide what Oniguruma's possessive rewrite compares
  ## and how it unravels a string.  ``reads`` as for [tuneLookBehinds].
  if node == nil:
    return
  case node.kind
  of nkLookaround:
    tuneLookBehindsIn(node.lookBody, g, flags, reads)
    case node.lookKind
    of lkBehind:
      tuneLookBehind(node, g, flags, reads)
    of lkNegBehind:
      tuneNegLookBehind(node, g, flags, reads)
      reduceNegLookBehind(node.lookBody, flags)
    else:
      discard
  of nkFlagGroup:
    tuneLookBehindsIn(node.flagBody, g, flags + node.flagsOn - node.flagsOff, reads)
  else:
    for child in node.childNodes:
      tuneLookBehindsIn(child, g, flags, reads)

proc tuneLookBehinds*(
    ast: Node, names: seq[(string, int)], flags: RegexFlags, reads: bool
) =
  ## Give every look-behind in ``ast`` the shape Oniguruma leaves it in (see
  ## the module documentation).  ``names`` maps each capture name to its
  ## group, for the references and calls a body is measured through.
  ## ``reads`` says the pattern may hold a backreference or a call, without
  ## which no look-behind is measured for [fixedChars].  Must run where
  ## [reduceBody] says: before every pass that reads a look-behind's bounds,
  ## since a reduced body may become fixed-length.
  var g = initGroupSpans(ast, names)
  g.unravel = true
  g.rootFlags = flags
  tuneLookBehindsIn(ast, g, flags, reads)
