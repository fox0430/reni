import std/[algorithm, tables, sets, unicode]

import types, unicode_utils, parser, leafgate

proc demoteUnnamedCaptures(node: Node, indexMap: Table[int, int]): Node =
  ## When named captures exist, convert unnamed nkCapture to nkGroup
  ## and renumber nkNamedCapture indices using indexMap (old 0-based → new 0-based).
  if node == nil:
    return nil
  case node.kind
  of nkCapture:
    # Convert to non-capturing group
    Node(kind: nkGroup, groupBody: demoteUnnamedCaptures(node.captureBody, indexMap))
  of nkNamedCapture:
    let newIdx = indexMap[node.namedCaptureIndex]
    Node(
      kind: nkNamedCapture,
      captureName: node.captureName,
      namedCaptureIndex: newIdx,
      namedCaptureBody: demoteUnnamedCaptures(node.namedCaptureBody, indexMap),
    )
  of nkConcat:
    var children = newSeq[Node](node.children.len)
    for i, child in node.children:
      children[i] = demoteUnnamedCaptures(child, indexMap)
    Node(kind: nkConcat, children: children)
  of nkAlternation:
    var alts = newSeq[Node](node.alternatives.len)
    for i, alt in node.alternatives:
      alts[i] = demoteUnnamedCaptures(alt, indexMap)
    Node(kind: nkAlternation, alternatives: alts)
  of nkGroup:
    Node(kind: nkGroup, groupBody: demoteUnnamedCaptures(node.groupBody, indexMap))
  of nkFlagGroup:
    Node(
      kind: nkFlagGroup,
      flagsOn: node.flagsOn,
      flagsOff: node.flagsOff,
      flagBody:
        if node.flagBody != nil:
          demoteUnnamedCaptures(node.flagBody, indexMap)
        else:
          nil,
      graphemeMode: node.graphemeMode,
    )
  of nkQuantifier:
    Node(
      kind: nkQuantifier,
      quantMin: node.quantMin,
      quantMax: node.quantMax,
      quantKind: node.quantKind,
      quantBody: demoteUnnamedCaptures(node.quantBody, indexMap),
    )
  of nkLookaround:
    Node(
      kind: nkLookaround,
      lookKind: node.lookKind,
      lookBody: demoteUnnamedCaptures(node.lookBody, indexMap),
    )
  of nkAtomicGroup:
    Node(
      kind: nkAtomicGroup, atomicBody: demoteUnnamedCaptures(node.atomicBody, indexMap)
    )
  of nkConditional:
    var newRefIdx = node.condRefIndex
    if node.condKind == ckBackref and node.condRefIndex > 0:
      let oldIdx = node.condRefIndex - 1 # 0-based
      if oldIdx in indexMap:
        newRefIdx = indexMap[oldIdx] + 1 # back to 1-based
    Node(
      kind: nkConditional,
      condKind: node.condKind,
      condRefIndex: newRefIdx,
      condRefName: node.condRefName,
      condYes: demoteUnnamedCaptures(node.condYes, indexMap),
      condNo: demoteUnnamedCaptures(node.condNo, indexMap),
      condBody: demoteUnnamedCaptures(node.condBody, indexMap),
    )
  of nkBackreference:
    # Update index: old 1-based → map via 0-based → new 1-based
    var newIdx = node.backrefIndex
    let oldIdx = node.backrefIndex - 1
    if oldIdx in indexMap:
      newIdx = indexMap[oldIdx] + 1
    Node(kind: nkBackreference, backrefIndex: newIdx, backrefLevel: node.backrefLevel)
  of nkSubexpCall:
    var newCallIndex = node.callIndex
    if node.callIndex > 0:
      let oldIdx = node.callIndex - 1
      if oldIdx in indexMap:
        newCallIndex = indexMap[oldIdx] + 1
    Node(kind: nkSubexpCall, callIndex: newCallIndex, callName: node.callName)
  of nkAbsent:
    Node(
      kind: nkAbsent,
      absentKind: node.absentKind,
      absentBody: demoteUnnamedCaptures(node.absentBody, indexMap),
      absentExpr: demoteUnnamedCaptures(node.absentExpr, indexMap),
    )
  else:
    # Leaf nodes: nkLiteral, nkEscapedLiteral, nkCharType, nkCharClass,
    # nkAnchor, nkNamedBackref — no transformation needed
    node

proc resolveForwardRefConditions(node: Node, namedCaptures: seq[(string, int)]) =
  ## Resolve conditional forward references: when ckRegexCond has a condName
  ## matching a named capture, convert it to ckNamedRef.
  if node == nil:
    return
  if node.kind == nkConditional and node.condKind == ckRegexCond and
      node.condRefName.len > 0:
    for (name, _) in namedCaptures:
      if name == node.condRefName:
        node.condKind = ckNamedRef
        node.condBody = nil
        break
  for child in node.childNodes:
    resolveForwardRefConditions(child, namedCaptures)

proc collectGroupBodies(
    node: Node,
    bodies: var seq[Node],
    flags: var seq[RegexFlags],
    currentFlags: RegexFlags = {},
) =
  ## Walk AST to collect capture group bodies and their definition-time flags.
  if node == nil:
    return
  var activeFlags = currentFlags
  case node.kind
  of nkCapture:
    if node.captureIndex >= bodies.len:
      bodies.setLen(node.captureIndex + 1)
      flags.setLen(node.captureIndex + 1)
    bodies[node.captureIndex] = node.captureBody
    flags[node.captureIndex] = activeFlags
  of nkNamedCapture:
    if node.namedCaptureIndex >= bodies.len:
      bodies.setLen(node.namedCaptureIndex + 1)
      flags.setLen(node.namedCaptureIndex + 1)
    bodies[node.namedCaptureIndex] = node.namedCaptureBody
    flags[node.namedCaptureIndex] = activeFlags
  of nkFlagGroup:
    activeFlags = activeFlags + node.flagsOn - node.flagsOff
  else:
    discard
  for child in node.childNodes:
    collectGroupBodies(child, bodies, flags, activeFlags)

proc validateUtf8(s: string) =
  ## Check that the pattern string is valid UTF-8.
  ## Rejects overlong encodings, surrogate codepoints, and values > U+10FFFF.
  var i = 0
  while i < s.len:
    let b = s[i].uint8
    var seqLen: int
    if b <= 0x7F:
      seqLen = 1
    elif b >= 0xC2 and b <= 0xDF:
      # 2-byte: U+0080..U+07FF (0xC0/0xC1 would be overlong)
      seqLen = 2
    elif b >= 0xE0 and b <= 0xEF:
      seqLen = 3
    elif b >= 0xF0 and b <= 0xF4:
      seqLen = 4
    else:
      raise newException(RegexError, "invalid code point value")
    if i + seqLen > s.len:
      raise newException(RegexError, "invalid code point value")
    for j in 1 ..< seqLen:
      if (s[i + j].uint8 and 0xC0) != 0x80:
        raise newException(RegexError, "invalid code point value")
    if seqLen == 3:
      # Reject overlong 3-byte (< U+0800) and surrogates (U+D800..U+DFFF)
      let cp =
        (uint32(b and 0x0F) shl 12) or (uint32(s[i + 1].uint8 and 0x3F) shl 6) or
        uint32(s[i + 2].uint8 and 0x3F)
      if cp < 0x0800 or (cp >= 0xD800 and cp <= 0xDFFF):
        raise newException(RegexError, "invalid code point value")
    elif seqLen == 4:
      # Reject overlong 4-byte (< U+10000) and > U+10FFFF
      let cp =
        (uint32(b and 0x07) shl 18) or (uint32(s[i + 1].uint8 and 0x3F) shl 12) or
        (uint32(s[i + 2].uint8 and 0x3F) shl 6) or uint32(s[i + 3].uint8 and 0x3F)
      if cp < 0x10000 or cp > 0x10FFFF:
        raise newException(RegexError, "invalid code point value")
    i += seqLen

proc canMatchEmpty(node: Node): bool =
  ## Check if a node can match without consuming input (conservative).
  if node == nil:
    return true
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkString, nkCharType, nkCharClass, nkBackreference,
      nkNamedBackref:
    false
  of nkConcat:
    for child in node.children:
      if not canMatchEmpty(child):
        return false
    true
  of nkAlternation:
    for alt in node.alternatives:
      if canMatchEmpty(alt):
        return true
    false
  of nkQuantifier:
    # Inverted range behaves swapped (``{2,0}`` like ``{0,2}``): use the
    # effective minimum.
    effectiveQuantBounds(node.quantMin, node.quantMax).lo == 0 or
      canMatchEmpty(node.quantBody)
  of nkCapture:
    canMatchEmpty(node.captureBody)
  of nkNamedCapture:
    canMatchEmpty(node.namedCaptureBody)
  of nkGroup:
    canMatchEmpty(node.groupBody)
  of nkFlagGroup:
    node.flagBody == nil or canMatchEmpty(node.flagBody)
  of nkAnchor, nkLookaround, nkAbsent, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    true # zero-width
  of nkAtomicGroup:
    canMatchEmpty(node.atomicBody)
  of nkConditional:
    # Either branch matching empty is enough, and with no else-branch a false
    # condition matches empty by itself.
    if node.condNo == nil:
      true
    else:
      canMatchEmpty(node.condYes) or canMatchEmpty(node.condNo)
  of nkSubexpCall:
    true # conservative: assume it can match empty

proc hasRecursiveCycle(
    startIdx: int,
    node: Node,
    bodies: seq[Node],
    namedCaptures: seq[(string, int)],
    visiting: var HashSet[int],
): bool =
  ## Return true when evaluating ``node`` unconditionally reaches ``startIdx``
  ## through a subexpression-call chain without consuming input — direct
  ## (``(?<a>(?&a))``) or mutual (``(?<a>(?&b))(?<b>(?&a))``) recursion.
  if node == nil:
    return false
  case node.kind
  of nkSubexpCall:
    var callIdx = -1
    if node.callIndex > 0:
      callIdx = node.callIndex - 1
    elif node.callName.len > 0:
      for (name, i) in namedCaptures:
        if name == node.callName:
          callIdx = i
          break
    if callIdx < 0:
      return false
    if callIdx == startIdx:
      return true
    if callIdx in visiting:
      # Already on the DFS stack through a different path — the cycle, if any,
      # would have been detected on that frame. Treat as non-recursive here.
      return false
    visiting.incl(callIdx)
    let hit =
      if callIdx < bodies.len and bodies[callIdx] != nil:
        hasRecursiveCycle(startIdx, bodies[callIdx], bodies, namedCaptures, visiting)
      else:
        false
    visiting.excl(callIdx)
    hit
  of nkConcat:
    for child in node.children:
      if hasRecursiveCycle(startIdx, child, bodies, namedCaptures, visiting):
        return true
      if not canMatchEmpty(child):
        return false
    false
  of nkAlternation:
    for alt in node.alternatives:
      if not hasRecursiveCycle(startIdx, alt, bodies, namedCaptures, visiting):
        return false
    node.alternatives.len > 0
  of nkCapture:
    hasRecursiveCycle(startIdx, node.captureBody, bodies, namedCaptures, visiting)
  of nkNamedCapture:
    hasRecursiveCycle(startIdx, node.namedCaptureBody, bodies, namedCaptures, visiting)
  of nkGroup:
    hasRecursiveCycle(startIdx, node.groupBody, bodies, namedCaptures, visiting)
  of nkFlagGroup:
    if node.flagBody == nil:
      false
    else:
      hasRecursiveCycle(startIdx, node.flagBody, bodies, namedCaptures, visiting)
  of nkAtomicGroup:
    hasRecursiveCycle(startIdx, node.atomicBody, bodies, namedCaptures, visiting)
  of nkQuantifier:
    # Effective min == 0 skips the body and never forces recursion.
    if effectiveQuantBounds(node.quantMin, node.quantMax).lo == 0:
      false
    else:
      hasRecursiveCycle(startIdx, node.quantBody, bodies, namedCaptures, visiting)
  of nkConditional:
    if node.condYes != nil and
        hasRecursiveCycle(startIdx, node.condYes, bodies, namedCaptures, visiting):
      if node.condNo != nil:
        return hasRecursiveCycle(startIdx, node.condNo, bodies, namedCaptures, visiting)
      # condNo is nil. The nil branch matches empty when the condition is
      # false — but if the condition is guaranteed true (a backref whose
      # target can match empty), the yes branch is always taken.
      if node.condKind == ckBackref:
        let refIdx = node.condRefIndex - 1
        if refIdx >= 0 and refIdx < bodies.len and bodies[refIdx] != nil:
          if canMatchEmpty(bodies[refIdx]):
            return true
    false
  else:
    false

