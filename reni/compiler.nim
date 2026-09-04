import std/[tables, sets, unicode]

import types, parser

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
    node.quantMin == 0 or canMatchEmpty(node.quantBody)
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
    # Optional quantifiers (min == 0) can always skip the body, so they never
    # force recursion. Required reps propagate whatever the body does.
    if node.quantMin == 0:
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
          merged.add Node(kind: nkString, runes: run)
          run = @[]
        elif run.len == 1:
          merged.add Node(kind: nkLiteral, rune: run[0])
          run = @[]
        merged.add mc
    if run.len >= 2:
      merged.add Node(kind: nkString, runes: run)
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
  ## Records on every quantifier whether its body can write state that a
  ## rollback snapshot restores: captures, ``keepStart`` (``\K``), flags /
  ## grapheme mode or ``subjectEnd``.  ``nkSubexpCall`` counts conservatively.
  ## Returns that verdict for ``node``'s own subtree; the flag stored on a
  ## quantifier is its negation.
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
  for child in node.childNodes:
    if markQuantBodyPure(child):
      result = true
  if node.kind == nkQuantifier:
    # ``result`` is the OR over the children, and the quantifier node itself
    # writes nothing, so it is exactly the body's verdict.
    node.quantBodyPure = not result

proc annotateTree(node: Node) =
  ## Single post-parse walk over the finished AST: precomputes each character
  ## class's ASCII membership bitmap, so the matcher can answer ASCII input
  ## with one bit test instead of walking the atoms.  Stored before negation,
  ## which ``matchCharClassAt`` applies to the lookup's answer.
  if node == nil:
    return
  if node.kind == nkCharClass:
    var ascii: set[uint8]
    var nonAscii, predicate: bool
    if classAsciiMatches(node, ascii, nonAscii, predicate):
      node.asciiSet = ascii
      node.asciiSetOk = true
  for child in node.childNodes:
    annotateTree(child)

proc re*(pattern: string, flags: RegexFlags = {}): Regex =
  validateUtf8(pattern)
  var p = initParser(pattern, flags)
  var ast = p.parseRegex()
  if not p.atEnd:
    raise newException(RegexError, "unexpected character at position " & $p.position)
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
  # Must run on the final AST: ``mergeLiterals`` rebuilds nodes and would drop
  # the annotation.  Nodes default to ``quantBodyPure == false``, so a rewrite
  # added after this line stays safe (it just always snapshots).
  discard markQuantBodyPure(ast)
  let finalFlags = flags + (p.currentFlags * {rfFindLongest})
  # Same rule: must see the final AST.  Annotate under ``finalFlags``, the
  # flags the matcher starts from (``resetForRegex`` seeds ``ctx.flags`` from
  # ``regex.flags``), since an annotation is used only while the two agree.
  annotateLookaroundBounds(ast, finalFlags)
  # Re-collect group bodies after AST transformation
  bodies = @[]
  groupFlags = @[]
  collectGroupBodies(ast, bodies, groupFlags, flags)
  annotateTree(ast)
  initRegex(
    pattern = pattern,
    ast = ast,
    flags = finalFlags,
    captureCount = captureCount,
    namedCaptures = namedCaptures,
    groupBodies = bodies,
    groupFlags = groupFlags,
    firstCharInfo = extractFirstChar(ast, finalFlags),
    literalScan = hasLiteralPrefix(ast, finalFlags),
    requiredByte = extractRequiredByte(ast, finalFlags),
    semiEndAnchored = semiEndAnchored(ast),
    semiEndDMax = maxByteLen(ast, finalFlags),
  )
