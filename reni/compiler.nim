import std/[algorithm, tables, sets, unicode]

import types, unicode_utils, parser, leafgate, lookbehind_tune, stackguard

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
      namedCapturePos: node.namedCapturePos,
    )
  of nkConcat:
    var children = newSeq[Node](node.children.len)
    for i, child in node.children.view:
      children[i] = demoteUnnamedCaptures(child, indexMap)
    Node(kind: nkConcat, children: children)
  of nkAlternation:
    var alts = newSeq[Node](node.alternatives.len)
    for i, alt in node.alternatives.view:
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
      lookPos: node.lookPos,
      lookBody: demoteUnnamedCaptures(node.lookBody, indexMap),
      lookFail: node.lookFail,
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
        newRefIdx = int32(indexMap[oldIdx] + 1) # back to 1-based
    Node(
      kind: nkConditional,
      condKind: node.condKind,
      condRefIndex: newRefIdx,
      condScope: node.condScope,
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
    Node(
      kind: nkBackreference,
      backrefIndex: newIdx,
      backrefLevel: node.backrefLevel,
      backrefLeveled: node.backrefLeveled,
    )
  of nkSubexpCall:
    var newCallIndex = node.callIndex
    if node.callIndex > 0:
      let oldIdx = node.callIndex - 1
      if oldIdx in indexMap:
        newCallIndex = indexMap[oldIdx] + 1
    Node(
      kind: nkSubexpCall,
      callIndex: newCallIndex,
      callName: node.callName,
      callPos: node.callPos,
    )
  of nkAbsent:
    Node(
      kind: nkAbsent,
      absentKind: node.absentKind,
      absentLoopsOnExpr: node.absentLoopsOnExpr,
      absentPos: node.absentPos,
      absentLoopLo: node.absentLoopLo,
      absentLoopHi: node.absentLoopHi,
      absentBody: demoteUnnamedCaptures(node.absentBody, indexMap),
      absentExpr: demoteUnnamedCaptures(node.absentExpr, indexMap),
    )
  else:
    # Leaf nodes: nkLiteral, nkEscapedLiteral, nkCharType, nkCharClass,
    # nkAnchor, nkNamedBackref — no transformation needed
    node

proc hasGroupName(namedCaptures: seq[(string, int)], name: string): bool =
  for (n, _) in namedCaptures:
    if n == name:
      return true
  false

proc resolveBareNameConditions(node: Node, namedCaptures: seq[(string, int)]): bool =
  ## Turn each condition whose text is a group's name, ``(?(n)...)``, into a
  ## reference to that group, wherever the group is: reni's own spelling.
  ## The parser read every such condition as a pattern, as Oniguruma does.
  ## True when any became a reference.
  if node == nil:
    return false
  if node.kind == nkConditional and node.condKind == ckRegexCond and
      node.condRefName.len > 0 and namedCaptures.hasGroupName(node.condRefName):
    node.condKind = ckNamedRef
    node.condBody = nil
    result = true
  for child in node.childNodes:
    if resolveBareNameConditions(child, namedCaptures):
      result = true

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

proc callTarget(node: Node, bodies: seq[Node], namedCaptures: seq[(string, int)]): int =
  ## The 0-based group the call ``node`` runs, or -1 when there is no body to
  ## follow: a call to the whole pattern (``\g<0>``, ``(?R)``), a number
  ## [validateNumericRefs] has yet to reject, or a group with no body.  A name
  ## resolves to the first group declared with it.
  var idx = -1
  if node.callIndex > 0:
    idx = node.callIndex - 1
  elif node.callName.len > 0:
    for (name, i) in namedCaptures:
      if name == node.callName:
        idx = i
        break
  if idx >= 0 and idx < bodies.len and bodies[idx] != nil: idx else: -1

const
  RecursionExist = 1'u8 ## The walk reached the group being checked.
  RecursionMust = 2'u8 ## ... on every path it took.
  RecursionInfinite = 4'u8 ## ... on a path that had consumed nothing.
  MaxRecursionCheckSteps {.intdefine: "reniMaxRecursionCheckSteps".} = 100_000_000
    ## Steps [checkNeverEndingRecursion] may take before it raises
    ## ``RegexLimitError``.  Each group's check walks every group that shares a
    ## cycle of calls with it, as Oniguruma's does, so a cycle costs the square
    ## of the groups in it: a ring of N groups each calling the next takes 4N²
    ## steps, 52 million for the 3,600 a release build's stack budget holds,
    ## and N groups that each call one that calls them all take as many, at 6
    ## to 8 ns each.  The 6,030 grammar patterns take at most 6,320.
  MaxRecursionCheckRewalkSteps {.intdefine: "reniMaxRecursionCheckRewalkSteps".} =
    10_000_000
    ## Of those, the steps a check may take walking into groups it has walked
    ## into before.  Inside a cycle of calls the walk goes down every path, as
    ## Oniguruma's does: 9 groups that each call all 9 take 12.8 million steps,
    ## 10 take 138 million and 11 take 1.6 billion.  A ring takes none, nor
    ## does any grammar pattern.

type RecursionCheck = object
  ## The state of [checkNeverEndingRecursion].  A slot is a group: slot 0 the
  ## whole pattern, which ``\g<0>`` calls, and slot ``k`` group ``k``.
  ast: Node
  bodies: seq[Node]
  namedCaptures: seq[(string, int)]
  called: seq[bool]
    ## A call that can run reaches the group (Oniguruma's ``CALLED``).  Only
    ## these groups are checked.
  recursive: seq[bool]
    ## The group runs itself again, through calls or not (Oniguruma's
    ## ``RECURSION``).  Only these groups are checked.
  component: seq[int]
    ## The group's strongly connected component, where a group leads to the
    ## groups its body holds and calls.  Set for the groups a call reaches, -1
    ## for the rest.
  componentEntered: seq[int] ## How many groups of each component the walk is inside.
  check: int ## The number of the check running, from 1.
  memo: seq[uint8]
    ## The flags of the walk into slot ``s`` with head ``h``, at ``2*s+h``,
    ## for a walk begun while the walk was inside no group of the slot's
    ## component.  Nothing that walk reaches is then on the path to it, so it
    ## goes the same way each time, and it leaves every length it needs
    ## worked out, so walking it again would change nothing.
  memoCheck: seq[int] ## The check each ``memo`` entry belongs to.
  walked: seq[int]
    ## The check that last walked into slot ``s`` with head ``h``, at
    ## ``2*s+h``, for [checkBudget].
  rewalking: int
    ## How many of the walks the walk is inside went where their check had
    ## walked into before.
  marked: seq[bool]
    ## Oniguruma's ``MARK1``: the group being checked, and the groups whose
    ## length is being worked out.  Both count as matching empty.
  entered: seq[bool] ## Oniguruma's ``MARK2``: the groups the walk is inside.
  minLen: seq[int8]
    ## Whether a group always consumes, once worked out: -1 not yet, 0 no,
    ## 1 yes.  Kept from one group's check to the next, as Oniguruma keeps
    ## ``FIXED_MIN``, so a group worked out while another was being checked
    ## keeps the 0 that one counted as.
  openRefs: HashSet[pointer]
    ## The backreferences written inside a group they read, which count as
    ## matching empty (``ND_ST_RECURSION`` on a backreference).
  stackBase: int ## Where the check began, for [checkBudget].
  steps: int ## The steps taken so far, for [checkBudget].
  rewalkSteps: int ## The steps taken so far while ``rewalking``.

template checkBudget(c: var RecursionCheck) =
  ## Count a step of [consumes] or [recursionFlags], and raise
  ## ``RegexLimitError`` past ``MaxRecursionCheckSteps`` or
  ## ``MaxRecursionCheckRewalkSteps``, or before the native stack, or a debug
  ## build's call depth, runs out.  Both follow calls, and a chain of calls is
  ## as long as the pattern: ``MaxNestingDepth`` does not bound it.
  inc c.steps
  if c.steps > MaxRecursionCheckSteps:
    raise newException(RegexLimitError, "compile step limit exceeded")
  if c.rewalking > 0:
    inc c.rewalkSteps
    if c.rewalkSteps > MaxRecursionCheckRewalkSteps:
      raise newException(RegexLimitError, "compile step limit exceeded")
  if nearStackEnd(c.stackBase):
    raise newException(RegexLimitError, "compile stack budget exceeded")

proc slotBody(c: RecursionCheck, slot: int): Node =
  if slot == 0:
    c.ast
  else:
    c.bodies[slot - 1]

proc groupSlot(node: Node): int =
  ## The slot of the group ``node``, or -1 when it is not one.
  case node.kind
  of nkCapture:
    node.captureIndex + 1
  of nkNamedCapture:
    node.namedCaptureIndex + 1
  else:
    -1

proc callSlot(c: RecursionCheck, node: Node): int =
  ## The slot the call ``node`` runs, or -1 when there is no body to follow.
  if node.callIndex == 0 and node.callName.len == 0:
    return 0
  let idx = callTarget(node, c.bodies, c.namedCaptures)
  if idx < 0:
    -1
  else:
    idx + 1

iterator refSlots(c: RecursionCheck, node: Node): int =
  ## The slots the backreference ``node`` reads.
  if node.kind == nkBackreference:
    if node.backrefIndex >= 1 and node.backrefIndex <= c.bodies.len:
      yield node.backrefIndex
  else:
    for idx in c.namedCaptures.namedGroupsRead(node.backrefName, node.backrefScope):
      yield idx + 1

proc consumes(c: var RecursionCheck, node: Node): bool

proc groupConsumes(c: var RecursionCheck, slot: int): bool =
  ## [consumes] for a group, and for a call to it.
  if c.minLen[slot] >= 0:
    return c.minLen[slot] == 1
  if c.marked[slot]:
    return false
  c.marked[slot] = true
  result = c.consumes(c.slotBody(slot))
  c.marked[slot] = false
  c.minLen[slot] = int8(result)

proc consumes(c: var RecursionCheck, node: Node): bool =
  ## Whether ``node`` always consumes something: Oniguruma's
  ## ``node_min_byte_len`` is not 0.  Every part is worked out, as there, even
  ## once one settles the answer, since working out a group fixes its length.
  if node == nil:
    return false
  c.checkBudget()
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkCharType, nkCharClass:
    result = true
  of nkString:
    result = node.runes.len > 0
  of nkConcat:
    result = false
    for child in node.children.view:
      if c.consumes(child):
        result = true
  of nkAlternation:
    result = node.alternatives.len > 0
    for alt in node.alternatives.view:
      if not c.consumes(alt):
        result = false
  of nkQuantifier:
    result =
      effectiveQuantBounds(node.quantMin, node.quantMax).lo > 0 and
      c.consumes(node.quantBody)
  of nkCapture, nkNamedCapture:
    result = c.groupConsumes(groupSlot(node))
  of nkGroup:
    result = c.consumes(node.groupBody)
  of nkAtomicGroup:
    result = c.consumes(node.atomicBody)
  of nkFlagGroup:
    result = c.consumes(node.flagBody)
  of nkBackreference, nkNamedBackref:
    # The shortest of the groups it reads.  Inside one of them it reads unset.
    if cast[pointer](node) in c.openRefs:
      return false
    result = true
    for slot in c.refSlots(node):
      if not c.groupConsumes(slot):
        result = false
  of nkSubexpCall:
    let slot = c.callSlot(node)
    result = slot >= 0 and c.groupConsumes(slot)
  of nkAbsent:
    # Only ``(?~|X|E)`` holds what ``E`` consumes; the other forms may stop
    # where they start.  An E that is the loop around X
    # (``absentLoopsOnExpr``) consumes when it must run, and then works out X
    # first, as it holds X.
    if node.absentKind != abExpression:
      result = false
    elif node.absentLoopsOnExpr:
      result = node.absentLoopLo > 0
      if result:
        discard c.consumes(node.absentBody)
    else:
      result = c.consumes(node.absentExpr)
  of nkConditional:
    var yes = node.condKind == ckRegexCond and c.consumes(node.condBody)
    if c.consumes(node.condYes):
      yes = true
    let no = c.consumes(node.condNo)
    result = yes and no
  of nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    # ``(*FAIL)`` too: Oniguruma reads it as a callout here, not as its fail
    # node.
    result = false

proc recursionFlags(c: var RecursionCheck, node: Node, head: bool): uint8

proc enterGroup(c: var RecursionCheck, slot: int, head: bool): uint8 =
  if c.entered[slot]:
    return 0
  if c.marked[slot]:
    return
      if head:
        RecursionExist or RecursionMust or RecursionInfinite
      else:
        RecursionExist or RecursionMust
  let component = c.component[slot]
  when not defined(release):
    # Debug builds only: in a release build the -1 fails the index below.
    doAssert component >= 0, "a group outside every component"
  let fresh = c.componentEntered[component] == 0
  let key = 2 * slot + ord(head)
  if fresh and c.memoCheck[key] == c.check:
    return c.memo[key]
  let rewalk = c.walked[key] == c.check
  c.walked[key] = c.check
  c.entered[slot] = true
  inc c.componentEntered[component]
  c.rewalking += ord(rewalk)
  result = c.recursionFlags(c.slotBody(slot), head)
  c.rewalking -= ord(rewalk)
  dec c.componentEntered[component]
  c.entered[slot] = false
  if fresh:
    c.memo[key] = result
    c.memoCheck[key] = c.check

proc recursionFlags(c: var RecursionCheck, node: Node, head: bool): uint8 =
  ## Oniguruma's ``infinite_recursive_call_check``: how ``node`` reaches the
  ## group being checked, where ``head`` says nothing has been consumed since
  ## that group began.  Returns at once with ``RecursionInfinite``.
  if node == nil:
    return 0
  c.checkBudget()
  case node.kind
  of nkConcat:
    var head = head
    for child in node.children.view:
      let flags = c.recursionFlags(child, head)
      if (flags and RecursionInfinite) != 0:
        return flags
      result = result or flags
      if head and c.consumes(child):
        head = false
  of nkAlternation:
    var must = RecursionMust
    for alt in node.alternatives.view:
      let flags = c.recursionFlags(alt, head)
      if (flags and RecursionInfinite) != 0:
        return flags
      result = result or (flags and RecursionExist)
      must = must and flags
    result = result or must
  of nkQuantifier:
    let bounds = effectiveQuantBounds(node.quantMin, node.quantMax)
    if bounds.hi != 0:
      result = c.recursionFlags(node.quantBody, head)
      if bounds.lo == 0:
        result = result and not RecursionMust
  of nkCapture, nkNamedCapture:
    result = c.enterGroup(groupSlot(node), head)
  of nkSubexpCall:
    let slot = c.callSlot(node)
    if slot >= 0:
      result = c.enterGroup(slot, head)
  of nkGroup:
    result = c.recursionFlags(node.groupBody, head)
  of nkAtomicGroup:
    result = c.recursionFlags(node.atomicBody, head)
  of nkFlagGroup:
    result = c.recursionFlags(node.flagBody, head)
  of nkLookaround:
    result = c.recursionFlags(node.lookBody, head)
  of nkAbsent:
    # Oniguruma tries the absent pattern X in a loop that may stop before it
    # (``make_absent_engine``), so no recursion in it is one every path
    # takes.  X stands in a sequence in that loop, so its length is worked
    # out once it is walked, as is E's after it, in the sequence the tree of
    # ``(?~|X|E)`` is.  An E that is the loop around X (``absentLoopsOnExpr``)
    # is no part of that sequence, and E{0} never runs X.
    let loops = node.absentLoopsOnExpr
    if node.absentBody != nil and (not loops or node.absentLoopHi != 0):
      let flags = c.recursionFlags(node.absentBody, head)
      if (flags and RecursionInfinite) != 0:
        return flags
      result = flags and RecursionExist
      if head:
        discard c.consumes(node.absentBody)
    if node.absentKind == abExpression and not loops:
      let flags = c.recursionFlags(node.absentExpr, head)
      if (flags and RecursionInfinite) != 0:
        return flags
      result = result or flags
      if head:
        discard c.consumes(node.absentExpr)
  of nkConditional:
    let cond = if node.condKind == ckRegexCond: node.condBody else: nil
    result = c.recursionFlags(cond, head)
    if (result and RecursionInfinite) != 0:
      return
    if node.condYes != nil:
      let flags = c.recursionFlags(node.condYes, head and not c.consumes(cond))
      if (flags and RecursionInfinite) != 0:
        return flags
      result = result or flags
    if node.condNo != nil:
      let flags = c.recursionFlags(node.condNo, head)
      if (flags and RecursionInfinite) != 0:
        return flags
      result = result or (flags and RecursionExist)
      if (flags and RecursionMust) == 0:
        result = result and not RecursionMust
    else:
      # Oniguruma's rule, though a recursion in the condition runs either way.
      result = result and not RecursionMust
  else:
    discard

proc collectEdges(c: RecursionCheck, node: Node, edges: var seq[int]) =
  ## Add the slots ``node`` runs itself: the groups it holds and the ones it
  ## calls, not the ones those run in turn.
  if node == nil:
    return
  let slot =
    if node.kind == nkSubexpCall:
      c.callSlot(node)
    else:
      groupSlot(node)
  if slot >= 0:
    edges.add slot
    return
  for child in node.childNodes:
    c.collectEdges(child, edges)

type ComponentSearch = object
  ## Tarjan's algorithm over the slots, for [findComponents].
  edges: seq[int] ## The slots each slot reached runs, added as it is reached.
  order: seq[int] ## The order a slot was reached in, from 1; 0 for not yet.
  low: seq[int] ## The lowest order the slot leads back to.
  stack: seq[int]
  onStack: seq[bool]
  reached: int
  components: int ## The components found so far, which number them.
  path: seq[tuple[slot, edge, last: int]]
    ## The slots being visited, each with the part of ``edges`` it has yet to
    ## follow: the recursion of Tarjan's ``strongconnect``, kept here as a
    ## chain of calls is as long as the pattern.

proc reach(c: var RecursionCheck, t: var ComponentSearch, v: int) =
  inc t.reached
  t.order[v] = t.reached
  t.low[v] = t.reached
  t.stack.add v
  t.onStack[v] = true
  let first = t.edges.len
  c.collectEdges(c.slotBody(v), t.edges)
  t.path.add (v, first, t.edges.len)

proc connect(c: var RecursionCheck, t: var ComponentSearch, root: int) =
  c.reach(t, root)
  while t.path.len > 0:
    let v = t.path[^1].slot
    let edge = t.path[^1].edge
    if edge < t.path[^1].last:
      inc t.path[^1].edge
      let w = t.edges[edge]
      if w == v:
        c.recursive[v] = true
      if t.order[w] == 0:
        c.reach(t, w)
      elif t.onStack[w]:
        t.low[v] = min(t.low[v], t.order[w])
      continue
    discard t.path.pop()
    if t.low[v] == t.order[v]:
      let component = t.components
      inc t.components
      while true:
        let w = t.stack.pop()
        t.onStack[w] = false
        c.component[w] = component
        if w == v:
          break
    if t.path.len > 0:
      let u = t.path[^1].slot
      t.low[u] = min(t.low[u], t.low[v])

proc findComponents(c: var RecursionCheck, slots: int) =
  ## Fill ``c.component`` and ``c.recursive`` for the groups a call reaches,
  ## the only ones a check walks into: a group runs itself again when it
  ## calls itself or shares its component.  Then size ``c.componentEntered``,
  ## one count for each component.
  var t = ComponentSearch(
    order: newSeq[int](slots), low: newSeq[int](slots), onStack: newSeq[bool](slots)
  )
  c.recursive = newSeq[bool](slots)
  c.component = newSeq[int](slots)
  for slot in 0 ..< slots:
    c.component[slot] = -1
  for slot in 0 ..< slots:
    if c.called[slot] and t.order[slot] == 0:
      c.connect(t, slot)
  c.componentEntered = newSeq[int](t.components)
  var size = newSeq[int](t.components)
  for slot in 0 ..< slots:
    if t.order[slot] != 0:
      inc size[c.component[slot]]
  for slot in 0 ..< slots:
    if t.order[slot] != 0 and size[c.component[slot]] > 1:
      c.recursive[slot] = true

proc markCalled(
    c: var RecursionCheck, node: Node, inCall: bool, pending: var seq[int]
) =
  ## Oniguruma's ``tune_call2``: mark the groups a call that can run reaches,
  ## adding each to ``pending`` for its body to be marked in turn.  Outside a
  ## called body, a call under ``{0}`` cannot run, nor one in the absent
  ## pattern of ``(?~|X|E{0})``, where E is the loop around X
  ## (``absentLoopsOnExpr``) and holds no call itself.
  if node == nil:
    return
  case node.kind
  of nkSubexpCall:
    let slot = c.callSlot(node)
    if slot >= 0 and not c.called[slot]:
      c.called[slot] = true
      pending.add slot
    return
  of nkQuantifier:
    if not inCall and effectiveQuantBounds(node.quantMin, node.quantMax).hi == 0:
      return
  of nkAbsent:
    if not inCall and node.absentLoopsOnExpr and node.absentLoopHi == 0:
      return
  else:
    discard
  for child in node.childNodes:
    c.markCalled(child, inCall, pending)

proc markOpenRefs(c: var RecursionCheck, node: Node, open: var seq[bool]) =
  ## Fill ``c.openRefs``, where ``open`` holds the groups around ``node``.
  if node == nil:
    return
  if node.kind in {nkBackreference, nkNamedBackref}:
    for read in c.refSlots(node):
      if open[read]:
        c.openRefs.incl(cast[pointer](node))
        break
  let slot = groupSlot(node)
  if slot >= 0:
    open[slot] = true
  for child in node.childNodes:
    c.markOpenRefs(child, open)
  if slot >= 0:
    open[slot] = false

proc checkGroup(c: var RecursionCheck, slot: int) =
  if not c.called[slot] or not c.recursive[slot]:
    return
  inc c.check
  c.marked[slot] = true
  let flags = c.recursionFlags(c.slotBody(slot), true)
  if (flags and (RecursionMust or RecursionInfinite)) != 0:
    raise newException(RegexError, "never ending recursion")
  c.marked[slot] = false

proc checkGroups(c: var RecursionCheck, node: Node) =
  ## Oniguruma's ``infinite_recursive_call_check_trav``: check every group in
  ## ``node``, in its order.
  if node == nil:
    return
  case node.kind
  of nkCapture, nkNamedCapture:
    c.checkGroup(groupSlot(node))
  of nkConditional:
    # Both branches before the condition, as there.
    c.checkGroups(node.condYes)
    c.checkGroups(node.condNo)
    c.checkGroups(node.condBody)
    return
  else:
    discard
  for child in node.childNodes:
    c.checkGroups(child)

proc checkNeverEndingRecursion(
    ast: Node, bodies: seq[Node], namedCaptures: seq[(string, int)], readsGroups: bool
) =
  ## Reject a recursion that never ends, as Oniguruma does
  ## (``ONIGERR_NEVER_ENDING_RECURSION``): a group a call can run that calls
  ## itself on every path through it, or before it has consumed anything.
  ## ``\g<0>``, ``a|\g<0>``, ``(a\g<1>)`` and ``x|(?<=\g<0>)`` are rejected,
  ## ``a|b\g<0>`` and ``(?<n>a\g<n>){0}`` are not.  The rules are Oniguruma's
  ## to the letter, down to the lengths a check works out for the next.
  ##
  ## A walk that follows calls past ``MaxStackBytes`` raises
  ## ``RegexLimitError``, as a ring of 30,000 groups each calling the next
  ## does.  Oniguruma takes a minute over that one, and overflows its stack on
  ## the same chain left open.  So does a check past
  ## ``MaxRecursionCheckRewalkSteps``, as 9 groups that each call all 9 do,
  ## where Oniguruma goes down every path too, and one past
  ## ``MaxRecursionCheckSteps``, as 5,000 groups that each call one that calls
  ## them all do.
  var c = RecursionCheck(
    ast: ast,
    bodies: bodies,
    namedCaptures: namedCaptures,
    stackBase: currentStackAddr(),
  )
  let slots = bodies.len + 1
  c.called = newSeq[bool](slots)
  c.marked = newSeq[bool](slots)
  c.entered = newSeq[bool](slots)
  c.minLen = newSeq[int8](slots)
  for slot in 0 ..< slots:
    c.minLen[slot] = -1
  c.memo = newSeq[uint8](2 * slots)
  c.memoCheck = newSeq[int](2 * slots)
  c.walked = newSeq[int](2 * slots)
  var pending: seq[int]
  c.markCalled(ast, false, pending)
  while pending.len > 0:
    c.markCalled(c.slotBody(pending.pop()), true, pending)
  c.findComponents(slots)
  if readsGroups:
    var open = newSeq[bool](slots)
    c.markOpenRefs(ast, open)
  # The whole pattern is the outermost group.
  c.checkGroup(0)
  c.checkGroups(ast)

proc holdsAbsent(
    node: Node,
    bodies: seq[Node],
    namedCaptures: seq[(string, int)],
    calledAbsent: seq[int8],
    visited: var HashSet[int],
    pending: var seq[int],
): bool =
  ## Whether ``node`` holds a ``(?~|...)`` form in place, or calls a group
  ## known to, for [containsAbsent].  The groups it calls that are not known
  ## either way go to ``pending``, each once.
  if node == nil:
    return false
  case node.kind
  of nkAbsent:
    if node.absentKind != abFunction:
      return true
  of nkSubexpCall:
    let idx = callTarget(node, bodies, namedCaptures)
    if idx >= 0:
      if calledAbsent[idx] > 0:
        return true
      if calledAbsent[idx] == 0 and idx notin visited:
        visited.incl(idx)
        pending.add idx
    return false
  else:
    discard
  for child in node.childNodes:
    if holdsAbsent(child, bodies, namedCaptures, calledAbsent, visited, pending):
      return true
  false

proc containsAbsent(
    group: int,
    bodies: seq[Node],
    namedCaptures: seq[(string, int)],
    calledAbsent: var seq[int8],
): bool =
  ## Check if the 0-based group ``group`` transitively contains a ``(?~|...)``
  ## form, which [validateLookbehinds] rejects when written in a look-behind
  ## directly.  The absent function ``(?~pattern)`` -- ``(?~)`` included -- is
  ## allowed there, as in Oniguruma, but its pattern is searched like any
  ## other body: ``(?<=\g<1>)((?~(?~|a)))`` is rejected, as it is written in
  ## place.
  ##
  ## ``calledAbsent`` keeps the answers, by group: 0 until known, 1 when it
  ## holds one, -1 when not.  A "no" is kept for every group the search went
  ## through, as each calls only groups it went through too or knew were
  ## clean, so however many look-behinds call into one chain, the chain is
  ## searched once.  A "yes" is
  ## kept only for ``group``: a group the search went through may reach the
  ## form only through ``group``, or not at all.
  ##
  ## Calls are followed to any depth, from a list rather than by recursion, as
  ## a chain of calls is as long as the pattern.  Oniguruma follows only the
  ## first (``check_called_node_in_look_behind`` has no case for a call), so it
  ## compiles ``(?<=\g<1>)(\g<2>)((?~|))``, and the range clear then escapes
  ## the look-behind.  reni rejects that on purpose.
  ##
  ## A call to the whole pattern (``\g<0>``, ``(?R)``) is not followed, here
  ## or in [validateLookbehinds].  Oniguruma follows no recursive call, and a
  ## ``\g<0>`` in a look-behind always is one, so it compiles
  ## ``(?~|a)|(?<=x\g<0>)`` as reni does.  In the shapes checked, a stopper or
  ## a range clear run through it stays inside the look-behind in both
  ## engines, so following it would only reject what Oniguruma accepts.  A
  ## recursive call through a group, ``((?~|a)|(?<=x\g<1>))``, is followed and
  ## rejected, which Oniguruma does not do.
  if calledAbsent[group] != 0:
    return calledAbsent[group] > 0
  var visited = [group].toHashSet
  var pending = @[group]
  while pending.len > 0:
    let body = bodies[pending.pop()]
    if holdsAbsent(body, bodies, namedCaptures, calledAbsent, visited, pending):
      calledAbsent[group] = 1
      return true
  for idx in visited:
    calledAbsent[idx] = -1
  false

proc validateLookbehinds(
    node: Node,
    bodies: seq[Node],
    namedCaptures: seq[(string, int)],
    inPosBehind, inNegBehind: bool,
    calledAbsent: var seq[int8],
) =
  ## Reject what Oniguruma's ``check_node_in_look_behind`` rejects in a
  ## look-behind body: ``\z``, ``\Z`` and look-aheads in any, a negative
  ## look-behind inside a positive one, and a capturing group inside a negative
  ## one.  ``inPosBehind`` and ``inNegBehind`` say whether some look-behind of
  ## that polarity encloses the node.  Oniguruma checks each look-behind's whole
  ## body, nested look-behinds included, under that look-behind's own polarity,
  ## so a node is rejected when any look-behind around it rejects it:
  ## ``(?<!(?<=(?<!a)))`` fails on the positive one in the middle.
  ##
  ## Every ``(?~|...)`` form is rejected as well, in place or through a call.
  ## Oniguruma rejects only the two with side effects, the range clear and the
  ## stopper, and accepts the absent expression ``(?~|a|b)``, which reni does
  ## not run inside a look-behind.
  ##
  ## Runs after unnamed captures are demoted, as Oniguruma's check runs after
  ## ``disable_noname_group_capture``: ``(?<n>a)(?<!(b))`` compiles there.  A
  ## look-around condition counts as a look-around in the body.  Oniguruma
  ## cannot spell ``(?(?=a)...)``, but it rejects ``(?((?=a))...)``, its own
  ## form, in a look-behind.  ``(*FAIL)`` is not a look-ahead there, so it
  ## passes ([lookFail]).
  ##
  ## A called body is checked only for absent operators ([containsAbsent]), as
  ## ``check_called_node_in_look_behind`` does, so ``(?<=\g<1>)(a\z)``
  ## compiles.  ``calledAbsent`` keeps that answer for each group, so a group
  ## called from many look-behinds is searched once.
  ##
  ## The error gives the position where the rejected node starts, as a parser
  ## error does.  For an absent operator reached through a call, that is the
  ## call.
  if node == nil:
    return
  template reject() =
    var msg = "invalid pattern in look-behind"
    let pos = node.patternPos
    if pos > 0:
      msg.add " at position " & $pos
    raise newException(RegexError, msg)

  let inBehind = inPosBehind or inNegBehind
  case node.kind
  of nkAnchor:
    if inBehind and node.anchor in {akStringEnd, akStringEndOrNewline}:
      reject()
    return
  of nkLookaround:
    case node.lookKind
    of lkAhead, lkNegAhead:
      if inBehind and not node.lookFail:
        reject()
    of lkBehind:
      validateLookbehinds(
        node.lookBody, bodies, namedCaptures, true, inNegBehind, calledAbsent
      )
      return
    of lkNegBehind:
      if inPosBehind:
        reject()
      validateLookbehinds(
        node.lookBody, bodies, namedCaptures, inPosBehind, true, calledAbsent
      )
      return
  of nkCapture, nkNamedCapture:
    if inNegBehind:
      reject()
  of nkAbsent:
    if inBehind and node.absentKind != abFunction:
      reject()
  of nkSubexpCall:
    if inBehind:
      let idx = callTarget(node, bodies, namedCaptures)
      if idx >= 0 and containsAbsent(idx, bodies, namedCaptures, calledAbsent):
        reject()
    return
  else:
    discard
  for child in node.childNodes:
    validateLookbehinds(
      child, bodies, namedCaptures, inPosBehind, inNegBehind, calledAbsent
    )

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
      if not namedCaptures.hasGroupName(node.callName):
        raise newException(
          RegexError, "undefined name reference '\\g<" & node.callName & ">'"
        )
    else:
      # callIndex == 0 is the whole-pattern recursion \g<0>, always valid.
      if node.callIndex != 0 and (node.callIndex < 1 or node.callIndex > captureCount):
        raise
          newException(RegexError, "invalid subexp call '\\g<" & $node.callIndex & ">'")
  of nkNamedBackref:
    if not namedCaptures.hasGroupName(node.backrefName):
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
      if not namedCaptures.hasGroupName(node.condRefName):
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
    for child in node.children.view:
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
    for child in node.children.view:
      flattenLiteralGroups(child)
    var spliced: seq[Node]
    var changed = false
    for child in node.children.view:
      var inner: seq[Node]
      if child.kind == nkGroup and collectLiteralNodes(child, inner):
        spliced.add inner
        changed = true
      else:
        spliced.add child
    if changed:
      node.children = spliced
  of nkAlternation:
    for alt in node.alternatives.view:
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
    for child in node.children.view:
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
    for i, alt in node.alternatives.view:
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
      condScope: node.condScope,
      condRefName: node.condRefName,
      condYes: mergeLiterals(node.condYes),
      condNo: mergeLiterals(node.condNo),
      condBody: mergeLiterals(node.condBody),
    )
  of nkAbsent:
    Node(
      kind: nkAbsent,
      absentKind: node.absentKind,
      absentLoopsOnExpr: node.absentLoopsOnExpr,
      absentLoopLo: node.absentLoopLo,
      absentLoopHi: node.absentLoopHi,
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

type EmptyCheckEnv = object ## What [markGroupReads] reads beside the tree.
  spans: GroupSpans ## measures a repeat's body, through the groups it reads
  owner: seq[Node]
    ## By group number: the innermost repeat that may match empty around the
    ## group's definition, or nil.
  opensUnset: seq[bool] ## By group number: read; see ``Regex.opensUnset``.
  status: seq[uint32] ## By body [NodeId]; see ``Regex.emptyStatus``.
  openOrder: bool ## A ``\k<name+0>`` reads a name several groups declare.

proc assignEmptyOwners(node: Node, unclaimed: var seq[int], env: var EmptyCheckEnv) =
  ## Oniguruma's ``set_empty_repeat_node_trav``: give each group the innermost
  ## repeat around it that may match empty.  Bottom up, so inner repeats are
  ## measured first and [repeatBodyMayBeEmpty] reuses their spans.
  ## ``unclaimed`` holds the groups defined so far that no repeat has claimed.
  ## A look-around leaves the groups inside it unowned, as ``ANCR_PREC_READ``
  ## and ``ANCR_LOOK_BEHIND`` do for the positive ones.  Oniguruma owns a
  ## negative one's groups, harmlessly since it keeps none of them; reni's
  ## ``(?(?!X)...)`` keeps X's captures, and two such owned groups could move
  ## each other back and forth forever.  ``X{1}`` claims nothing, as Oniguruma
  ## parses it to ``X``.
  if node == nil:
    return
  let mark = unclaimed.len
  case node.kind
  of nkCapture:
    unclaimed.add(node.captureIndex + 1)
  of nkNamedCapture:
    unclaimed.add(node.namedCaptureIndex + 1)
  else:
    discard
  for child in node.childNodes:
    assignEmptyOwners(child, unclaimed, env)
  case node.kind
  of nkQuantifier:
    if node.quantMax != 0 and not (node.quantMin == 1 and node.quantMax == 1) and
        node.repeatBodyMayBeEmpty(env.spans):
      for i in mark ..< unclaimed.len:
        if unclaimed[i] < env.owner.len:
          env.owner[unclaimed[i]] = node
      unclaimed.setLen(mark)
  of nkLookaround:
    unclaimed.setLen(mark)
  else:
    discard

proc noteGroupRead(group: int, visible: seq[Node], floor: int, env: var EmptyCheckEnv) =
  ## A backreference or condition at a place where ``visible[floor ..^ 1]`` are
  ## the repeats Oniguruma sees it inside reads ``group``.
  if group <= 0 or group >= env.owner.len:
    return
  env.opensUnset[group] = true
  let q = env.owner[group]
  if q == nil or group >= 32:
    return
  for i in floor ..< visible.len:
    if visible[i] == q:
      return
  let body = q.quantBody.id.int
  env.status[body] = env.status[body] or (1'u32 shl group)

proc scanGroupReads(
    node: Node, r: Regex, visible: var seq[Node], floor: int, env: var EmptyCheckEnv
) =
  ## Oniguruma's ``set_empty_status_check_trav``: a read of a group counts for
  ## the group's owner unless the read is inside that repeat, and "inside" is
  ## decided as ``is_ancestor_node`` decides it -- by parent pointers, of which
  ## ``set_parent_node_trav`` sets only one per list or alternation: from its
  ## first element.  Every later element's chain ends at its own cell.  So a
  ## read counts as inside exactly when every list and alternation between it
  ## and the repeat is entered at its first element: ``(?:\1a|())*`` reads
  ## group 1 inside, ``(?:a\1|())*`` from outside.  ``visible[floor ..^ 1]``
  ## are the repeats ``node`` is inside in that sense.  A name reads the
  ## groups ``r`` resolved it to.
  if node == nil:
    return
  case node.kind
  of nkConcat:
    # An isolated ``(?i)`` needs nothing of its own: the parser already wraps
    # the rest of the group in it, as Oniguruma's option node does.
    for i, child in node.children.view:
      scanGroupReads(child, r, visible, if i == 0: floor else: visible.len, env)
  of nkAlternation:
    for i, alt in node.alternatives.view:
      scanGroupReads(alt, r, visible, if i == 0: floor else: visible.len, env)
  of nkQuantifier:
    visible.add(node)
    scanGroupReads(node.quantBody, r, visible, floor, env)
    discard visible.pop()
  of nkBackreference:
    noteGroupRead(node.backrefIndex, visible, floor, env)
  of nkNamedBackref:
    var groups = 0
    for i in r.nameRefsOf(node.backrefRefs):
      noteGroupRead(int(i) + 1, visible, floor, env)
      inc groups
    # The stamps ride on the read marked just above: [clearOnOpen] stamps
    # exactly the groups ``opensUnset`` names.
    if groups > 1 and node.namedBackrefLeveled and node.namedBackrefLevel == 0:
      env.openOrder = true
  else:
    if node.kind == nkConditional:
      case node.condKind
      of ckBackref:
        noteGroupRead(node.condRefIndex, visible, floor, env)
      of ckNamedRef:
        for i in r.nameRefsOf(node.condRefs):
          noteGroupRead(int(i) + 1, visible, floor, env)
      else:
        discard
    for child in node.childNodes:
      scanGroupReads(child, r, visible, floor, env)

proc markGroupReads(
    r: var Regex, namedCaptures: seq[(string, int)], captureCount: int
) =
  ## Fill ``Regex.emptyStatus``, ``Regex.opensUnset`` and ``Regex.openedLast``
  ## from the references and conditionals that read groups.  Runs on the
  ## numbered final tree, so a repeat's body is measured once and a name
  ## reads the groups ``resolveNameRefs`` gave it.
  var env = EmptyCheckEnv(
    spans: initGroupSpans(r.ast, namedCaptures, r.nodes.len),
    owner: newSeq[Node](captureCount + 1),
    opensUnset: newSeq[bool](captureCount + 1),
    status: newSeq[uint32](r.nodes.len),
  )
  var unclaimed: seq[int]
  assignEmptyOwners(r.ast, unclaimed, env)
  var visible: seq[Node]
  scanGroupReads(r.ast, r, visible, 0, env)
  # The matcher's pure fast paths skip the empty check (``quantSnapshot``);
  # a body that writes nothing defines no group, so it never owns one.
  for node in r.nodes:
    if node != nil and node.kind == nkQuantifier and node.quantBodyPure and
        node.quantBody != nil:
      let id = node.quantBody.id.int
      doAssert id <= 0 or id >= env.status.len or env.status[id] == 0,
        "pure repeat body with an empty-check set"
    # Without ``openOrder`` the matcher reads a level-0 name's first group
    # alone (``leveledBackrefEnd``), so the walk has to have seen each one.
    if node != nil and node.kind == nkNamedBackref and node.namedBackrefLeveled and
        node.namedBackrefLevel == 0:
      doAssert env.openOrder or r.nameRefCount(node.backrefRefs) <= 1,
        "a level-0 read of several groups without openOrder"
  var watched = false
  for groups in env.status:
    if groups != 0:
      watched = true
      break
  if watched:
    r.setEmptyStatus(move env.status)
  if env.openOrder:
    # Every group [clearOnOpen] stamps, from the first to the last.
    let first = env.opensUnset.find(true)
    var last = first
    for group in first + 1 .. captureCount:
      if env.opensUnset[group]:
        last = group
    r.setOpenedGroups(first .. last)
  if true in env.opensUnset:
    r.setOpensUnset(move env.opensUnset)

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
    for i, alt in node.alternatives.view:
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
    for child in node.children.view:
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
    for child in node.children.view:
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
    for child in node.children.view:
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
    for child in node.children.view:
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
    for alt in node.alternatives.view:
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
    for child in node.children.view:
      if not consumable(child, flags, s):
        return false
    true
  of nkAlternation:
    for alt in node.alternatives.view:
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
    for child in node.children.view:
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

proc foldedLeadBytes(cp: int32): set[uint8] =
  ## The lead byte of every subject character that can stand where the ASCII
  ## ``cp`` stands under ``(?i)``: its simple-fold variants (``ſ`` for ``s``,
  ## ``K`` for ``k``), and every character whose multi-character fold holds
  ## it (``ß`` for ``s``, ``ﬁ`` for ``i``), which [stringAdvance] matches
  ## against a run of pattern characters at once.  Taken from the tables the
  ## matcher reads, so it cannot drift from them.
  var buf: array[4, char]
  for v in caseFoldVariants(Rune(cp)):
    discard utf8Encode(int32(v), buf)
    result.incl uint8(buf[0])
  result.incl uint8(cp)
  for f in MultiCharFolds:
    for j in 0 ..< f.len:
      if caseInsensitiveMatch(Rune(f.expansion[j]), Rune(cp), {rfIgnoreCase}):
        discard utf8Encode(f.source, buf)
        result.incl uint8(buf[0])

const FoldedLeadBytes = block:
  ## [foldedLeadBytes] for every ASCII character, worked out once.
  var t: array[128, set[uint8]]
  for c in 0 .. 127:
    t[c] = foldedLeadBytes(int32(c))
  t

const ByteWeight = block:
  ## Rough frequency of each byte in source text, for choosing what is
  ## least likely to be present.  Only the order matters.
  var t: array[256, int]
  for b in 0 .. 255:
    t[b] = 1
  t[ord(' ')] = 30
  for c in "etaoinsrl":
    t[ord(c)] = 12
  for c in "cdumphfgywb_":
    t[ord(c)] = 6
  for c in "vkxjqz0123456789\t":
    t[ord(c)] = 3
  for c in "ETAOINSRLCDUMPHFGYWB":
    t[ord(c)] = 3
  t

const ByteWeights = block:
  ## The weights ``ByteWeight`` gives, lightest first.
  var weights: seq[int]
  for w in ByteWeight:
    if w notin weights:
      weights.add w
  weights.sort()
  weights

const WeightSteps = block:
  ## ``ByteWeight`` as steps: each weight a byte has, how far it stands above
  ## the next lighter one, and the bytes that weigh at least that much.  A
  ## set weighs the sum over the steps of the step times how many of its
  ## bytes the step holds.
  var steps: array[ByteWeights.len, tuple[step: int, bytes: set[uint8]]]
  var below = 0
  for i, w in ByteWeights:
    for b in 0 .. 255:
      if ByteWeight[b] >= w:
        steps[i].bytes.incl uint8(b)
    steps[i].step = w - below
    below = w
  steps

func popCount(x: uint64): int {.inline.} =
  ## The builtin is a libgcc call without ``-mpopcnt``.
  var v = x - ((x shr 1) and 0x5555555555555555'u64)
  v = (v and 0x3333333333333333'u64) + ((v shr 2) and 0x3333333333333333'u64)
  v = (v + (v shr 4)) and 0x0F0F0F0F0F0F0F0F'u64
  int((v * 0x0101010101010101'u64) shr 56)

proc setWeight(bs: set[uint8]): int =
  ## The sum of ``ByteWeight`` over ``bs``, a word at a time: the walk weighs
  ## every class and every join, and a set read member by member tests all
  ## 256 bytes.
  when nimvm:
    for b in bs:
      result += ByteWeight[b]
  else:
    let words = cast[array[4, uint64]](bs)
    for s in WeightSteps:
      let held = cast[array[4, uint64]](s.bytes)
      var n = 0
      for i in 0 .. 3:
        n += popCount(words[i] and held[i])
      result += s.step * n

const FoldedWeight = block:
  ## [setWeight] of each [FoldedLeadBytes] entry.
  var t: array[128, int]
  for c in 0 .. 127:
    t[c] = setWeight(FoldedLeadBytes[c])
  t

func folds(flags: RegexFlags): bool {.inline.} =
  (flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card != 0

type
  ReqSet = object
    ## The least likely byte set some node requires, for an alternation
    ## branch.  Any one required byte will do, so no run is kept.
    weight: int ## -1 while nothing is required.
    bs: set[uint8]

  ReqWalk = object
    ## [requiredLiteral]'s walk, which keeps the best string and set as it
    ## goes.  ``run`` holds the bytes read since the last node that was not a
    ## literal: the subject holds them back to back.
    run: string
    runAtStart: bool
    atStart: bool ## Nothing a match must consume has been passed yet.
    skipStart: bool
      ## Leave out what begins at the match start: the first-byte scan
      ## already looks for it.
    skipByte: int ## The byte ``requiredByte`` tests, or -1.
    str: string ## Longest required string of two or more bytes.
    set: ReqSet

proc offer(s: var ReqSet, bs: set[uint8], weight: int) =
  if s.weight < 0 or weight < s.weight:
    s.weight = weight
    s.bs = bs

proc offerSet(w: var ReqWalk, bs: set[uint8], weight: int, atStart: bool) =
  if atStart and w.skipStart:
    return
  if w.skipByte >= 0 and bs == {uint8(w.skipByte)}:
    return
  w.set.offer(bs, weight)

proc flushRun(w: var ReqWalk) =
  if w.run.len == 0:
    return
  if w.run.len == 1:
    let b = uint8(w.run[0])
    w.offerSet({b}, ByteWeight[b], w.runAtStart)
  elif not (w.runAtStart and w.skipStart) and w.run.len > w.str.len:
    w.str = w.run
  w.run.setLen(0)

proc reqBreak(w: var ReqWalk) =
  ## A node that may consume, but whose bytes are not known: what follows is
  ## neither next to the run nor at the match start.
  w.flushRun()
  w.atStart = false

proc reqRune(w: var ReqWalk, cp: int32, flags: RegexFlags) =
  ## A literal character the match consumes here.
  if w.run.len == 0:
    w.runAtStart = w.atStart
  if not flags.folds:
    # Compared byte for byte ([matchBytes]).
    var buf: array[4, char]
    let n = utf8Encode(cp, buf)
    for i in 0 ..< n:
      w.run.add buf[i]
  elif cp >= 0x80:
    # A fold reaches other encodings; nothing is stated.
    w.reqBreak()
    return
  elif FoldedLeadBytes[cp] == {uint8(cp)}:
    # No other character folds to it: still its own byte, next to the run.
    w.run.add char(cp)
  else:
    w.flushRun()
    w.offerSet(FoldedLeadBytes[cp], FoldedWeight[cp], w.atStart)
  w.atStart = false

proc reqClassBytes(node: Node, flags: RegexFlags): set[uint8] =
  ## [leafLeadBytes], less the set of every byte, which no subject lacks.
  result = leafLeadBytes(node, flags)
  if result == {0'u8 .. 255'u8}:
    result = {}

type ReqPair = object
  ## [reqBest]'s answer twice: ``plain`` from the literals alone, ``wide``
  ## counting classes and types too, and never likelier.  A class can be a
  ## branch's least likely set and still join into a likelier one:
  ## ``[uU]r|[bB]r|r`` joins ``{u, U, b, B, r}`` where the literals give
  ## ``{r}``.  So an alternation joins both, and ``wide`` keeps the lighter.
  plain, wide: ReqSet

const NoReqPair = ReqPair(plain: ReqSet(weight: -1), wide: ReqSet(weight: -1))

proc offer(p: var ReqPair, bs: set[uint8], weight: int) =
  p.plain.offer(bs, weight)
  p.wide.offer(bs, weight)

proc offerByte(p: var ReqPair, cp: int32, flags: RegexFlags) =
  ## A literal character's lead byte, or under folding what may stand for it.
  if not flags.folds:
    var buf: array[4, char]
    discard utf8Encode(cp, buf)
    let b = uint8(buf[0])
    p.offer({b}, ByteWeight[b])
  elif cp < 0x80:
    p.offer(FoldedLeadBytes[cp], FoldedWeight[cp])

proc reqUnion(node: Node, flags: RegexFlags): ReqPair

proc reqBest(p: var ReqPair, node: Node, flags: RegexFlags) =
  ## The least likely byte set ``node`` requires, into ``p``.
  if node == nil:
    return
  case node.kind
  of nkLiteral:
    p.offerByte(int32(node.rune), flags)
  of nkEscapedLiteral:
    p.offerByte(int32(node.escapedRune), flags)
  of nkString:
    for r in node.runes:
      p.offerByte(int32(r), flags)
  of nkConcat:
    var cur = flags
    for child in node.children.view:
      if child.kind == nkFlagGroup and child.flagBody == nil:
        cur = cur + child.flagsOn - child.flagsOff
      else:
        p.reqBest(child, cur)
  of nkCapture:
    p.reqBest(node.captureBody, flags)
  of nkNamedCapture:
    p.reqBest(node.namedCaptureBody, flags)
  of nkGroup:
    p.reqBest(node.groupBody, flags)
  of nkAtomicGroup:
    p.reqBest(node.atomicBody, flags)
  of nkFlagGroup:
    if node.flagBody != nil:
      p.reqBest(node.flagBody, flags + node.flagsOn - node.flagsOff)
  of nkLookaround:
    if node.lookKind == lkAhead:
      p.reqBest(node.lookBody, flags)
  of nkQuantifier:
    if node.quantMin >= 1:
      p.reqBest(node.quantBody, flags)
  of nkAlternation:
    let u = reqUnion(node, flags)
    if u.plain.weight >= 0:
      p.plain.offer(u.plain.bs, u.plain.weight)
    if u.wide.weight >= 0:
      p.wide.offer(u.wide.bs, u.wide.weight)
  of nkCharClass, nkCharType:
    let bs = reqClassBytes(node, flags)
    if bs != {}:
      p.wide.offer(bs, setWeight(bs))
  else:
    discard

proc reqUnion(node: Node, flags: RegexFlags): ReqPair =
  ## One least likely set from each branch of the alternation ``node``,
  ## joined, as [ReqPair] keeps them; ``weight`` -1 where some branch
  ## requires nothing.
  result = NoReqPair
  if node.alternatives.len == 0:
    return
  var plain, wide: set[uint8]
  var plainHeld = true
  for alt in node.alternatives.view:
    var b = NoReqPair
    b.reqBest(alt, flags)
    if b.wide.weight < 0:
      # Nor does ``plain``, which takes no offer ``wide`` does not.
      return
    wide = wide + b.wide.bs
    if b.plain.weight < 0:
      plainHeld = false
    else:
      plain = plain + b.plain.bs
  result.wide = ReqSet(weight: setWeight(wide), bs: wide)
  if plainHeld:
    result.plain = ReqSet(weight: setWeight(plain), bs: plain)
    if result.plain.weight < result.wide.weight:
      result.wide = result.plain

proc reqWalk(w: var ReqWalk, node: Node, flags: RegexFlags) =
  if node == nil:
    return
  case node.kind
  of nkLiteral:
    w.reqRune(int32(node.rune), flags)
  of nkEscapedLiteral:
    w.reqRune(int32(node.escapedRune), flags)
  of nkString:
    if not flags.folds:
      # [stringAdvance] compares ``bytes``.
      if w.run.len == 0:
        w.runAtStart = w.atStart
      w.run.add node.bytes
      w.atStart = false
    else:
      for r in node.runes:
        w.reqRune(int32(r), flags)
  of nkConcat:
    var cur = flags
    for child in node.children.view:
      if child.kind == nkFlagGroup and child.flagBody == nil:
        cur = cur + child.flagsOn - child.flagsOff
      else:
        w.reqWalk(child, cur)
  of nkCapture:
    w.reqWalk(node.captureBody, flags)
  of nkNamedCapture:
    w.reqWalk(node.namedCaptureBody, flags)
  of nkGroup:
    w.reqWalk(node.groupBody, flags)
  of nkAtomicGroup:
    w.reqWalk(node.atomicBody, flags)
  of nkFlagGroup:
    if node.flagBody != nil:
      w.reqWalk(node.flagBody, flags + node.flagsOn - node.flagsOff)
  of nkAnchor, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    discard # Zero-width: the run goes on past it.
  of nkLookaround:
    # Zero-width too.  A look-ahead reads from where the match stands, so
    # its body goes on from the run, but the match goes on from before it.
    # A look-behind reads before the search start, and a negative form
    # needs nothing.
    if node.lookKind == lkAhead:
      # ``var``, so a copy: under refc a ``let`` shares the buffer the body
      # goes on to append to.
      var run = w.run
      let runAtStart = w.runAtStart
      let atStart = w.atStart
      w.reqWalk(node.lookBody, flags)
      w.flushRun()
      w.run = run
      w.runAtStart = runAtStart
      w.atStart = atStart
  of nkQuantifier:
    # The first iteration is mandatory and follows the run; what comes after
    # it is neither.
    if node.quantMin >= 1:
      w.reqWalk(node.quantBody, flags)
    w.reqBreak()
  of nkAlternation:
    # Every branch requires something, or nothing is stated: then one byte
    # set from each, joined.
    w.flushRun()
    let u = reqUnion(node, flags).wide
    if u.weight >= 0:
      w.offerSet(u.bs, u.weight, false)
    w.reqBreak()
  of nkCharClass, nkCharType:
    # One character whose bytes are not known, only those it begins with:
    # a set, as for an alternation.  ``[a-zA-Z_]`` turns away a line of
    # ``/****/``, which Oniguruma's map refuses too.
    w.flushRun()
    # [offerSet] would leave it to the scan too; testing first saves the
    # weighing.
    if not (w.atStart and w.skipStart):
      let bs = reqClassBytes(node, flags)
      if bs != {}:
        w.offerSet(bs, setWeight(bs), w.atStart)
    w.reqBreak()
  else:
    # References, calls, conditions and absent operators state no byte here.
    w.reqBreak()

proc requiredLiteral(
    ast: Node,
    flags: RegexFlags,
    fc: FirstCharInfo,
    rb: RequiredByteInfo,
    leadAnchors: set[AnchorKind],
    semiEnd: bool,
): RequiredLiteral =
  ## What every match holds at or after the search start, for the search to
  ## test before it tries a position: the longest byte string, or else the
  ## byte set least likely to occur.  What opens every match is left out
  ## while ``fc`` scans for its first byte anyway, and so is the byte ``rb``
  ## already tests.  Nothing is taken where ``\A``, ``\G`` or ``\Z`` leaves
  ## one start to try: reading the subject for it would cost more than the
  ## attempt it might save.
  if fc.kind == fcAnchorStart or akSearchBegin in leadAnchors or semiEnd:
    return
  var w = ReqWalk(
    atStart: true,
    skipStart: fc.kind in {fcByte, fcByteSet},
    skipByte:
      if rb.valid:
        int(rb.byte)
      else:
        -1,
    set: ReqSet(weight: -1),
  )
  w.reqWalk(ast, flags)
  w.flushRun()
  if w.str.len > 0:
    result.kind = rlString
    result.str = w.str
    for i in 1 ..< w.str.len:
      if ByteWeight[uint8(w.str[i])] < ByteWeight[uint8(w.str[result.at])]:
        result.at = i
  elif w.set.weight >= 0:
    # A set no less likely than the first-byte scan's own only reads the
    # subject a second time.
    if w.skipStart:
      let scan =
        if fc.kind == fcByte:
          {fc.byte}
        else:
          fc.bytes
      if w.set.weight >= setWeight(scan):
        return
    if w.set.bs.card == 1:
      # A string of one, which the search hands to ``memchr``.
      result.kind = rlString
      for b in w.set.bs:
        result.str = $char(b)
    else:
      result.kind = rlSet
      result.set = w.set.bs

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
    for child in node.children.view:
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
    for child in node.children.view:
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

proc quantTypeNum(node: Node): int {.inline.} =
  ## [quantTypeNum] of a repeat node.  Possessives answer -1 and never reach
  ## [ReduceTable] anyway: [reduceNestedQuantifier] turns them away first,
  ## since Oniguruma spells one as ``(?>...)`` around a greedy repeat and so
  ## never has a possessive repeat node to put in a row.
  if node.quantKind == qkPossessive:
    -1
  else:
    quantTypeNum(node.quantMin, node.quantMax, node.quantKind == qkGreedy)

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
  ## [tuneLookBehinds] pins a leading repeat over a *simple* atom only
  ## -- see ``isSimpleRepeatBody`` -- so it can only reduce ``(?:a*)*\b`` to
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
  if node.kind == nkAbsent and node.absentLoopsOnExpr:
    # Oniguruma builds an expression that is the loop around the absent
    # pattern from its one character and bounds, and never writes it out:
    # ``a{3}`` stays three steps of ``a``, each a start for the absent
    # pattern, not one ``aaa`` the matcher cannot step through
    # (``findExprAbsentPos``).
    tuneRepeats(node.absentBody, expand)
    tuneRepeats(node.absentExpr, false)
    return
  for child in node.childNodes:
    tuneRepeats(child, expand)
  if node.kind == nkQuantifier:
    reduceNestedQuantifier(node)
    if expand:
      expandStringRepeat(node)

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
    for alt in node.alternatives.view:
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
    for child in node.children.view:
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
  ## Compile a reusable pattern. With ``rfCaptureGroup``, ordinary groups keep
  ## their numbers even when named groups exist, and numbered references stay
  ## available. This corresponds to Oniguruma's ``ONIG_OPTION_CAPTURE_GROUP``;
  ## without it, named groups retain Oniguruma's default capture behavior.
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
  # Bare-name conditions, now that every group name is known.  One that
  # becomes a reference reads its group.
  if p.sawBareNameCondition and namedCaptures.len > 0:
    if resolveBareNameConditions(ast, namedCaptures):
      p.sawGroupRead = true
  # A bare name with no branch has to have been a reference (``(?(n))``).
  for (name, at) in p.branchlessNames:
    if not namedCaptures.hasGroupName(name):
      raise newException(RegexError, "invalid if-else syntax at position " & $at)
  # When named captures exist, demote unnamed captures to non-capturing groups
  # (Oniguruma default behavior: unnamed groups don't capture when named groups present)
  if namedCaptures.len > 0 and rfCaptureGroup notin flags:
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
  # Validate that every numeric / named reference points to an existing group.
  validateNumericRefs(ast, captureCount, namedCaptures)
  # After the reference checks, which Oniguruma makes first too.
  if p.sawCall:
    checkNeverEndingRecursion(ast, bodies, namedCaptures, p.sawGroupRead)
  # What a look-behind body may hold, and absent operators reached through
  # calls.  After the reference checks, as Oniguruma reports those while
  # parsing and this one while tuning: ``(?<!(a))\5`` is a bad reference there.
  var calledAbsent = newSeq[int8](bodies.len)
  validateLookbehinds(ast, bodies, namedCaptures, false, false, calledAbsent)
  # Merge consecutive literals into nkString nodes
  ast = mergeLiterals(ast)
  # Must run before any analysis that reads a quantifier's bounds or kind.
  normaliseInvertedRanges(ast)
  # Collapse a repeat over a repeat and write out an exact repeat of a
  # literal, as Oniguruma does while parsing and in ``tune_quant``.  Must run
  # before the look-behind reduction, which only sees a leading repeat over a
  # simple atom and so needs both shapes settled first.
  tuneRepeats(ast, expand = not foldsAnywhere(ast, flags))
  # Pin a look-behind body's leading repeats to their lower bound, and drop or
  # divide the look-behinds Oniguruma does.  Runs before every pass that reads
  # bounds; a reduced body may become fixed-length.
  tuneLookBehinds(ast, namedCaptures, flags)
  # Must run on the final AST: ``mergeLiterals`` rebuilds nodes and would drop
  # the annotation.  Nodes default to ``quantBodyPure == false``, so a rewrite
  # added after this line stays safe (it just always snapshots).
  discard markQuantBodyPure(ast)
  # Same rule: a node this pass never reaches keeps the flag save.
  discard markGroupBodyKeepsFlags(ast)
  # Same rule, and before ``annotateLookaroundBounds``: ``lengthBounds``
  # reads the flag.  A node this pass never reaches just scans.  Skipped when
  # the pattern has no ``(?~...)`` at all.
  if p.sawAbsent:
    markAbsents(ast)
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
  let firstChar = extractFirstChar(ast, finalFlags)
  let requiredByte =
    requiredByteRegion(ast, finalFlags, extractRequiredByte(ast, finalFlags))
  let leadAnchors = leadAnchorSet(ast, finalFlags)
  let semiEnd = semiEndAnchored(ast)
  result = initRegex(
    pattern = pattern,
    ast = ast,
    flags = finalFlags,
    captureCount = captureCount,
    namedCaptures = namedCaptures,
    groupBodies = bodies,
    groupFlags = groupFlags,
    firstCharInfo = firstChar,
    literalScan = hasLiteralPrefix(ast, finalFlags),
    requiredByte = requiredByte,
    requiredLit =
      requiredLiteral(ast, finalFlags, firstChar, requiredByte, leadAnchors, semiEnd),
    semiEndAnchored = semiEnd,
    # [anchorDMax] parts from [maxByteLen] only over an absent operator.
    semiEndDMax =
      if p.sawAbsent:
        anchorDMax(ast, finalFlags)
      else:
        maxByteLen(ast, finalFlags),
    levelBackrefs = levelBackrefs,
    leadRun =
      if rfFindLongest in finalFlags:
        # findLongest fails every start on purpose, so no skip applies.
        nil
      else:
        let q = leadSimpleRepeat(ast, finalFlags)
        if q != nil and leadRunSkipSafe(ast): q else: nil,
    leadLeaf = leadLeaf,
    leadAnchors = leadAnchors,
    leadRepeat = leadRepeat,
    leadBehind = leadBehindLiteral(ast, finalFlags),
  )
  # After the constructor, which numbers the tree the table indexes.  Derived
  # under ``result.flags`` rather than ``finalFlags`` because the runtime
  # validity check is against the flags the ``Regex`` carries.
  result.setLeafGates(buildLeafGates(result.nodes, result.flags))
  # Same numbering; from ``result.flags`` for the same reason, since the
  # matcher's flags start there and move through the flag groups.
  result.setClassFolds(buildClassFolds(result.ast, result.nodes, result.flags))
  # Same numbering, same flags: an element names its leaf by ``NodeId``.
  buildSeqRuns(result.nodes, result.flags)
  # Same numbering: a repeat's frame names its body by ``NodeId``.  Oniguruma
  # skips it too when nothing reads a group.
  if p.sawGroupRead and captureCount > 0:
    result.markGroupReads(namedCaptures, captureCount)