proc containsAbsent(
    node: Node,
    bodies: seq[Node],
    namedCaptures: seq[(string, int)],
    visited: var HashSet[int],
): bool =
  ## Check if a node transitively contains non-clear absent expressions.
  if node == nil:
    return false
  case node.kind
  of nkAbsent:
    return node.absentKind != abClear
  of nkSubexpCall:
    # Resolve the call target and check its body
    var idx = -1
    if node.callIndex > 0:
      idx = node.callIndex - 1
    elif node.callName.len > 0:
      for (name, i) in namedCaptures:
        if name == node.callName:
          idx = i
          break
    if idx >= 0 and idx < bodies.len and bodies[idx] != nil:
      if idx notin visited:
        visited.incl(idx)
        return containsAbsent(bodies[idx], bodies, namedCaptures, visited)
    return false
  else:
    discard
  for child in node.childNodes:
    if containsAbsent(child, bodies, namedCaptures, visited):
      return true
  false

proc validateLookbehinds(
    node: Node, bodies: seq[Node], namedCaptures: seq[(string, int)], inLookbehind: bool
) =
  ## Check that lookbehinds don't contain absent expressions through subexp calls.
  if node == nil:
    return
  case node.kind
  of nkLookaround:
    let isLB = node.lookKind in {lkBehind, lkNegBehind}
    validateLookbehinds(node.lookBody, bodies, namedCaptures, inLookbehind or isLB)
    return
  of nkSubexpCall:
    if inLookbehind:
      var idx = -1
      if node.callIndex > 0:
        idx = node.callIndex - 1
      elif node.callName.len > 0:
        for (name, i) in namedCaptures:
          if name == node.callName:
            idx = i
            break
      if idx >= 0 and idx < bodies.len and bodies[idx] != nil:
        var visited = initHashSet[int]()
        if containsAbsent(bodies[idx], bodies, namedCaptures, visited):
          raise newException(RegexError, "invalid pattern in look-behind")
    return
  else:
    discard
  for child in node.childNodes:
    validateLookbehinds(child, bodies, namedCaptures, inLookbehind)

proc validateNoNumberedRefs(node: Node) =
  ## Oniguruma: when named captures exist, numbered backrefs/calls are forbidden.
  if node == nil:
    return
  case node.kind
  of nkBackreference:
    raise newException(RegexError, "numbered backref/call is not allowed. (use name)")
  of nkSubexpCall:
    if node.callName == "":
      raise newException(RegexError, "numbered backref/call is not allowed. (use name)")
  of nkConditional:
    if node.condKind == ckBackref:
      raise newException(RegexError, "numbered backref/call is not allowed. (use name)")
  else:
    discard
  for child in node.childNodes:
    validateNoNumberedRefs(child)

proc validateNumericRefs(
    node: Node, captureCount: int, namedCaptures: seq[(string, int)]
) =
  ## Ensure that every numeric backref / subexp call / conditional reference
  ## points to an existing capture group, and that named references resolve
  ## to a known capture name.
  if node == nil:
    return
  case node.kind
  of nkBackreference:
    if node.backrefIndex < 1 or node.backrefIndex > captureCount:
      raise newException(
        RegexError, "invalid group reference '\\" & $node.backrefIndex & "'"
      )
  of nkSubexpCall:
    if node.callName.len > 0:
      var found = false
      for (n, _) in namedCaptures:
        if n == node.callName:
          found = true
          break
      if not found:
        raise newException(
          RegexError, "undefined name reference '\\g<" & node.callName & ">'"
        )
    else:
      # callIndex == 0 is the whole-pattern recursion \g<0>, always valid.
      if node.callIndex != 0 and (node.callIndex < 1 or node.callIndex > captureCount):
        raise
          newException(RegexError, "invalid subexp call '\\g<" & $node.callIndex & ">'")
  of nkNamedBackref:
    var found = false
    for (n, _) in namedCaptures:
      if n == node.backrefName:
        found = true
        break
    if not found:
      raise newException(
        RegexError, "undefined name reference '\\k<" & node.backrefName & ">'"
      )
  of nkConditional:
    if node.condKind == ckBackref:
      if node.condRefIndex < 1 or node.condRefIndex > captureCount:
        raise newException(
          RegexError,
          "invalid conditional group reference '(" & $node.condRefIndex & ")'",
        )
    elif node.condKind == ckNamedRef:
      var found = false
      for (n, _) in namedCaptures:
        if n == node.condRefName:
          found = true
          break
      if not found:
        raise newException(
          RegexError,
          "undefined name reference in conditional '" & node.condRefName & "'",
        )
  else:
    discard
  for child in node.childNodes:
    validateNumericRefs(child, captureCount, namedCaptures)

proc collectLiteralNodes(node: Node, into: var seq[Node]): bool =
  ## Append the literal characters of a subtree made of nothing but literals —
  ## one, a concat of them, or any of those inside a ``(?:...)``.  False (with
  ## ``into`` for the caller to discard) for anything else, including an empty
  ## group or concat: Oniguruma does not see through ``(?:)`` either.
  if node == nil:
    return false
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkString:
    into.add node
    true
  of nkGroup:
    collectLiteralNodes(node.groupBody, into)
  of nkConcat:
    if node.children.len == 0:
      return false
    for child in node.children:
      if not collectLiteralNodes(child, into):
        return false
    true
  else:
    false

proc flattenLiteralGroups(node: Node) =
  ## Splice a ``(?:...)`` holding nothing but literals into the concat around
  ## it.  Such a group has no identity of its own, and the wrapper only hid its
  ## characters from the surrounding run — which is what the reverse
  ## multi-character fold needs, so ``(?i)f(?:f)`` then matches ``ﬀ`` like
  ## ``(?i)ff``.  Oniguruma reads these groups the same way.
  ##
  ## Must run before unnamed captures are demoted: a demoted capture is an
  ## ``nkGroup`` too, and Oniguruma does not fold through one.
  if node == nil:
    return
  case node.kind
  of nkConcat:
    for child in node.children:
      flattenLiteralGroups(child)
    var spliced: seq[Node]
    var changed = false
    for child in node.children:
      var inner: seq[Node]
      if child.kind == nkGroup and collectLiteralNodes(child, inner):
        spliced.add inner
        changed = true
      else:
        spliced.add child
    if changed:
      node.children = spliced
  of nkAlternation:
    for alt in node.alternatives:
      flattenLiteralGroups(alt)
  of nkCapture:
    flattenLiteralGroups(node.captureBody)
  of nkNamedCapture:
    flattenLiteralGroups(node.namedCaptureBody)
  of nkGroup:
    flattenLiteralGroups(node.groupBody)
  of nkFlagGroup:
    flattenLiteralGroups(node.flagBody)
  of nkQuantifier:
    flattenLiteralGroups(node.quantBody)
  of nkLookaround:
    flattenLiteralGroups(node.lookBody)
  of nkAtomicGroup:
    flattenLiteralGroups(node.atomicBody)
  of nkConditional:
    flattenLiteralGroups(node.condYes)
    flattenLiteralGroups(node.condNo)
    flattenLiteralGroups(node.condBody)
  of nkAbsent:
    flattenLiteralGroups(node.absentBody)
    flattenLiteralGroups(node.absentExpr)
  else:
    discard

proc newStringNode(runes: seq[Rune]): Node =
  ## An ``nkString`` over ``runes``, with their UTF-8 encoding and its ASCII
  ## fold precomputed.
  var size = 0
  for r in runes:
    size += r.size
  var bytes = newStringOfCap(size)
  for r in runes:
    bytes.add $r
  var folded = newString(bytes.len)
  for i in 0 ..< bytes.len:
    folded[i] = char(asciiFoldByte(uint8(bytes[i])))
  Node(kind: nkString, runes: runes, bytes: bytes, foldedBytes: folded)

proc mergeLiterals(node: Node): Node =
  ## Merge consecutive nkLiteral/nkEscapedLiteral children in nkConcat into nkString.
  if node == nil:
    return nil
  case node.kind
  of nkConcat:
    var merged: seq[Node]
    var run: seq[Rune]
    for child in node.children:
      let mc = mergeLiterals(child)
      if mc.kind == nkLiteral:
        run.add mc.rune
      elif mc.kind == nkEscapedLiteral:
        run.add mc.escapedRune
      elif mc.kind == nkString:
        run.add mc.runes
      else:
        if run.len >= 2:
          merged.add newStringNode(run)
          run = @[]
        elif run.len == 1:
          merged.add Node(kind: nkLiteral, rune: run[0])
          run = @[]
        merged.add mc
    if run.len >= 2:
      merged.add newStringNode(run)
    elif run.len == 1:
      merged.add Node(kind: nkLiteral, rune: run[0])
    if merged.len == 1:
      return merged[0]
    Node(kind: nkConcat, children: merged)
  of nkAlternation:
    var alts = newSeq[Node](node.alternatives.len)
    for i, alt in node.alternatives:
      alts[i] = mergeLiterals(alt)
    Node(kind: nkAlternation, alternatives: alts)
  of nkCapture:
    Node(
      kind: nkCapture,
      captureIndex: node.captureIndex,
      captureBody: mergeLiterals(node.captureBody),
    )
  of nkNamedCapture:
    Node(
      kind: nkNamedCapture,
      captureName: node.captureName,
      namedCaptureIndex: node.namedCaptureIndex,
      namedCaptureBody: mergeLiterals(node.namedCaptureBody),
    )
  of nkGroup:
    Node(kind: nkGroup, groupBody: mergeLiterals(node.groupBody))
  of nkFlagGroup:
    Node(
      kind: nkFlagGroup,
      flagsOn: node.flagsOn,
      flagsOff: node.flagsOff,
      flagBody:
        if node.flagBody != nil:
          mergeLiterals(node.flagBody)
        else:
          nil,
      graphemeMode: node.graphemeMode,
    )
  of nkQuantifier:
    Node(
      kind: nkQuantifier,
      quantMin: node.quantMin,
      quantMax: node.quantMax,
      quantKind: node.quantKind,
      quantBody: mergeLiterals(node.quantBody),
    )
  of nkLookaround:
    Node(
      kind: nkLookaround,
      lookKind: node.lookKind,
      lookBody: mergeLiterals(node.lookBody),
    )
  of nkAtomicGroup:
    Node(kind: nkAtomicGroup, atomicBody: mergeLiterals(node.atomicBody))
  of nkConditional:
    Node(
      kind: nkConditional,
      condKind: node.condKind,
      condRefIndex: node.condRefIndex,
      condRefName: node.condRefName,
      condYes: mergeLiterals(node.condYes),
      condNo: mergeLiterals(node.condNo),
      condBody: mergeLiterals(node.condBody),
    )
  of nkAbsent:
    Node(
      kind: nkAbsent,
      absentKind: node.absentKind,
      absentBody: mergeLiterals(node.absentBody),
      absentExpr: mergeLiterals(node.absentExpr),
    )
  else:
    node

proc markQuantBodyPure(node: Node): bool =
  ## Records on every quantifier, lookaround and consuming conditional whether
  ## its body can write state that a rollback snapshot restores: captures,
  ## ``keepStart`` (``\K``), flags / grapheme mode or ``subjectEnd``.
  ## ``nkSubexpCall`` counts conservatively.  Returns that verdict for
  ## ``node``'s own subtree; the flag on the node is its negation.
  if node == nil:
    return false
  result =
    case node.kind
    of nkCapture, nkNamedCapture, nkFlagGroup, nkAbsent, nkSubexpCall:
      true
    of nkAnchor:
      node.anchor == akKeep
    else:
      false
  # A conditional's flag is about ``condBody`` alone -- the branches run in
  # the enclosing machine and undo themselves -- so pick its verdict out of
  # the walk rather than from the OR below.
  let wantCond = node.kind == nkConditional
  var condImpure = false
  for child in node.childNodes:
    let childImpure = markQuantBodyPure(child)
    if wantCond and child == node.condBody:
      condImpure = childImpure
    if childImpure:
      result = true
  case node.kind
  of nkQuantifier:
    # ``result`` is the OR over the children, and the quantifier node itself
    # writes nothing, so it is exactly the body's verdict.
    node.quantBodyPure = not result
  of nkLookaround:
    # Same reasoning: the only child is ``lookBody``.
    node.lookBodyPure = not result
  of nkConditional:
    node.condBodyPure = not condImpure
  else:
    discard

proc markGroupBodyKeepsFlags(node: Node): bool =
  ## Records on every group node -- ``nkGroup`` and both capturing spellings --
  ## whether anything below it can write ``ctx.flags``.  Returns that verdict
  ## for ``node``'s own subtree; the flag on the node is its negation.
  ##
  ## Only ``nkFlagGroup`` writes them, and ``nkSubexpCall``, which enters a
  ## body this walk never sees and so counts conservatively.
  if node == nil:
    return false
  result = node.kind in {nkFlagGroup, nkSubexpCall}
  for child in node.childNodes:
    if markGroupBodyKeepsFlags(child):
      result = true
  # A group node writes nothing itself, so the OR over its children is its
  # body's verdict.
  case node.kind
  of nkGroup:
    node.groupBodyKeepsFlags = not result
  of nkCapture:
    node.captureBodyKeepsFlags = not result
  of nkNamedCapture:
    node.namedCaptureBodyKeepsFlags = not result
  else:
    discard

proc sameFirstChar(a, b: FirstCharInfo): bool =
  ## Structural equality for two hints.  Spelled out because ``FirstCharInfo``
  ## is a case object, for which Nim generates no ``==``.
  if a.kind != b.kind:
    return false
  case a.kind
  of fcByte:
    a.byte == b.byte
  of fcByteSet:
    a.bytes == b.bytes
  of fcNone, fcAnchorStart, fcLineStart:
    true

const AltTrieMaxStates = 4096
  ## Ceiling on the distinct prefixes one trie may hold, so a machine-written
  ## alternation of thousands of literals does not pay for the table at every
  ## ``re()``.  Past it the alternation keeps the hints; refusing a trie only
  ## ever costs speed.

const AltTrieRowMinEdges = 2
  ## Edges a state must have before it earns a transition row.  A one-edge
  ## state -- the inside of a word no other branch shares -- answers the walk
  ## in the single compare the indexed load itself costs, so a row there
  ## spends a kilobyte to tie.  From two edges up it is measured ahead (-0.5%
  ## of ``alternation/large``).

const AltTrieStatesPerRow = 8
  ## States a trie must hold per row it is granted, so a table never dwarfs
  ## the trie it accelerates: a row is a fixed kilobyte where a state is
  ## twenty bytes and an edge eight.  Without a ratio every two-branch
  ## alternation buys one -- 2000 copies of ``(?:a|b)`` cost 3.53 MB of
  ## ``re()``, 1.45 MB at this ratio -- while the alternation benchmarks keep
  ## every row they had (77.421M ``Ir`` either way).  One row per sixteen
  ## states drops rows and costs +0.24% ``Ir``.

const AltTrieMaxRows = 64
  ## Ceiling on the rows one trie holds (64 KiB).  Past it the widest and
  ## shallowest states take the budget -- a walk re-scans those at every
  ## position reaching them -- and the rest keep the walk, which only ever
  ## costs speed.

const AltTrieMaxWordLen = 16
  ## Longest branch a trie will take, mirroring ``BulkCompareLen`` in the
  ## matcher: from that length a branch compares as one ``memcmp``, which a
  ## walk spending a state lookup and an edge scan per byte cannot match --
  ## and long branches share long prefixes, so the walk pays that depth at
  ## every position.  Below the bound both paths compare byte at a time, and
  ## the walk does every branch at once.

proc literalBytes(node: Node): string =
  ## The exact bytes ``node`` matches with case folding off, or ``""`` when it
  ## is not a plain literal.  Read where the matcher reads them: an
  ## ``nkString`` carries ``bytes``, a literal re-encodes its rune.
  case node.kind
  of nkString:
    node.bytes
  of nkLiteral, nkEscapedLiteral:
    var buf: array[4, char]
    let cp = int32(if node.kind == nkLiteral: node.rune else: node.escapedRune)
    let n = utf8Encode(cp, buf)
    var s = newString(n)
    for i in 0 ..< n:
      s[i] = buf[i]
    s
  else:
    ""

proc buildAltTrie(alternatives: seq[Node]): AltTrie =
  ## Trie over ``alternatives`` when every one of them is a non-empty plain
  ## literal, else ``nil``.  Built as a linked tree and then flattened, so the
  ## matcher walks arrays and not a graph of ``ref``s.
  ##
  ## No lower bound on the branch count, from the structure of the work and
  ## not a measurement: a hint test reads the same byte the branch's own
  ## compare would read next, so two hints do not cost less than one walk --
  ## the walk *is* that compare, and it also names the branch.  (Two-branch
  ## patterns do measure faster, but inside the swing this benchmark shows
  ## from code alignment alone.)  The bound on branch *length* is real,
  ## though: see [AltTrieMaxWordLen].
  if alternatives.len < 2:
    return nil
  var words = newSeq[string](alternatives.len)
  for i, alt in alternatives:
    words[i] = literalBytes(alt)
    if words[i].len == 0:
      # A root terminal could express a zero-width branch, but
      # ``stringAdvance`` refuses an empty run, so the trie would not agree
      # with the path it replaces.  Leave the alternation to the hints.
      return nil
    if words[i].len >= AltTrieMaxWordLen:
      return nil
  type BuildState = object
    kids: seq[tuple[label: uint8, next: int32]]
    terms: seq[int32]
    depth: int32

  var build = @[BuildState()]
  for i, w in words:
    var s = 0'i32
    for ch in w:
      let b = uint8(ch)
      var nxt = -1'i32
      for k in build[s].kids:
        if k.label == b:
          nxt = k.next
          break
      if nxt < 0:
        if build.len >= AltTrieMaxStates:
          return nil
        build.add BuildState(depth: build[s].depth + 1)
        nxt = int32(build.len - 1)
        build[s].kids.add (b, nxt)
      s = nxt
    # Ascending by construction: the branches are walked in their own order.
    build[s].terms.add int32(i)
  result = AltTrie(states: newSeq[AltTrieState](build.len))
  for s in 0 ..< build.len:
    # Sorted, so a walk can stop at the first label past the byte it wants.
    build[s].kids.sort(
      proc(a, b: tuple[label: uint8, next: int32]): int =
        cmp(a.label, b.label)
    )
    result.states[s] = AltTrieState(
      edgeOff: int32(result.edges.len),
      edgeLen: int32(build[s].kids.len),
      termOff: int32(result.terms.len),
      termLen: int32(build[s].terms.len),
      depth: build[s].depth,
      rowOff: -1'i32,
    )
    for k in build[s].kids:
      result.edges.add AltTrieEdge(label: k.label, next: k.next)
    for t in build[s].terms:
      result.terms.add t
  # Rows are granted by what they save and not in state order: the states are
  # numbered by a walk over the branches in their own order, so spending the
  # budget as the numbering hands it out would give every row to the first
  # branches' subtrees and leave the widest later states -- the root's own
  # children among them -- on the edge scan.
  var rowed = newSeq[int32]()
  for s in 0 ..< build.len:
    if build[s].kids.len >= AltTrieRowMinEdges:
      rowed.add int32(s)
  rowed.sort(
    proc(a, b: int32): int =
      # Widest first, then shallowest: a shallow state is reached from more
      # of the subject's positions, so its scan runs most often.
      var c = cmp(build[b].kids.len, build[a].kids.len)
      if c == 0:
        c = cmp(build[a].depth, build[b].depth)
      if c == 0:
        c = cmp(a, b)
      c
  )
  let budget = min(AltTrieMaxRows, build.len div AltTrieStatesPerRow)
  if rowed.len > budget:
    rowed.setLen(budget)
  for s in rowed:
    let rowOff = int32(result.rows.len)
    result.states[s].rowOff = rowOff
    result.rows.setLen(result.rows.len + 256)
    for b in rowOff ..< rowOff + 256:
      result.rows[b] = -1'i32 # no edge, which ``setLen``'s zero would name
    for k in build[s].kids:
      result.rows[rowOff + int32(k.label)] = k.next
  let root = result.states[0]
  for e in root.edgeOff ..< root.edgeOff + root.edgeLen:
    result.firstBytes.incl result.edges[e].label

proc altTriesUsable(node: Node): bool =
  ## Whether a trie stays sound for the life of a match.  It reads the
  ## literal's own bytes, so it may only run with ``rfIgnoreCase`` off, and
  ## the matcher's test of that flag is worth nothing unless the flag cannot
  ## come on *after* it, while a choice point of the alternation is still on
  ## the stack.
  ##
  ## A scoped ``(?i:...)`` cannot: it pushes its restore as it is entered.
  ## The isolated ``(?i)`` sets the flag with nothing left to undo it, so it
  ## extends across the branches of an alternation it follows -- and a branch
  ## the trie passed over on the bytes could match once folding is on.  One
  ## such spelling anywhere takes tries off the table for the whole pattern.
  ##
  ## ``parseConcat`` rewrites every isolated group into a scoped one, so no
  ## pattern spells this today; the guard is against the matcher's own
  ## ``flagBody == nil`` arm, which is still there and still undoes nothing.
  if node == nil:
    return true
  if node.kind == nkFlagGroup and node.flagBody == nil and
      (node.flagsOn * {rfIgnoreCase, rfIgnoreCaseAscii}).card > 0:
    return false
  for child in node.childNodes:
    if not altTriesUsable(child):
      return false
  true

proc annotateTree(
    node: Node,
    hintFlags: RegexFlags,
    cache: var FirstCharCache,
    levelBackrefs: var bool,
    triesUsable: bool,
) =
  ## Single post-parse walk over the finished AST: precomputes each character
  ## class's ASCII membership bitmap, so the matcher can answer ASCII input
  ## with one bit test instead of walking the atoms (stored before negation,
  ## which ``classAdvance`` applies to the lookup's answer), records
  ## each alternative's first-byte hint so the matcher can pass over a branch
  ## that cannot start here, and reports whether the pattern uses a
  ## recursion-level backreference.
  ##
  ## ``hintFlags`` is not tracked down the tree the way ``extractFirstChar``
  ## tracks it across a concatenation: it carries ``rfIgnoreCase`` from the
  ## start and stays put.  That flag is the only one the first-byte analysis
  ## reads, and reading it as set only ever widens a hint or abandons it, so
  ## a hint computed this way is a superset of the truth under any flags the
  ## match actually runs with -- including an ``(?i)`` the pattern switches
  ## on partway through, which no compile-time walk of the tree would see at
  ## the right place anyway.
  if node == nil:
    return
  # Children first: the alternation arm below memoises a hint into ``cache``
  # off every node under it, and ``classFirstChar``'s fallback reads the
  # ``asciiSet`` this walk fills.  Parent-first would cache the ``fcNone``
  # that fallback returns before the set was there and hand that stale answer
  # to every enclosing alternation afterwards.
  for child in node.childNodes:
    annotateTree(child, hintFlags, cache, levelBackrefs, triesUsable)
  case node.kind
  of nkAlternation:
    # Allocated on first use, so a pattern with no alternation in it pays for
    # no table at all.
    if cache.isNil:
      cache = newTable[(uint, RegexFlags), FirstCharInfo]()
    var hints = newSeq[FirstCharInfo](node.alternatives.len)
    var discriminates = false
    for i, alt in node.alternatives:
      hints[i] = extractFirstChar(alt, hintFlags, cache)
      if i > 0 and not sameFirstChar(hints[i], hints[0]):
        discriminates = true
    # Hints that are all the same one can never pass over a branch: whatever
    # byte is in front of the matcher, either every branch survives the test
    # or none does.  Keeping them would buy a pointer chase into ``altFirst``
    # per branch per visit and nothing else -- measurably so, since a
    # ``FirstCharInfo`` carries a 32-byte set and a handful of them span
    # several cache lines.  The alternation that could still gain, one whose
    # branches all fail together partway through a pattern, gives back less
    # than the test costs everywhere else.
    if discriminates:
      node.altFirst = hints
    # Left beside the hints, not in place of them: the trie is only sound
    # with folding off, and the hints answer the same alternation under
    # ``(?i)``.
    if triesUsable:
      node.altTrie = buildAltTrie(node.alternatives)
  of nkCharClass:
    # A bare ``\p{...}``: one atom, no fold variant, nothing past the first
    # element.  Read the shape off here so [classAdvance] need not.
    node.solePropOk =
      not node.bracketClass and node.atoms.len == 1 and
      node.atoms[0].kind in {ccUnicodeProp, ccNegUnicodeProp}
    # The shape reader first; [exactAsciiClassSet] only for what it gives up
    # on -- a ``\p{...}``, a nested class, an intersection.  Asking every atom
    # about every ASCII byte costs microseconds per pattern (``re()`` on
    # ``[a-z&&[^aeiou]]+`` goes 0.4 -> 4.0 us, -d:danger), which is worth it
    # against a decode at every position of every attempt, but only where it
    # buys something.
    var ascii: set[uint8]
    var nonAscii, predicate: bool
    if classAsciiMatches(node, ascii, nonAscii, predicate) or
        exactAsciiClassSet(node.atoms, ascii):
      # Masked, so the field means the same whichever producer filled it:
      # [classAsciiMatches] fills 0x80..0xFF for a range written across the
      # ASCII boundary, [exactAsciiClassSet] never does.  The mask is the
      # field's contract: a reader wanting the high bytes asks the atoms
      # ([classCrossesAsciiBoundary]) instead.
      node.asciiSet = ascii * AllAsciiBytes
      node.asciiSetOk = true
  of nkBackreference:
    if node.backrefLevel != 0:
      levelBackrefs = true
  of nkNamedBackref:
    if node.namedBackrefLevel != 0:
      levelBackrefs = true
  else:
    discard

proc exactAsciiLeaf(node: Node, s: var set[uint8]): bool =
  ## Exact ASCII byte set a leaf accepts, or false when it is not one ASCII
  ## byte. Refuses negated classes, non-ASCII members, and predicates:
  ## ``charTypeBytes`` reports start bytes (a superset), so it cannot prove
  ## exactness. Callers must have ruled out case folding first.
  case node.kind
  of nkLiteral, nkEscapedLiteral:
    let cp = int32(if node.kind == nkLiteral: node.rune else: node.escapedRune)
    if cp >= 128:
      return false
    s = {uint8(cp)}
    true
  of nkCharClass:
    if node.negated:
      return false
    var ascii: set[uint8]
    var nonAscii, predicate: bool
    if not classAsciiMatches(node, ascii, nonAscii, predicate):
      return false
    if nonAscii or predicate:
      return false
    s = ascii
    true
  else:
    false

const LeadZeroWidth =
  {nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp}
  ## Zero-width node kinds skipped when finding the first consuming node.

proc leadFirstLeaf(node: Node, flags: RegexFlags): Node =
  ## Leaf every match must start with, or nil. The scan tests it at each
  ## candidate start, so a refusal costs one character test, not a full
  ## attempt. Only mandatory first leaves qualify: quantifiers with min >= 1,
  ## no case folding, and no exact ASCII leaf (already covered by
  ## ``firstCharInfo``).
  if node == nil:
    return nil
  if (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card > 0:
    return nil
  case node.kind
  of nkConcat:
    # Zero-width nodes consume nothing; look past them.
    for child in node.children:
      if child.kind in LeadZeroWidth:
        continue
      return leadFirstLeaf(child, flags)
    nil
  of nkCapture:
    leadFirstLeaf(node.captureBody, flags)
  of nkNamedCapture:
    leadFirstLeaf(node.namedCaptureBody, flags)
  of nkGroup:
    leadFirstLeaf(node.groupBody, flags)
  of nkAtomicGroup:
    leadFirstLeaf(node.atomicBody, flags)
  of nkQuantifier:
    if node.quantMin >= 1:
      leadFirstLeaf(node.quantBody, flags)
    else:
      nil
  of nkLiteral, nkEscapedLiteral, nkCharClass:
    var s: set[uint8]
    if exactAsciiLeaf(node, s): nil else: node
  of nkCharType:
    # Variable-width types are no single character test.
    if node.charType in {ctDot, ctGraphemeCluster, ctNewlineSeq}: nil else: node
  else:
    nil

proc soleLeafBody(node: Node, flags: RegexFlags): Node =
  ## The single leaf a capture body consumes, or nil. Skips anchors; anything
  ## else beyond one leaf fails.
  if node == nil:
    return nil
  case node.kind
  of nkConcat:
    var leaf: Node = nil
    for child in node.children:
      if child.kind == nkAnchor:
        continue
      if leaf != nil:
        return nil
      leaf = soleLeafBody(child, flags)
      if leaf == nil:
        return nil
    leaf
  of nkGroup:
    soleLeafBody(node.groupBody, flags)
  of nkAtomicGroup:
    soleLeafBody(node.atomicBody, flags)
  of nkLiteral, nkEscapedLiteral, nkCharClass:
    node
  of nkCharType:
    # Variable-width types are no single character test.
    if node.charType in {ctDot, ctGraphemeCluster, ctNewlineSeq}: nil else: node
  else:
    nil

proc leadRepeatLeaf(node: Node, flags: RegexFlags): Node =
  ## Leaf every match starts with twice running (``(leaf)\1``), or nil.
  ## Case folding and non-level-0 backreferences disqualify.
  if node == nil:
    return nil
  if (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card > 0:
    return nil
  case node.kind
  of nkConcat:
    # Same zero-width nodes [leadFirstLeaf] skips.
    var i = 0
    while i < node.children.len and node.children[i].kind in LeadZeroWidth:
      inc i
    if i + 1 >= node.children.len:
      return nil
    let cap = node.children[i]
    # ``\1`` is ``captureIndex`` 0.
    var capIndex: int
    var body: Node
    case cap.kind
    of nkCapture:
      capIndex = cap.captureIndex + 1
      body = cap.captureBody
    of nkNamedCapture:
      # Unreachable today: validation rejects numeric backrefs here.
      capIndex = cap.namedCaptureIndex + 1
      body = cap.namedCaptureBody
    else:
      return nil
    let leaf = soleLeafBody(body, flags)
    if leaf == nil:
      return nil
    let after = node.children[i + 1]
    if after.kind != nkBackreference or after.backrefLevel != 0 or
        after.backrefIndex != capIndex:
      return nil
    leaf
  of nkGroup:
    leadRepeatLeaf(node.groupBody, flags)
  of nkAtomicGroup:
    leadRepeatLeaf(node.atomicBody, flags)
  else:
    nil

proc leadAnchorSet(node: Node, flags: RegexFlags): set[AnchorKind] =
  ## Zero-width assertions every match must satisfy at the start position.
  ##
  ## Same descent as [leadFirstLeaf]: everything walked past is zero-width or
  ## entered at the start position. The result is a conjunction of pure
  ## position predicates, so order is irrelevant.
  ##
  ## ``akKeep`` is excluded: it writes ``keepStart`` and cannot run early.
  ## Lookarounds and callouts are walked past as in ``leadFirstLeaf``.
  if node == nil:
    return {}
  case node.kind
  of nkConcat:
    for child in node.children:
      case child.kind
      of nkAnchor:
        if child.anchor != akKeep:
          result.incl child.anchor
      of nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
        discard
      else:
        return result + leadAnchorSet(child, flags)
  of nkAnchor:
    if node.anchor != akKeep:
      result.incl node.anchor
  of nkCapture:
    result = leadAnchorSet(node.captureBody, flags)
  of nkNamedCapture:
    result = leadAnchorSet(node.namedCaptureBody, flags)
  of nkGroup:
    result = leadAnchorSet(node.groupBody, flags)
  of nkAtomicGroup:
    result = leadAnchorSet(node.atomicBody, flags)
  of nkQuantifier:
    if node.quantMin >= 1:
      result = leadAnchorSet(node.quantBody, flags)
  else:
    discard

proc hasSubexpCall(node: Node): bool =
  ## Whether any ``\g<...>`` appears; a body may then run under another continuation.
  if node == nil:
    return false
  if node.kind == nkSubexpCall:
    return true
  for child in node.childNodes:
    if hasSubexpCall(child):
      return true
  false

type
  NonAsciiSet = enum
    ## Which characters above U+007F a leaf accepts, coarsely enough for
    ## [nonAsciiDisjoint] to answer without walking the code space.
    naWord ## ``\w``: letters, marks, digits, connector punctuation
    naDigit ## ``\d``, a subset of ``naWord``
    naSpace ## ``\s``
    naOther ## anything else, every negated type included

  AcceptSet = object
    ## The characters a leaf accepts, or the union over several.  ``ascii``
    ## is exact: [AsciiCharTypeSets] does not depend on the ASCII-only flags
    ## and [exactAsciiLeaf] refuses what it cannot state.  ``nonAscii`` is a
    ## superset.
    ascii: set[uint8]
    nonAscii: set[NonAsciiSet]

  FollowStep = enum
    fsStop ## the node consumes a character; the walk ends at it
    fsPass ## it may match empty, so the next node speaks too
    fsUnknown ## not even consumption is stated; the caller must give up

  ContinuationReq = object
    ## What the continuation requires at the position a give-back or a lazy
    ## scan hands it: two necessary conditions, each usable on its own.
    ## Weakening either -- a wider ``accept``, a nil ``leaf`` -- costs a
    ## refusal; narrowing drops matches.  They are tracked apart because a
    ## leaf can be testable where its set cannot be stated: an ``nkString``
    ## opening on a non-ASCII rune is one ``leadLeafEnd`` answers and
    ## [leafAccept] refuses.
    accept: AcceptSet
    acceptKnown: bool ## ``accept`` is a superset of the first characters
    leaf: Node
      ## The single node that can consume first, and one ``leadLeafEnd`` can
      ## test in place; nil where two nodes can, or where that one is not a
      ## leaf kind.
    leafMulti: bool ## a second node reached the position; ``leaf`` stays nil

template UnknownReq(): ContinuationReq =
  ## Nothing stated on either track.  A template, not a ``const``: that
  ## cannot hold the ``ref`` the leaf track is.
  ContinuationReq(leafMulti: true)

proc noteLeaf(r: var ContinuationReq, leaf: Node) =
  ## Record one more node that can consume at the position.  Every arm that
  ## adds to ``accept`` calls this in lockstep, which is what makes a
  ## surviving ``leaf`` a *necessary* test rather than one of several ways.
  if r.leafMulti:
    return
  if r.leaf != nil or leaf == nil:
    r.leaf = nil
    r.leafMulti = true
  else:
    r.leaf = leaf

proc mergeTail(r: var ContinuationReq, tail: ContinuationReq) =
  ## Fold what follows a node that may match empty into what the node itself
  ## requires: either can consume first, so both tracks widen.
  if r.acceptKnown and tail.acceptKnown:
    r.accept.ascii = r.accept.ascii + tail.accept.ascii
    r.accept.nonAscii = r.accept.nonAscii + tail.accept.nonAscii
  else:
    r.acceptKnown = false
  if r.leafMulti or tail.leafMulti or (r.leaf != nil and tail.leaf != nil):
    r.leaf = nil
    r.leafMulti = true
  elif r.leaf == nil:
    r.leaf = tail.leaf

proc nonAsciiDisjoint(a, b: NonAsciiSet): bool =
  ## Whether two non-ASCII families provably share no character.  Only these
  ## two pairs are claimed, and ``test_engine.nim`` pins both against every
  ## code point.
  (a == naWord and b == naSpace) or (a == naSpace and b == naWord) or
    (a == naDigit and b == naSpace) or (a == naSpace and b == naDigit)

proc disjointAccept(a, b: AcceptSet): bool =
  ## Whether no character is in both sets.  An empty intersection proves it
  ## on either half: ``ascii`` is exact, and ``nonAscii`` is a superset.
  if a.ascii * b.ascii != {}:
    return false
  for x in a.nonAscii:
    for y in b.nonAscii:
      if not nonAsciiDisjoint(x, y):
        return false
  true

proc leafAccept(node: Node, flags: RegexFlags, s: var AcceptSet): bool =
  ## The set ``node`` accepts as its first character, or false when it cannot
  ## be stated.  Callers must have ruled out case folding first.
  if node == nil:
    return false
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkCharClass:
    var ascii: set[uint8]
    if not exactAsciiLeaf(node, ascii):
      return false
    s = AcceptSet(ascii: ascii)
    true
  of nkString:
    # Only the first character stands at the position in question.
    if node.runes.len == 0 or int32(node.runes[0]) >= 128:
      return false
    s = AcceptSet(ascii: {uint8(int32(node.runes[0]))})
    true
  of nkCharType:
    # ``\h`` is ASCII throughout; ``.``, ``\O``, ``\R`` and ``\X`` state no
    # fixed set of characters at all.
    let family =
      case node.charType
      of ctWord:
        {naWord}
      of ctDigit:
        {naDigit}
      of ctSpace:
        {naSpace}
      of ctHexDigit:
        {}
      of ctNotWord, ctNotDigit, ctNotSpace, ctNotHexDigit, ctNotNewline:
        {naOther}
      else:
        return false
    s = AcceptSet(ascii: AsciiCharTypeSets[node.charType], nonAscii: family)
    true
  else:
    false

proc leafTestable(node: Node): bool =
  ## Whether ``leadLeafEnd`` can answer this node at a position.  Only kinds
  ## with a ``leadLeafMatches`` arm qualify, and not ``.``, ``\X`` or ``\R``,
  ## which fix no character.  Case folding widens every leaf; the whole walk
  ## is gated on it being off.
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkCharClass, nkString:
    true
  of nkCharType:
    node.charType notin {ctDot, ctGraphemeCluster, ctNewlineSeq}
  else:
    false

proc addReq(node: Node, flags: RegexFlags, f: var ContinuationReq): FollowStep =
  ## Add what ``node`` requires at the start of the continuation to ``f``, and
  ## say whether the node after it speaks too.
  ##
  ## ``f.accept`` must stay a *superset* of what the continuation can begin
  ## with: an extra leaf costs a refusal, a missing one drops matches.  So a
  ## node that cannot be stated stops the walk, unless it is zero-width and
  ## can only refuse positions.  ``f.leaf`` carries the same direction, and
  ## survives only where exactly one node can consume first.
  if node == nil:
    return fsUnknown
  case node.kind
  of nkAnchor:
    fsPass # zero-width, ``\K`` included: a failed continuation rolls it back
  of nkLookaround:
    if node.lookKind == lkAhead:
      # A positive look-ahead demands its own first character right here, so
      # what its body requires at its start is required at this position, its
      # leaf included.  The body walks into its own ``ContinuationReq`` so a
      # refusal inside it leaves ``f`` alone: the look-ahead is zero-width, so
      # dropping its share leaves the union a superset of what the rest of the
      # continuation requires.
      var body = ContinuationReq(acceptKnown: true)
      if addReq(node.lookBody, flags, body) == fsStop and body.acceptKnown:
        f.accept.ascii = f.accept.ascii + body.accept.ascii
        f.accept.nonAscii = f.accept.nonAscii + body.accept.nonAscii
        f.noteLeaf(body.leaf)
        fsStop
      else:
        # Nothing was taken from the body, so nothing is claimed for it; the
        # node after the look-ahead speaks at this same position.
        fsPass
    else:
      # A negative look-ahead and both look-behinds only refuse positions.
      fsPass
  of nkConcat:
    for child in node.children:
      case addReq(child, flags, f)
      of fsStop:
        return fsStop
      of fsUnknown:
        return fsUnknown
      of fsPass:
        discard
    fsPass
  of nkGroup:
    addReq(node.groupBody, flags, f)
  of nkCapture:
    addReq(node.captureBody, flags, f)
  of nkNamedCapture:
    addReq(node.namedCaptureBody, flags, f)
  of nkAtomicGroup:
    # Atomic cuts backtracking only; its first character is its body's.
    addReq(node.atomicBody, flags, f)
  of nkAlternation:
    # Every branch can consume first, so two that state a leaf leave none
    # required -- which [noteLeaf] already says.
    var mayPass = false
    for alt in node.alternatives:
      case addReq(alt, flags, f)
      of fsUnknown:
        return fsUnknown
      of fsPass:
        mayPass = true
      of fsStop:
        discard
    if mayPass: fsPass else: fsStop
  of nkQuantifier:
    if node.quantMax == 0:
      return fsPass # ``{0,0}`` matches empty, so the node after it speaks
    let step = addReq(node.quantBody, flags, f)
    if step == fsUnknown:
      fsUnknown
    elif node.quantMin >= 1:
      step
    else:
      fsPass
  of nkFlagGroup:
    # Recursing under the new flags would not help: a folded leaf's set is its
    # ASCII case closure plus every character above U+007F folding into it, so
    # ``nonAscii`` widens to ``naOther`` and both readers of ``accept`` give up
    # anyway.  The isolated ``(?imx)`` form carries ``flagBody == nil`` and
    # moves its *siblings*' flags, which this walk cannot carry either.
    fsUnknown
  of nkLiteral, nkEscapedLiteral, nkCharClass, nkCharType, nkString:
    var a: AcceptSet
    let stated = leafAccept(node, flags, a)
    let testable = leafTestable(node)
    if not stated and not testable:
      return fsUnknown # ``.``, ``\X``, ``\R``: neither track has anything
    if stated:
      f.accept.ascii = f.accept.ascii + a.ascii
      f.accept.nonAscii = f.accept.nonAscii + a.nonAscii
    else:
      f.acceptKnown = false
    f.noteLeaf(if testable: node else: nil)
    fsStop
  else:
    fsUnknown

proc reqBefore(node: Node, flags: RegexFlags, tail: ContinuationReq): ContinuationReq =
  ## What the continuation requires just before ``node``, given ``tail`` is
  ## what it requires just after it.  A concat folds right to left with this,
  ## reaching every child once.
  var here = ContinuationReq(acceptKnown: true)
  case addReq(node, flags, here)
  of fsStop:
    here
  of fsPass:
    here.mergeTail(tail)
    here
  of fsUnknown:
    UnknownReq

type RegionStep = enum
  ## Walk-back result on the mandatory path to the required byte.
  rsNone ## no byte found; bytes seen joined the union
  rsFound ## required byte found
  rsRefuse ## unstated leaf; region stays off

proc addAccept(s: var set[uint8], a: AcceptSet) =
  s = s + a.ascii
  if a.nonAscii != {}:
    # Over-approximation only moves the region left.
    s = s + {0x80'u8 .. 0xFF'u8}

proc addRune(s: var set[uint8], cp: int32) =
  if cp < 128:
    s.incl uint8(cp)
  else:
    s = s + {0x80'u8 .. 0xFF'u8}

proc consumable(node: Node, flags: RegexFlags, s: var set[uint8]): bool =
  ## Every byte ``node`` can consume; false where a leaf cannot be stated exactly.
  if node == nil:
    return false
  case node.kind
  of nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    true # zero-width
  of nkLiteral:
    addRune(s, int32(node.rune))
    true
  of nkEscapedLiteral:
    addRune(s, int32(node.escapedRune))
    true
  of nkString:
    for r in node.runes:
      addRune(s, int32(r))
    true
  of nkCharClass, nkCharType:
    var a: AcceptSet
    if not leafAccept(node, flags, a):
      return false
    addAccept(s, a)
    true
  of nkConcat:
    for child in node.children:
      if not consumable(child, flags, s):
        return false
    true
  of nkAlternation:
    for alt in node.alternatives:
      if not consumable(alt, flags, s):
        return false
    true
  of nkGroup:
    consumable(node.groupBody, flags, s)
  of nkCapture:
    consumable(node.captureBody, flags, s)
  of nkNamedCapture:
    consumable(node.namedCaptureBody, flags, s)
  of nkAtomicGroup:
    consumable(node.atomicBody, flags, s)
  of nkQuantifier:
    node.quantMax == 0 or consumable(node.quantBody, flags, s)
  else:
    # Anything else states no byte set.
    false

proc regionWalk(
    node: Node, flags: RegexFlags, prefix: var set[uint8], found: var uint8
): RegionStep =
  ## Collect bytes before the required byte into ``prefix``; byte in ``found``.
  if node == nil:
    return rsRefuse
  case node.kind
  of nkAnchor, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    rsNone # zero-width
  of nkLookaround:
    # Positive look-ahead only; its body precedes the byte.
    if node.lookKind == lkAhead and extractRequiredByte(node.lookBody, flags).valid:
      if regionWalk(node.lookBody, flags, prefix, found) == rsFound:
        rsFound
      else:
        rsRefuse
    else:
      rsNone
  of nkLiteral, nkEscapedLiteral, nkString:
    # Extraction source.
    let rb = extractRequiredByte(node, flags)
    if not rb.valid:
      return rsRefuse
    found = rb.byte
    rsFound
  of nkCharClass, nkCharType:
    var a: AcceptSet
    if not leafAccept(node, flags, a):
      return rsRefuse
    addAccept(prefix, a)
    rsNone
  of nkConcat:
    for child in node.children:
      case regionWalk(child, flags, prefix, found)
      of rsFound:
        return rsFound
      of rsRefuse:
        return rsRefuse
      of rsNone:
        discard
    rsNone
  of nkGroup:
    regionWalk(node.groupBody, flags, prefix, found)
  of nkCapture:
    regionWalk(node.captureBody, flags, prefix, found)
  of nkNamedCapture:
    regionWalk(node.namedCaptureBody, flags, prefix, found)
  of nkAtomicGroup:
    regionWalk(node.atomicBody, flags, prefix, found)
  of nkQuantifier:
    if node.quantMax != 0 and node.quantMin >= 1:
      # Mandatory: a byte inside is in the first iteration.
      let step = regionWalk(node.quantBody, flags, prefix, found)
      if step != rsNone:
        return step
      if not consumable(node.quantBody, flags, prefix):
        return rsRefuse
      rsNone
    else:
      # Optional: all may precede the byte.
      if not consumable(node.quantBody, flags, prefix):
        return rsRefuse
      rsNone
  of nkAlternation:
    # Never the source; all of it is walk-back.
    if not consumable(node, flags, prefix):
      return rsRefuse
    rsNone
  else:
    rsRefuse

proc requiredByteRegion(
    ast: Node, flags: RegexFlags, rb: RequiredByteInfo
): RequiredByteInfo =
  ## Attach the walk-back set; off under folding or ``\g<...>``.
  result = rb
  if not rb.valid:
    return
  if (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card != 0 or hasSubexpCall(ast):
    return
  var prefix: set[uint8]
  var found = 0'u8
  # Both walks must agree on the byte.
  if regionWalk(ast, flags, prefix, found) == rsFound and found == rb.byte:
    result.regionOk = true
    result.prefix = prefix

type LeadBehindStep = enum
  lbsNone ## Zero-width; the walk may look past it.
  lbsFound
  lbsRefuse

proc behindLiteral(node: Node, lit: var string): bool =
  ## Whether a look-behind body is one case-sensitive ASCII literal, appended
  ## to ``lit``. ASCII only, so byte length equals its width behind the start;
  ## flag groups are refused since folding is not a byte comparison.
  if node == nil:
    return false
  case node.kind
  of nkLiteral:
    let cp = int32(node.rune)
    if cp >= 128:
      return false
    lit.add char(cp)
    true
  of nkEscapedLiteral:
    let cp = int32(node.escapedRune)
    if cp >= 128:
      return false
    lit.add char(cp)
    true
  of nkString:
    for r in node.runes:
      let cp = int32(r)
      if cp >= 128:
        return false
      lit.add char(cp)
    true
  of nkConcat:
    for child in node.children:
      if not behindLiteral(child, lit):
        return false
    true
  of nkGroup:
    behindLiteral(node.groupBody, lit)
  of nkCapture:
    behindLiteral(node.captureBody, lit)
  of nkNamedCapture:
    behindLiteral(node.namedCaptureBody, lit)
  of nkAtomicGroup:
    behindLiteral(node.atomicBody, lit)
  else:
    false

proc leadBehindWalk(node: Node, info: var LeadBehindInfo): LeadBehindStep =
  ## Leading ``(?<=lit)`` every match begins with. Stops at the first
  ## consuming node, past which the assertion no longer stands at the start.
  if node == nil:
    return lbsRefuse
  case node.kind
  of nkAnchor, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    lbsNone # zero-width
  of nkLookaround:
    # Other lookarounds are zero-width.
    if node.lookKind == lkBehind:
      var lit = ""
      if behindLiteral(node.lookBody, lit) and lit.len > 0:
        info = LeadBehindInfo(valid: true, byte: uint8(lit[0]), offset: lit.len)
        return lbsFound
    lbsNone
  of nkConcat:
    for child in node.children:
      case leadBehindWalk(child, info)
      of lbsFound:
        return lbsFound
      of lbsRefuse:
        return lbsRefuse
      of lbsNone:
        discard
    lbsNone
  of nkGroup:
    leadBehindWalk(node.groupBody, info)
  of nkCapture:
    leadBehindWalk(node.captureBody, info)
  of nkNamedCapture:
    leadBehindWalk(node.namedCaptureBody, info)
  of nkAtomicGroup:
    leadBehindWalk(node.atomicBody, info)
  of nkQuantifier:
    # Mandatory repeats only.
    if node.quantMax != 0 and node.quantMin >= 1:
      leadBehindWalk(node.quantBody, info)
    else:
      lbsRefuse
  of nkFlagGroup:
    # Only folding can change what a case-sensitive ASCII byte compare
    # matches, so the walk passes through every other flag.  The isolated
    # ``(?x)`` form carries no body and its flags reach the siblings the
    # concat walks next, which is what makes stepping over it right.
    if (node.flagsOn + node.flagsOff) * {rfIgnoreCase, rfIgnoreCaseAscii} != {}:
      lbsRefuse
    elif node.flagBody == nil:
      lbsNone
    else:
      leadBehindWalk(node.flagBody, info)
  else:
    lbsRefuse

proc leadBehindLiteral(ast: Node, flags: RegexFlags): LeadBehindInfo =
  ## Leading look-behind literal's first byte and offset behind the start,
  ## or invalid. Off under folding and ``\g<...>``.
  if (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card != 0 or hasSubexpCall(ast):
    return LeadBehindInfo(valid: false)
  var info = LeadBehindInfo(valid: false)
  if leadBehindWalk(ast, info) == lbsFound:
    info
  else:
    LeadBehindInfo(valid: false)

proc normaliseInvertedRanges(node: Node) =
  ## Rewrite an inverted range into what Oniguruma matches for it: ``{3,1}``
  ## is ``{1,3}`` possessive, whatever kind it was spelled with.  Doing it
  ## once here lets every later pass read ``quantMin`` / ``quantKind`` as
  ## written.
  ##
  ## A possessive repeat is an atomic group around a greedy one, and they part
  ## only when the minimum needs the body to give characters back:
  ## ``(?:a+){4,2}`` matches ``"aaaa"`` as ``"aaa"`` + ``"a"``, a split the
  ## possessive loop -- which keeps each iteration's first match -- never
  ## reaches.  So a minimum above one is spelled out as ``(?>X{m,n})``.  Up to
  ## one rep that first answer is the greedy one already, so those stay
  ## possessive and keep the fast paths that read the kind, [leadSimpleRepeat]
  ## among them.
  if node == nil:
    return
  if node.kind == nkQuantifier and isInvertedRange(node.quantMin, node.quantMax):
    doAssert node.id == NoNodeId,
      "normaliseInvertedRanges: numbering runs later, so no id is set yet"
    swap(node.quantMin, node.quantMax)
    if node.quantMin >= 2:
      # Rewritten in place: a fresh node carries the repeat, and this one --
      # which a parent already points at -- becomes the atomic group over it.
      # Numbering runs on the final tree, so the new node is unnumbered here.
      let repeat = Node(
        kind: nkQuantifier,
        quantBody: node.quantBody,
        quantMin: node.quantMin,
        quantMax: node.quantMax,
        quantKind: qkGreedy,
      )
      node[] = Node(kind: nkAtomicGroup, atomicBody: repeat)[]
    else:
      node.quantKind = qkPossessive
  for child in node.childNodes:
    normaliseInvertedRanges(child)

type ReduceAction = enum
  raAsIs ## leave the pair as it stands
  raDel ## the outer repeat becomes the inner one
  raStar ## the pair becomes ``*``
  raPlus ## the pair becomes ``+``
  raLazyStar ## the pair becomes ``*?``
  raLazyOpt ## the pair becomes ``??``
  raPlusLazyOpt ## the pair becomes ``(?:X+)??``

proc quantTypeNum(node: Node): int {.inline.} =
  ## Oniguruma's ``quantifier_type_num``: which of the six popular spellings
  ## this repeat is -- ``?`` 0, ``*`` 1, ``+`` 2, ``??`` 3, ``*?`` 4, ``+?`` 5
  ## -- or -1 for a counted one, which [ReduceTable] has no row for.
  ## Possessives answer -1 and never reach the table anyway:
  ## [reduceNestedQuantifier] turns them away first, since Oniguruma spells
  ## one as ``(?>...)`` around a greedy repeat and so never has a possessive
  ## repeat node to put in a row.
  case node.quantKind
  of qkGreedy:
    if node.quantMin == 0:
      if node.quantMax == 1:
        0
      elif node.quantMax < 0:
        1
      else:
        -1
    elif node.quantMin == 1 and node.quantMax < 0:
      2
    else:
      -1
  of qkLazy:
    if node.quantMin == 0:
      if node.quantMax == 1:
        3
      elif node.quantMax < 0:
        4
      else:
        -1
    elif node.quantMin == 1 and node.quantMax < 0:
      5
    else:
      -1
  of qkPossessive:
    -1

const ReduceTable: array[6, array[6, ReduceAction]] = [
  # Oniguruma's ``ReduceTypeTable``, transcribed. Indexed ``[inner][outer]``,
  # both by [quantTypeNum].
  [raDel, raStar, raStar, raLazyOpt, raLazyStar, raAsIs], # inner ``?``
  [raDel, raDel, raDel, raPlusLazyOpt, raPlusLazyOpt, raDel], # inner ``*``
  [raStar, raStar, raDel, raAsIs, raPlusLazyOpt, raDel], # inner ``+``
  [raDel, raLazyStar, raLazyStar, raDel, raLazyStar, raLazyStar], # inner ``??``
  [raDel, raDel, raDel, raDel, raDel, raDel], # inner ``*?``
  [raAsIs, raStar, raPlus, raLazyStar, raLazyStar, raDel], # inner ``+?``
]

proc setQuant(node: Node, lo, hi: int, kind: QuantKind) {.inline.} =
  node.quantMin = lo
  node.quantMax = hi
  node.quantKind = kind

proc reduceNestedQuantifier(node: Node) =
  ## Collapse a repeat whose body is itself a repeat, the way Oniguruma's
  ## ``onig_reduce_nested_quantifier`` does: ``(?:a*)*`` is ``a*``,
  ## ``(?:a?)+`` is ``a*``, ``(?:a{2}){3}`` is ``a{6}``.  Every rewrite is an
  ## identity, so on its own this changes no answer; what it changes is the
  ## *shape* the passes after it read.
  ##
  ## A look-behind body is where that shape becomes an answer.
  ## [reduceLookBehindBodies] pins a leading repeat over a *simple* atom only
  ## -- see [isSimpleRepeatBody] -- so it can only reduce ``(?:a*)*\b`` to
  ## the bare ``\b`` Oniguruma ends up with once this pass has flattened the
  ## pair first.  Oniguruma gets the ordering for free by doing this while
  ## parsing, long before any look-behind tuning runs; here it is the
  ## ordering in [re] that has to hold it.
  ##
  ## Bare groups are transparent, as in Oniguruma, where ``(?:...)`` leaves no
  ## node behind.  A capture stops the reduction -- ``(a*)*`` and ``a*`` do
  ## not write the same group -- and so does a possessive on either side,
  ## which in Oniguruma is an atomic group and therefore not a repeat node the
  ## pair could be read from.
  if node.quantMin == 1 and node.quantMax == 1:
    return # Oniguruma's ``assign_quantifier_body`` leaves ``X{1}`` alone.
  let inner = peelBareGroups(node.quantBody)
  if inner == nil or inner.kind != nkQuantifier:
    return
  if node.quantKind == qkPossessive or inner.quantKind == qkPossessive:
    return
  doAssert node.id == NoNodeId and inner.id == NoNodeId,
    "reduceNestedQuantifier: numbering runs later, so no id is set yet"
  let outerNum = quantTypeNum(node)
  let innerNum = quantTypeNum(inner)
  if outerNum < 0 or innerNum < 0:
    if node.quantMin == node.quantMax and inner.quantMin == inner.quantMax:
      # Two exact counts multiply.  A product past ``MaxRepeat`` is left as
      # the pair it was written as: the parser refuses to spell a count that
      # large, and Oniguruma reaching the same match through a product it does
      # allow is no reason to put one in the tree here.
      if inner.quantMin > 0 and node.quantMin > MaxRepeat div inner.quantMin:
        return
      node.quantMin = node.quantMin * inner.quantMin
      node.quantMax = node.quantMin
      node.quantBody = inner.quantBody
    elif innerNum in {1, 2} and node.quantKind == qkGreedy and node.quantMax > 1:
      # An unbounded inner repeat makes every iteration after the first match
      # empty, so a counted outer one needs no more than its minimum:
      # ``(?:a*){n,m}`` is ``(?:a*){n,n}``.  Oniguruma spells this rule out
      # beside the table rather than in it.
      node.quantMax = if node.quantMin == 0: 1 else: node.quantMin
    return
  let body = inner.quantBody
  case ReduceTable[innerNum][outerNum]
  of raAsIs:
    discard
  of raDel:
    node.quantBody = body
    node.setQuant(inner.quantMin, inner.quantMax, inner.quantKind)
  of raStar:
    node.quantBody = body
    node.setQuant(0, -1, qkGreedy)
  of raPlus:
    node.quantBody = body
    node.setQuant(1, -1, qkGreedy)
  of raLazyStar:
    node.quantBody = body
    node.setQuant(0, -1, qkLazy)
  of raLazyOpt:
    node.quantBody = body
    node.setQuant(0, 1, qkLazy)
  of raPlusLazyOpt:
    # The one rule that keeps the nesting rather than flattening it.
    node.setQuant(0, 1, qkLazy)
    inner.setQuant(1, -1, qkGreedy)

const ExpandStringMaxLength = 100
  ## Oniguruma's ``EXPAND_STRING_MAX_LENGTH``, in bytes, bounding both the
  ## count and the result of [expandStringRepeat].

proc foldsAnywhere(node: Node, flags: RegexFlags): bool =
  ## Whether case folding is in effect anywhere in the pattern -- the leading
  ## flags, or any ``(?i:...)`` scope inside it.  Answering per node would
  ## mean threading the scopes, and the one caller only needs to know whether
  ## to stand down.
  if (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card > 0:
    return true
  if node == nil:
    return false
  if node.kind == nkFlagGroup and
      (node.flagsOn * {rfIgnoreCase, rfIgnoreCaseAscii}).card > 0:
    return true
  for child in node.childNodes:
    if foldsAnywhere(child, flags):
      return true
  false

proc expandStringRepeat(node: Node) =
  ## Write out an exact repeat of a literal run: ``a{2}`` is ``aa``, and
  ## ``(?:ab){3}`` is ``ababab``.  Oniguruma's ``tune_quant`` does this, and
  ## like [reduceNestedQuantifier] it is an identity that matters for the
  ## shape it leaves: a repeat over a *string* is what the look-behind
  ## reduction can pin, a repeat over a repeat is not, so ``(?<=(?:a{2})*\b)``
  ## only reduces to the bare ``\b`` once the inner one is spelled out.
  ##
  ## The result is the node the pattern would have held had it been written
  ## out by hand: ``mergeLiterals`` already folds any run of adjacent literals
  ## into one ``nkString``, so this reaches no case that spelling does not.
  ## Which is exactly why [tuneRepeats] stands it down under case folding.
  ## ``(?i)ff`` matches ``\u{FB00}`` and ``(?i)f{2}`` does not, in Oniguruma
  ## as here: Oniguruma expands a multi-character fold while the repeat still
  ## holds a one-character string, and only writes the repeat out afterwards,
  ## so the pair never becomes one the fold can reach.  Reni folds at match
  ## time instead, so writing the repeat out *would* reach it.
  if node.quantMin != node.quantMax or node.quantMin <= 1 or
      node.quantMin > ExpandStringMaxLength:
    return
  let body = peelBareGroups(node.quantBody)
  if body == nil:
    return
  var runes: seq[Rune]
  case body.kind
  of nkLiteral:
    runes = @[body.rune]
  of nkEscapedLiteral:
    runes = @[body.escapedRune]
  of nkString:
    runes = body.runes
  else:
    return
  var size = 0
  for r in runes:
    size += r.size
  if size * node.quantMin > ExpandStringMaxLength:
    return
  doAssert node.id == NoNodeId,
    "expandStringRepeat: numbering runs later, so no id is set yet"
  var all = newSeqOfCap[Rune](runes.len * node.quantMin)
  for _ in 1 .. node.quantMin:
    all.add runes
  node[] = newStringNode(all)[]

proc tuneRepeats(node: Node, expand: bool) =
  ## Bring every repeat into the shape Oniguruma compiles it in, innermost
  ## first, so a stack of three collapses the way its bottom-up parse
  ## collapses one.  Each node is offered to each rewrite once, which is all
  ## Oniguruma does too -- it reduces a nested pair while parsing and expands
  ## a string repeat in ``tune_quant``, and this pass stands in for both.
  ##
  ## ``expand`` carries [foldsAnywhere]'s answer, inverted: the reduction is
  ## safe under folding, [expandStringRepeat] is not.
  if node == nil:
    return
  for child in node.childNodes:
    tuneRepeats(child, expand)
  if node.kind == nkQuantifier:
    reduceNestedQuantifier(node)
    if expand:
      expandStringRepeat(node)

proc isSimpleRepeatBody(node: Node): bool {.inline.} =
  ## Repeat bodies the look-behind reduction handles: strings, char types,
  ## char classes and backreferences. Captures and alternations do not reduce.
  ##
  ## ``\X`` and ``\R`` are char types here and are not ones Oniguruma
  ## reduces: it has no node for either, expanding both into a subexpression
  ## while parsing, and its table reads the node kind.  The difference is not
  ## cosmetic.  Both run over as many characters as the text gives them, so a
  ## body holding one has no fixed length and earns the window that makes
  ## ``(?<=\X*\b)`` refuse at offset 0 -- which reducing the repeat away
  ## would take from it.
  if node == nil:
    return false
  if node.kind == nkCharType:
    return node.charType notin {ctGraphemeCluster, ctNewlineSeq}
  node.kind in {
    nkLiteral, nkEscapedLiteral, nkString, nkCharClass, nkBackreference, nkNamedBackref
  }

proc reduceLeadingRepeat(node: Node): bool =
  ## Pin one leading repeat of a look-behind body to its lower bound.
  ## Returns whether it became empty, letting the caller advance. Skips
  ## possessives and non-simple bodies (see [isSimpleRepeatBody]).
  if node == nil or node.kind != nkQuantifier or node.quantKind == qkPossessive:
    return false
  if not isSimpleRepeatBody(peelBareGroups(node.quantBody)):
    return false
  node.quantMax = node.quantMin
  node.quantMin == 0

proc reduceLeadingElement(node: Node): bool =
  ## Pin one leading element of a look-behind front to empty where possible.
  ## Bare groups are transparent; anything else is tried as a repeat.
  let peeled = peelBareGroups(node)
  if peeled == nil:
    return true
  if peeled.kind == nkConcat:
    for child in peeled.children:
      if not reduceLeadingElement(child):
        return false
    return true
  reduceLeadingRepeat(peeled)

proc reduceLookBehindBody(node: Node) =
  ## Apply the reduction along the front of a look-behind body, stopping at
  ## the first element that does not empty. Each alternative is its own body.
  let peeled = peelBareGroups(node)
  if peeled == nil:
    return
  case peeled.kind
  of nkAlternation:
    for alt in peeled.alternatives:
      reduceLookBehindBody(alt)
  of nkConcat:
    for child in peeled.children:
      if not reduceLeadingElement(child):
        break
  else:
    discard reduceLeadingRepeat(peeled)

proc reduceLookBehindBodies(node: Node) =
  ## Run the reduction over every look-behind in the tree. Must run after
  ## ``normaliseInvertedRanges`` and before ``annotateContinuations``, whose
  ## possessives this pass skips.
  if node == nil:
    return
  if node.kind == nkLookaround and node.lookKind in {lkBehind, lkNegBehind}:
    reduceLookBehindBody(node.lookBody)
  for child in node.childNodes:
    reduceLookBehindBodies(child)

proc annotateContinuations(
    node: Node, flags: RegexFlags, after: ContinuationReq, calls: bool, mayRewrite: bool
) =
  ## Give every repeat what its continuation requires at the position it
  ## stops, and rewrite the greedy ones that cannot use a give-back at all --
  ## PCRE2's auto-possessification.
  ##
  ## One walk, because both arms ask the same question: a condition the
  ## continuation must meet where the repeat hands it the subject.  The greedy
  ## arm reads it as a byte set, the lazy arm as a leaf to test, and
  ## [ContinuationReq] carries both.
  ##
  ## ``mayRewrite`` is false below an inline ``(?i)`` and where the pattern has
  ## a ``\g<...>``.  ``calls`` gives up both tracks at every group, which a
  ## ``\g<...>`` can re-enter under a continuation this walk never sees.
  if node == nil:
    return
  case node.kind
  of nkConcat:
    # Right to left: what follows child ``i`` is child ``i+1`` folded into the
    # tail already built for it.
    var tail = after
    for i in countdown(node.children.high, 0):
      annotateContinuations(node.children[i], flags, tail, calls, mayRewrite)
      tail = reqBefore(node.children[i], flags, tail)
  of nkQuantifier:
    # What follows the body is the next iteration, or what follows the repeat
    # on the last one; neither is analysed, so the body walks under an
    # unknown follower.
    annotateContinuations(node.quantBody, flags, UnknownReq, calls, mayRewrite)
    case node.quantKind
    of qkGreedy:
      if mayRewrite and after.acceptKnown:
        var body: AcceptSet
        if leafAccept(node.quantBody, flags, body) and disjointAccept(
          body, after.accept
        ):
          # The body is one leaf, so a shorter split hands the continuation a
          # character that leaf accepted; one that can begin with none of them
          # fails at every split.
          node.quantKind = qkPossessive
        elif after.accept.nonAscii == {} and after.accept.ascii.card == 1:
          # The give-backs stay, but the continuation can begin with one
          # character only, so every other position fails at its first leaf.
          # ``accept`` being a *superset* is what makes a singleton a
          # requirement (C27).
          for b in after.accept.ascii:
            node.quantFollowByte = int16(b)
    of qkLazy:
      node.quantNextLeaf = after.leaf
    of qkPossessive:
      discard
  of nkAlternation:
    for alt in node.alternatives:
      annotateContinuations(alt, flags, after, calls, mayRewrite)
  of nkCapture:
    annotateContinuations(
      node.captureBody, flags, (if calls: UnknownReq else: after), calls, mayRewrite
    )
  of nkNamedCapture:
    annotateContinuations(
      node.namedCaptureBody,
      flags,
      (if calls: UnknownReq else: after),
      calls,
      mayRewrite,
    )
  of nkGroup:
    annotateContinuations(
      node.groupBody, flags, (if calls: UnknownReq else: after), calls, mayRewrite
    )
  of nkFlagGroup:
    # An inline ``(?i)`` widens every leaf below it, and the sets here are
    # written for folding off, so nothing below may be rewritten.  The walk
    # still descends: a leaf claimed under it is dropped at match time, where
    # the arm checks ``ctx.flags``.
    for child in node.childNodes:
      annotateContinuations(child, flags, UnknownReq, calls, false)
  else:
    # An atomic group, a lookaround body, an absent expression: each ends its
    # own continuation, which is not ``after``.
    for child in node.childNodes:
      annotateContinuations(child, flags, UnknownReq, calls, mayRewrite)

proc leadSimpleRepeat(node: Node, flags: RegexFlags): Node =
  ## Unbounded greedy or possessive repeat over a one-way leaf every match
  ## must start inside, or nil. The run must be unbounded: a bounded one
  ## reaches further from the next start. Zero-width wrappers are peeled, as
  ## is a repeat with ``min >= 1``, greedy/lazy, and non-inverted bounds,
  ## whose body must match at the start -- ``(?:\w+\s+){3,}`` leads with
  ## ``\w+``.
  ## Possessive qualifies too, and more simply: it has one end, the run's,
  ## from every start inside it. Fixed-width prefix leaves are allowed only
  ## as a subset of the repeat body, so skipped starts share the same run end.
  if node == nil:
    return nil
  case node.kind
  of nkConcat:
    if node.children.len == 0:
      return nil
    let head = leadSimpleRepeat(node.children[0], flags)
    if head != nil:
      return head
    # Case folding widens ASCII leaves; an inline ``(?i)`` needs no test
    # since the parser wraps it in a flag group, which is no leaf.
    if (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card > 0:
      return nil
    var prefix: set[uint8]
    for child in node.children:
      var leaf: set[uint8]
      if exactAsciiLeaf(child, leaf):
        prefix = prefix + leaf
        continue
      let q = leadSimpleRepeat(child, flags)
      var body: set[uint8]
      if q == nil or not exactAsciiLeaf(q.quantBody, body) or not (prefix <= body):
        return nil
      return q
    nil
  of nkCapture:
    leadSimpleRepeat(node.captureBody, flags)
  of nkNamedCapture:
    leadSimpleRepeat(node.namedCaptureBody, flags)
  of nkGroup:
    leadSimpleRepeat(node.groupBody, flags)
  of nkQuantifier:
    let body = node.quantBody
    if body == nil:
      return nil
    if node.quantKind in {qkGreedy, qkPossessive} and node.quantMax < 0:
      case body.kind
      of nkLiteral, nkEscapedLiteral, nkCharClass:
        return node
      of nkCharType:
        # ``\R`` and ``\X`` have variable-width runs.
        if body.charType notin {ctNewlineSeq, ctGraphemeCluster}:
          return node
        return nil
      else:
        discard
    # Mandatory repeat looks through to the body's run. Possessive is left
    # out here -- an atomic body's end is not the outer repeat's.
    if node.quantMin >= 1 and node.quantKind in {qkGreedy, qkLazy}:
      return leadSimpleRepeat(body, flags)
    nil
  else:
    nil

proc leadRunSkipSafe(node: Node): bool =
  ## Whether starts inside the leading run may be skipped. Holds only while
  ## the continuation verdict depends on position alone, not on captures,
  ## recursion state, or per-attempt side effects.
  if node == nil:
    return true
  case node.kind
  of nkBackreference, nkNamedBackref, nkConditional, nkSubexpCall, nkAbsent,
      nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    return false
  of nkAnchor:
    if node.anchor == akSearchBegin:
      return false
  else:
    discard
  for child in node.childNodes:
    if not leadRunSkipSafe(child):
      return false
  true

proc hasTopLevelFindLongest(node: Node): bool =
  ## True when a scoped ``(?L:...)`` spans the whole pattern. The parser
  ## restores ``p.flags`` on scoped-group exit, so ``p.currentFlags`` only
  ## carries the isolated ``(?L)`` spelling; walk the finished AST instead.
  ## Transparent wrappers (``(?:...)`` and ordinary ``(?flags:...)``) are
  ## unwrapped. Anything else means the ``L`` group, if any, does not span
  ## the pattern -- such patterns are rejected elsewhere, so answer false.
  var n = node
  while n != nil:
    case n.kind
    of nkGroup:
      n = n.groupBody
    of nkConcat:
      if n.children.len == 1:
        n = n.children[0]
      else:
        return false
    of nkFlagGroup:
      if rfFindLongest in n.flagsOn:
        return true
      if n.flagBody == nil:
        return false
      n = n.flagBody
    else:
      return false
  false

proc re*(pattern: string, flags: RegexFlags = {}): Regex =
  validateUtf8(pattern)
  var p = initParser(pattern, flags)
  var ast = p.parseRegex()
  if not p.atEnd:
    raise newException(RegexError, "unexpected character at position " & $p.position)
  p.validateLeadingOnlyPosition(ast)
  # Before anything else reads the tree, and before unnamed captures are
  # demoted into groups.  See [flattenLiteralGroups].  Skipped when the pattern
  # has no ``(?:...)`` at all.
  if p.sawPlainGroup:
    flattenLiteralGroups(ast)
  var namedCaptures = p.namedCaptures
  var captureCount = p.captureCount
  # Resolve forward reference conditionals now that all named captures are known
  if namedCaptures.len > 0:
    resolveForwardRefConditions(ast, namedCaptures)
  # When named captures exist, demote unnamed captures to non-capturing groups
  # (Oniguruma default behavior: unnamed groups don't capture when named groups present)
  if namedCaptures.len > 0:
    validateNoNumberedRefs(ast)
    var indexMap: Table[int, int]
    var newIdx = 0
    for i in 0 ..< namedCaptures.len:
      indexMap[namedCaptures[i][1]] = newIdx
      namedCaptures[i] = (namedCaptures[i][0], newIdx)
      inc newIdx
    captureCount = namedCaptures.len
    ast = demoteUnnamedCaptures(ast, indexMap)
  var bodies: seq[Node]
  var groupFlags: seq[RegexFlags]
  collectGroupBodies(ast, bodies, groupFlags, flags)
  # Check for never-ending recursion, including mutual recursion via
  # subexpression calls.
  for i, body in bodies:
    if body == nil:
      continue
    var visiting = initHashSet[int]()
    visiting.incl(i)
    if hasRecursiveCycle(i, body, bodies, namedCaptures, visiting):
      raise newException(RegexError, "never ending recursion")
  # Check for absent expressions in lookbehinds (including via subexp calls)
  validateLookbehinds(ast, bodies, namedCaptures, false)
  # Validate that every numeric / named reference points to an existing group.
  validateNumericRefs(ast, captureCount, namedCaptures)
  # Merge consecutive literals into nkString nodes
  ast = mergeLiterals(ast)
  # Must run before any analysis that reads a quantifier's bounds or kind.
  normaliseInvertedRanges(ast)
  # Collapse a repeat over a repeat and write out an exact repeat of a
  # literal, as Oniguruma does while parsing and in ``tune_quant``.  Must run
  # before the look-behind reduction, which only sees a leading repeat over a
  # simple atom and so needs both shapes settled first.
  tuneRepeats(ast, expand = not foldsAnywhere(ast, flags))
  # Pin a look-behind body's leading repeats to their lower bound.
  # Runs before every pass that reads bounds; a reduced body may become fixed-length.
  reduceLookBehindBodies(ast)
  # Must run on the final AST: ``mergeLiterals`` rebuilds nodes and would drop
  # the annotation.  Nodes default to ``quantBodyPure == false``, so a rewrite
  # added after this line stays safe (it just always snapshots).
  discard markQuantBodyPure(ast)
  # Same rule: a node this pass never reaches keeps the flag save.
  discard markGroupBodyKeepsFlags(ast)
  # ``p.currentFlags`` only carries the isolated ``(?L)`` spelling: scoped
  # groups restore ``p.flags`` on exit. A scoped ``(?L:...)`` that spans the
  # whole pattern is the same global option, so lift it from the AST.
  let scopedLongest = hasTopLevelFindLongest(ast)
  let finalFlags =
    flags + (p.currentFlags * {rfFindLongest}) +
    (if scopedLongest: {rfFindLongest} else: {})
  # Same rule: must see the final AST.  Annotate under ``finalFlags``, the
  # flags the matcher starts from (``resetForRegex`` seeds ``ctx.flags`` from
  # ``regex.flags``), since an annotation is used only while the two agree.
  # Folding off, because both tracks are written for it.  ``\g<...>`` blocks
  # the rewrite pattern-wide and gives up both tracks at every group besides.
  let noFold = (finalFlags * {rfIgnoreCase, rfIgnoreCaseAscii}).card == 0
  let calls = hasSubexpCall(ast)
  if noFold:
    annotateContinuations(ast, finalFlags, UnknownReq, calls, not calls)
  annotateLookaroundBounds(ast, finalFlags)
  # Re-collect group bodies after AST transformation
  bodies = @[]
  groupFlags = @[]
  collectGroupBodies(ast, bodies, groupFlags, flags)
  var firstCharCache: FirstCharCache = nil
  var levelBackrefs = false
  annotateTree(
    ast,
    finalFlags + {rfIgnoreCase},
    firstCharCache,
    levelBackrefs,
    # Folding off throughout, and no ``(?i)`` that could switch it on under a
    # trie the matcher already entered.
    (finalFlags * {rfIgnoreCase, rfIgnoreCaseAscii}).card == 0 and altTriesUsable(ast),
  )
  let leadRepeat = leadRepeatLeaf(ast, finalFlags)
  # ``leadRepeat`` includes the leaf test, so it replaces ``leadLeaf``.
  let leadLeaf =
    if leadRepeat != nil:
      nil
    else:
      leadFirstLeaf(ast, finalFlags)
  result = initRegex(
    pattern = pattern,
    ast = ast,
    flags = finalFlags,
    captureCount = captureCount,
    namedCaptures = namedCaptures,
    groupBodies = bodies,
    groupFlags = groupFlags,
    firstCharInfo = extractFirstChar(ast, finalFlags),
    literalScan = hasLiteralPrefix(ast, finalFlags),
    requiredByte =
      requiredByteRegion(ast, finalFlags, extractRequiredByte(ast, finalFlags)),
    semiEndAnchored = semiEndAnchored(ast),
    semiEndDMax = maxByteLen(ast, finalFlags),
    levelBackrefs = levelBackrefs,
    leadRun =
      if rfFindLongest in finalFlags:
        # findLongest fails every start on purpose, so no skip applies.
        nil
      else:
        let q = leadSimpleRepeat(ast, finalFlags)
        if q != nil and leadRunSkipSafe(ast): q else: nil,
    leadLeaf = leadLeaf,
    leadAnchors = leadAnchorSet(ast, finalFlags),
    leadRepeat = leadRepeat,
    leadBehind = leadBehindLiteral(ast, finalFlags),
  )
  # After the constructor, which numbers the tree the table indexes.  Derived
  # under ``result.flags`` rather than ``finalFlags`` because the runtime
  # validity check is against the flags the ``Regex`` carries.
  result.setLeafGates(buildLeafGates(result.nodes, result.flags))
