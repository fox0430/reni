## Backtracking regex matching engine.
## Uses an explicit frame stack on ``MatchContext`` for continuation
## passing, giving correct backtracking through alternations,
## quantifiers, and flag groups without per-call closure allocations.

import std/[unicode, tables]

import types, unicode_utils

type
  ContId = int32
    ## Index into ``MatchContext.frames`` identifying a continuation.
    ## ``TrueCont`` (-1) is the sentinel for "no further work, succeed".

  ContKind = enum
    ## Continuation kinds.  Each kind encodes a specific post-match
    ## action that closures used to perform via captured locals.
    ckSeqContinue ## After a child node, resume the next sibling.
    ckCapture ## After capture body, write capture span and chain.
    ckGroup ## After group body, restore flags before chaining.
    ckFlagGroup ## After flag group body, restore flags / grapheme mode.
    ckQuantGreedyMore ## Greedy quantifier: try one more rep, then fall back.
    ckQuantLazyMore ## Lazy quantifier: try one more rep, then fall back.
    ckRestoreSubjectEnd ## Absent abRange/abExpression: restore subjectEnd.
    ckEndCheckPos ## Lookbehind: succeed iff ctx.pos == targetPos.
    ckNonZeroPos ## Absent abFunction: succeed iff ctx.pos > startPos.
    ckCapturesChanged ## Quantifier zero-width subloop: succeed iff captures differ.
    ckFindLongestRec ## findLongest top level: record longest, return false.

  Frame = object
    ## A single continuation frame.  Frames live in a flat ``seq`` on
    ## the ``MatchContext`` and are reused across calls; their
    ## ``parent`` field implements the continuation chain.
    parent: ContId
    case kind: ContKind
    of ckSeqContinue:
      sNode: Node ## parent nkConcat node (children walked by idx)
      sIdx: int32 ## next child index to match
    of ckCapture:
      cCapIdx: int32
      cIndex: int32
      cMyDepth: int32
      cStartPos: int
      cSavedFlags: RegexFlags
    of ckGroup:
      grpSavedFlags: RegexFlags
    of ckFlagGroup:
      fgSavedFlags: RegexFlags
      fgSavedGM: GraphemeMode
    of ckQuantGreedyMore, ckQuantLazyMore:
      qBody: Node
      qMinRep: int32
      qMaxRep: int32
      qCount: int32
      qSavedPos: int
    of ckRestoreSubjectEnd:
      reSavedEnd: int
      reAbsentPos: int
    of ckEndCheckPos:
      ecpTargetPos: int
    of ckNonZeroPos:
      nzpStartPos: int
    of ckCapturesChanged:
      ccSnapshotStart: int32
        ## Start offset of this frame's snapshot in ``ctx.captureSnapshots``.
        ## A flat int32 keeps ``seq[Span]`` out of the variant, which would
        ## inflate every Frame.
    of ckFindLongestRec:
      flStartPos: int

  Subject = object
    ## Non-owning view of the subject string: starting a search must not
    ## copy it, or a findAll loop turns quadratic.  Borrows the caller's
    ## buffer and is only valid for one matcher entry point call.
    data: ptr UncheckedArray[char]
    size: int

  MatchContext* {.acyclic.} = ref object
    ## Caller-owned scratch buffer for the matcher.  Fields are
    ## engine-private; allocate via ``newMatchContext`` and pass the result
    ## to ``searchIntoCtx`` etc.  Reusing one context across searches keeps
    ## the internal seqs' capacity (they are only ``setLen``-resized).
    ##
    ## **Not thread-safe.** One ``MatchContext`` per thread.
    ##
    ## ``{.acyclic.}``: nothing reachable from a context links back to it.
    subject: Subject
    pos: int
    flags: RegexFlags
    captures: seq[Span]
    searchStart: int
    keepStart: int
    regex: Regex
    subjectEnd: int ## effective end of subject (for absent expression limiting)
    recursionDepth: int ## for detecting never-ending recursion
    captureStacks: seq[seq[Span]]
      ## per-group capture history for recursion-level backrefs
    groupRecursionDepth: seq[int] ## per-group recursion depth counter
    steps: int ## match step counter for ReDoS protection
    graphemeMode: GraphemeMode ## current grapheme mode from (?y{g}) or (?y{w})
    stepLimit: int ## max steps allowed (``int.high`` = unlimited)
    maxRecursionDepth: int ## max subexpression recursion depth
    calloutCounters: Table[string, int] ## (*COUNT) / (*MAX) tag counters
    callDepth: int ## matchWithCont recursion depth for stack overflow protection
    captureStacksDirty: bool
      ## true when at least one ``captureStacks[i]`` is non-empty, letting
      ## ``resetForPosition`` skip the per-group ``setLen(0)`` loop in the
      ## common case.
    frames: seq[Frame]
      ## Continuation frame stack.  Reused across calls; only
      ## ``setLen`` is used so the underlying capacity persists.
    captureSnapshots: seq[Span]
      ## Side stack of ``ctx.captures`` snapshots for ``ckCapturesChanged``,
      ## pushed and popped LIFO with ``frames``.
    capSaves: seq[Span]
      ## Side stack of capture vectors for live ``SavedState`` snapshots.
      ## Below the high-water mark a snapshot is a plain ``copyMem`` into
      ## capacity that is already there.
    capSavesPeak: int ## High-water mark of ``capSaves`` for the current search.
    capSavesHigh: int ## Highest peak seen since the buffer was last released.
    capSavesQuiet: int ## Consecutive searches whose peak stayed within ``CapSavesKeep``.
    flBestLen: int ## findLongest: best match length so far (-1 if none)
    flBestMatch: Match ## findLongest: deepest match recorded

  ScalarState = object
    ## Everything in a rollback snapshot except the capture vector.  A body
    ## that cannot write captures rolls back with one of these alone; the
    ## separate type keeps it out of the procs that release a side-stack slot.
    pos: int
    flags: RegexFlags
    keepStart: int
    subjectEnd: int
    graphemeMode: GraphemeMode

  SavedState = object
    ## Rollback snapshot.  ``capOff`` is the capture vector's offset on
    ## ``MatchContext.capSaves``, so taking one is a bulk copy rather than an
    ## allocation.  Strictly LIFO: every ``save`` must release its slot before
    ## returning, via ``restore``, ``restoreKeepingCaptures`` or ``drop``
    ## (``rewind`` rolls back without releasing, to replay the snapshot).
    scalars: ScalarState
    capOff: int32

var emptySubjectByte: char
  ## Target for the ``data`` pointer of an empty subject, so a ``Subject``
  ## view never holds a nil pointer.

proc toSubject(s: string): Subject {.inline.} =
  ## Borrow ``s``'s buffer.  The result must not outlive ``s``.
  if s.len > 0:
    Subject(data: cast[ptr UncheckedArray[char]](unsafeAddr s[0]), size: s.len)
  else:
    Subject(data: cast[ptr UncheckedArray[char]](addr emptySubjectByte), size: 0)

template len(s: Subject): int =
  s.size

template `[]`(s: Subject, i: int): char =
  s.data[i]

template oa(s: Subject): untyped =
  ## The view as an ``openArray[char]``, for the Unicode helpers.
  toOpenArray(s.data, 0, s.size - 1)

proc decodeChar(
    ctx: MatchContext, p: int, code: var int32, next: var int
): bool {.inline.} =
  ## Decode the character at ``p`` within the active subject bounds.
  ## False when the lead byte declares more bytes than are left, which is not
  ## a character at all: nothing consumes it.
  decodeAt(toOpenArray(ctx.subject.data, 0, ctx.subjectEnd - 1), p, code, next)

proc nextScanPos(s: string, p: int): int {.inline.} =
  ## The next position after ``p`` at which the scan loops start a match
  ## attempt.  Takes a plain string: the scans run before a ``MatchContext``
  ## view of the subject exists.
  ##
  ## One character on, with the length read out of the lead byte, clamped to
  ## the end of the subject.  A sequence truncated by the end declares more
  ## bytes than are there; stepping past ``s.len`` would skip the end
  ## position, which is a start position like any other — ``\z``, ``$`` and
  ## ``\b`` match there, and the backward scan starts from it.
  min(p + encLen(s[p].uint8), s.len)

proc leftAdjustCharHead(s: string, p: int): int {.inline.} =
  ## Oniguruma's ``utf8_left_adjust_char_head``: walk back to the nearest byte
  ## that is not a continuation byte.  This is a different rule from the
  ## ``encLen`` chain ``nextScanPos`` follows, and on malformed input the two
  ## disagree — as they do in Oniguruma, which steps forward with one and
  ## back with the other.  Everything that walks *back* to a start position
  ## goes through here: the backward scan and the semi-end anchor jump.
  var q = p
  while q > 0 and (s[q].uint8 and 0xC0'u8) == 0x80'u8:
    dec q
  q

proc prevCharHead(s: string, p: int): int {.inline.} =
  ## Oniguruma's ``ONIGENC_STEP_BACK(.., 1)``: the head of the character
  ## before ``p``.  The backward scan's step, and the position the semi-end
  ## anchor jump measures from.
  if p <= 0:
    0
  else:
    leftAdjustCharHead(s, p - 1)

proc rightAdjustCharHead(s: string, p: int): int {.inline.} =
  ## Oniguruma's ``onigenc_get_right_adjust_char_head``: left-adjust, and when
  ## that moved, step one character forward again.  ``p`` must be inside ``s``.
  ##
  ## The forward step is clamped to ``s.len``: a lead byte can declare more
  ## bytes than the subject holds, and a start position past the end would
  ## leave the scan loop with nothing to try.
  let q = leftAdjustCharHead(s, p)
  if q < p:
    min(q + encLen(s[q].uint8), s.len)
  else:
    p

proc advanceChainTo(s: string, start, target: int, byteScan: bool): int {.inline.} =
  ## The first scan position at or after ``target`` that a forward scan from
  ## ``start`` actually visits.
  ##
  ## The rule for a skip that stays on the walk it is already on, such as the
  ## ``^`` skip, whose newline is found by scanning bytes: jumping straight
  ## onto an off-chain offset would put the scan on a different walk and miss
  ## start positions the current one still owes.  A ``\Z`` skip is a window,
  ## not a walk, and re-bases instead — see [semiEndScanStart].
  ##
  ## Under a case-sensitive literal prefix the scan steps by bytes, so every
  ## offset is a candidate; otherwise it follows the ``encLen`` chain and the
  ## chain has to be walked to reach ``target``.
  if byteScan:
    return clamp(target, start, s.len)
  result = start
  while result < target and result < s.len:
    result = nextScanPos(s, result)

proc semiEndScanStart(s: string, regex: Regex, start: int): int =
  ## Where ``onig_search`` starts a forward scan for a pattern anchored at
  ## ``\Z``.  A match can only end at the subject's end or just before a
  ## newline that ends it, so everything more than ``semiEndDMax`` bytes to
  ## the left of that anchor is skipped rather than tried.
  ##
  ## A *window*, not a walk: ``onig_search`` computes the range start by
  ## arithmetic (``min_semi_end - dmax``), adjusts it to a character head and
  ## searches from there, so the landing point need not be on the ``encLen``
  ## chain from ``start``.  The walk that follows is the chain from where it
  ## lands.  Hence ``\Z`` and ``\s\Z`` differ on ``"\xC0\n"``: ``dmax == 0``
  ## gives window ``[1, 1]`` and a match at the newline, ``dmax == 1`` gives
  ## ``[0, 0]``, where ``\s`` cannot match ``"\xC0"``.
  let dmax = regex.semiEndDMax
  if dmax < 0:
    return start # Unbounded match length: no position can be ruled out.
  let preEnd = prevCharHead(s, s.len)
  let minSemiEnd =
    if s[preEnd] == '\n':
      # Oniguruma only jumps when the newline leaves room to its left.
      if preEnd == 0 or start > preEnd:
        return start
      preEnd
    else:
      s.len
  if minSemiEnd - start <= dmax:
    return start
  result = minSemiEnd - dmax
  if result < s.len:
    result = rightAdjustCharHead(s, result)

const TrueCont*: ContId = -1'i32 ## Sentinel "no further continuation, succeed".

# Counters in this region are bounded by ``stepLimit`` / ``MaxCallDepth`` / the
# subject length, and ``lengthBounds`` guards overflow
# explicitly, so the checks would only cost the hot path instructions.
{.push overflowChecks: off.}

const CapSavesKeep = 4096
  ## ``capSaves`` capacity (~64 KB) a context keeps between searches for free;
  ## anything above this is released once it stops being used.

const CapSavesQuietRuns = 16
  ## Consecutive searches that must stay within ``CapSavesKeep`` before an
  ## outsized ``capSaves`` buffer is handed back.

const MaxQuantRepetitions = 10_000
const MaxCallDepth* = 400
  ## Stack-overflow guard: each concat node costs ~4 real call frames, so
  ## this stays well below Nim's debug call-depth limit of 2000.

# Forward declarations
proc matchWithCont(ctx: MatchContext, node: Node, cont: ContId): bool
proc matchSeqCont(ctx: MatchContext, parent: Node, idx: int, cont: ContId): bool
proc matchQuantGreedy(
  ctx: MatchContext, body: Node, minRep, maxRep, count: int, cont: ContId
): bool

proc matchQuantLazy(
  ctx: MatchContext, body: Node, minRep, maxRep, count: int, cont: ContId
): bool

proc runCont(ctx: MatchContext, cont: ContId): bool

proc pushFrame(ctx: MatchContext, frame: sink Frame): ContId {.inline.} =
  ## Push a frame and return its index.  The pusher must pop it
  ## (``ctx.frames.setLen(fid)``) before returning to its caller.
  result = ctx.frames.len.int32
  ctx.frames.add(frame)

template copyCaptures(dst, src, n: untyped) =
  ## ``Span`` is a plain two-int value, so a snapshot moves in one block.
  ## A template so the ``addr`` operands are only taken when ``n > 0``.
  if n > 0:
    copyMem(addr dst, addr src, n * sizeof(Span))

proc pushCaptures(ctx: MatchContext): int32 {.inline.} =
  ## Copy ``ctx.captures`` onto the side stack and return its offset.
  result = ctx.capSaves.len.int32
  let n = ctx.captures.len
  ctx.capSaves.setLen(int(result) + n)
  copyCaptures(ctx.capSaves[int(result)], ctx.captures[0], n)
  if ctx.capSaves.len > ctx.capSavesPeak:
    ctx.capSavesPeak = ctx.capSaves.len

proc popCapturesTo(ctx: MatchContext, off: int32) {.inline.} =
  ## Copy the slice at ``off`` back into ``ctx.captures`` and release it.
  copyCaptures(ctx.captures[0], ctx.capSaves[int(off)], ctx.captures.len)
  ctx.capSaves.setLen(off)

proc saveScalars(ctx: MatchContext): ScalarState {.inline.} =
  ## Snapshot everything but the capture vector.  Nothing is pushed onto
  ## ``capSaves``, so the result rolls back with ``restoreScalars`` only.
  ScalarState(
    pos: ctx.pos,
    flags: ctx.flags,
    keepStart: ctx.keepStart,
    subjectEnd: ctx.subjectEnd,
    graphemeMode: ctx.graphemeMode,
  )

proc save(ctx: MatchContext): SavedState =
  SavedState(scalars: saveScalars(ctx), capOff: pushCaptures(ctx))

proc pos(s: SavedState): int {.inline.} =
  s.scalars.pos

proc restoreScalars(ctx: MatchContext, s: ScalarState) {.inline.} =
  ctx.pos = s.pos
  ctx.flags = s.flags
  ctx.keepStart = s.keepStart
  ctx.subjectEnd = s.subjectEnd
  ctx.graphemeMode = s.graphemeMode

proc restore(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Roll back to ``s`` and release its slot on the side stack.
  restoreScalars(ctx, s.scalars)
  popCapturesTo(ctx, s.capOff)

proc rewind(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Roll back to ``s`` but keep its slot, so it can be replayed again.
  ## The caller is responsible for releasing the stack afterwards.
  restoreScalars(ctx, s.scalars)
  copyCaptures(ctx.captures[0], ctx.capSaves[int(s.capOff)], ctx.captures.len)

proc restoreKeepingCaptures(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Roll back everything except the capture vector.  Positive lookaround
  ## and lookbehind keep what their (zero-width) body captured.
  restoreScalars(ctx, s.scalars)
  ctx.capSaves.setLen(s.capOff)

proc drop(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Release ``s``'s slot without rolling anything back.
  ctx.capSaves.setLen(s.capOff)

proc saveStackLens(ctx: MatchContext): seq[int] =
  ## Snapshot the per-group ``captureStacks[i].len`` so a lookaround body
  ## cannot leak recursion-level capture frames.  Lengths suffice:
  ## ``matchCapture`` already restores in-place values on failure, so only
  ## growth is visible.  When the stacks are clean the snapshot is left
  ## empty — ``restoreStackLens`` then trims everything back to zero.
  if ctx.captureStacksDirty:
    result = newSeq[int](ctx.captureStacks.len)
    for i in 0 ..< ctx.captureStacks.len:
      result[i] = ctx.captureStacks[i].len

proc restoreStackLens(ctx: MatchContext, savedLens: sink seq[int]) =
  ## Trim each ``captureStacks[i]`` back to its saved length, keeping the
  ## inner ``seq`` capacity.  An empty snapshot means "trim everything"
  ## (see ``saveStackLens``).
  if savedLens.len == 0:
    if ctx.captureStacksDirty:
      for i in 0 ..< ctx.captureStacks.len:
        ctx.captureStacks[i].setLen(0)
      ctx.captureStacksDirty = false
    return
  for i in 0 ..< savedLens.len:
    if i < ctx.captureStacks.len:
      ctx.captureStacks[i].setLen(savedLens[i])
  # Recompute dirty flag: if every stack we touched is now empty AND no
  # later stack was added, captureStacks is back to a clean state.
  var stillDirty = false
  for i in 0 ..< ctx.captureStacks.len:
    if ctx.captureStacks[i].len > 0:
      stillDirty = true
      break
  ctx.captureStacksDirty = stillDirty

proc matchSeqCont(ctx: MatchContext, parent: Node, idx: int, cont: ContId): bool =
  template nodes(): untyped =
    parent.children

  if idx >= nodes.len:
    return runCont(ctx, cont)
  # Handle absent range markers in sequence
  let node = nodes[idx]
  if node.kind == nkAbsent and node.absentKind == abRange:
    # (?~|absent) - limit matching range to exclude absent
    let rangeStart = ctx.pos
    let absentBody = node.absentBody
    # Find first position where absent matches
    var absentPos = ctx.subjectEnd
    block findAbsent:
      var checkPos = rangeStart
      while checkPos < ctx.subjectEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if matchWithCont(ctx, absentBody, TrueCont):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.subjectEnd:
          break
        var r: Rune
        nextCharAt(ctx.subject.oa, checkPos, r)
    ctx.pos = rangeStart
    let savedEnd = ctx.subjectEnd
    ctx.subjectEnd = absentPos
    let fid = pushFrame(
      ctx,
      Frame(
        kind: ckRestoreSubjectEnd,
        parent: cont,
        reSavedEnd: savedEnd,
        reAbsentPos: absentPos,
      ),
    )
    let ok = matchSeqCont(ctx, parent, idx + 1, fid)
    ctx.frames.setLen(fid)
    ctx.subjectEnd = savedEnd
    return ok
  if node.kind == nkAbsent and node.absentKind == abClear:
    # (?~|) or (?~) in sequence - restore subject end (clear absent range limit)
    ctx.subjectEnd = ctx.subject.len
    return matchSeqCont(ctx, parent, idx + 1, cont)
  let fid = pushFrame(
    ctx, Frame(kind: ckSeqContinue, parent: cont, sNode: parent, sIdx: int32(idx + 1))
  )
  let ok = matchWithCont(ctx, nodes[idx], fid)
  ctx.frames.setLen(fid)
  ok

proc caseInsensitiveMatch(r, target: Rune, flags: RegexFlags): bool =
  ## Case-insensitive comparison respecting rfIgnoreCaseAscii flag.
  if rfIgnoreCase notin flags:
    return r == target
  if rfIgnoreCaseAscii in flags:
    # ASCII-only: only fold if both are ASCII
    if int32(r) <= 127 and int32(target) <= 127:
      return simpleFold(r) == simpleFold(target)
    return r == target
  simpleFold(r) == simpleFold(target)

proc matchBytes(ctx: MatchContext, target: Rune, p: int): int {.inline.} =
  ## Compare the encoding of ``target`` against the subject at ``p``.
  ## Returns the position just past it, or -1 on mismatch.  Oniguruma holds a
  ## case-sensitive literal as the bytes it was written with and compares
  ## those, so this never decodes the subject: an overlong encoding of the
  ## same code point is a different byte string and does not match.
  var buf: array[4, char]
  let n = utf8Encode(int32(target), buf)
  if p + n > ctx.subjectEnd:
    return -1
  for i in 0 ..< n:
    if ctx.subject[p + i] != buf[i]:
      return -1
  p + n

proc matchLiteral(ctx: MatchContext, target: Rune, cont: ContId): bool =
  if ctx.pos >= ctx.subjectEnd:
    return false
  let savedPos = ctx.pos
  if rfIgnoreCase notin ctx.flags:
    let e = matchBytes(ctx, target, savedPos)
    if e < 0:
      return false
    ctx.pos = e
    if runCont(ctx, cont):
      return true
    ctx.pos = savedPos
    return false
  var code: int32
  var next: int
  if not decodeChar(ctx, savedPos, code, next):
    return false
  let r = Rune(code)
  # Under (?i) the comparison is on code points, and it reads the subject
  # character through the same containers a class would, so an overlong
  # encoding of an ASCII letter still fails.
  if codeIsClassifiable(code, next - savedPos) and
      (r == target or caseInsensitiveMatch(r, target, ctx.flags)):
    ctx.pos = next
    if runCont(ctx, cont):
      return true
  ctx.pos = savedPos
  # Multi-char fold: pattern char folds to multiple chars (e.g., ß → ss)
  if rfIgnoreCase in ctx.flags and
      (rfIgnoreCaseAscii notin ctx.flags or int32(target) <= 127):
    let fold = getMultiCharFold(target)
    if fold.len > 0:
      ctx.pos = savedPos
      var matched = true
      for i in 0 ..< fold.len:
        if ctx.pos >= ctx.subjectEnd:
          matched = false
          break
        var sc: int32
        var sn: int
        if not decodeChar(ctx, ctx.pos, sc, sn) or
            not codeIsClassifiable(sc, sn - ctx.pos) or
            not caseInsensitiveMatch(Rune(sc), fold.runes[i], ctx.flags):
          matched = false
          break
        ctx.pos = sn
      if matched and runCont(ctx, cont):
        return true
      ctx.pos = savedPos
  false

proc matchString(ctx: MatchContext, runes: seq[Rune], cont: ContId): bool =
  let savedPos = ctx.pos
  var i = 0
  while i < runes.len:
    if ctx.pos >= ctx.subjectEnd:
      ctx.pos = savedPos
      return false
    let target = runes[i]
    let posBeforeSubjChar = ctx.pos
    if rfIgnoreCase notin ctx.flags:
      # Case-sensitive: the whole string is compared as bytes.
      let e = matchBytes(ctx, target, ctx.pos)
      if e < 0:
        ctx.pos = savedPos
        return false
      ctx.pos = e
      inc i
      continue
    var code: int32
    var next: int
    if not decodeChar(ctx, ctx.pos, code, next):
      ctx.pos = savedPos
      return false
    let r = Rune(code)
    let classifiable = codeIsClassifiable(code, next - ctx.pos)
    ctx.pos = next
    let posAfterSubjChar = next
    if classifiable and (r == target or caseInsensitiveMatch(r, target, ctx.flags)):
      inc i
      continue
    # Try forward multi-char fold: pattern char folds to multiple subject chars (e.g., ß → ss)
    if rfIgnoreCase in ctx.flags and
        (rfIgnoreCaseAscii notin ctx.flags or int32(target) <= 127):
      let fold = getMultiCharFold(target)
      if fold.len > 0:
        ctx.pos = posBeforeSubjChar
        var matched = true
        for j in 0 ..< fold.len:
          if ctx.pos >= ctx.subjectEnd:
            matched = false
            break
          var sc: int32
          var sn: int
          if not decodeChar(ctx, ctx.pos, sc, sn) or
              not codeIsClassifiable(sc, sn - ctx.pos) or
              not caseInsensitiveMatch(Rune(sc), fold.runes[j], ctx.flags):
            matched = false
            break
          ctx.pos = sn
        if matched:
          inc i
          continue
    # Try reverse multi-char fold: subject char folds to consecutive pattern chars
    # e.g., subject "ß" matches pattern "ss" because ß full-folds to ss
    if rfIgnoreCase in ctx.flags and rfIgnoreCaseAscii notin ctx.flags:
      let fold = getMultiCharFold(r)
      if fold.len > 0 and i + fold.len <= runes.len:
        var matched = true
        for j in 0 ..< fold.len:
          if not caseInsensitiveMatch(fold.runes[j], runes[i + j], ctx.flags):
            matched = false
            break
        if matched:
          ctx.pos = posAfterSubjChar
          i += fold.len
          continue
    ctx.pos = savedPos
    return false
  if runCont(ctx, cont):
    return true
  ctx.pos = savedPos
  false

proc matchCharType(ctx: MatchContext, ct: CharTypeKind, cont: ContId): bool =
  if ctx.pos >= ctx.subjectEnd:
    return false
  let savedPos = ctx.pos
  # Grapheme cluster: \X or . in grapheme/word mode.  These work on byte
  # sequences rather than a single decoded character, so they run first.
  if ct == ctGraphemeCluster or
      (ct == ctDot and ctx.graphemeMode in {gmGrapheme, gmWord}):
    # A cluster still starts with a character, so a sequence truncated by the
    # end of the subject is no cluster either.
    var probe: int32
    var probeNext: int
    if not decodeChar(ctx, savedPos, probe, probeNext):
      return false
    if ct == ctDot:
      let isNewline = codeIsClassifiable(probe, probeNext - savedPos) and probe == 0x0A
      if isNewline and rfMultiLine notin ctx.flags:
        return false
    let clusterEnd =
      if ctx.graphemeMode == gmWord:
        nextWordSegmentEnd(ctx.subject.oa, savedPos)
      else:
        nextGraphemeClusterEnd(ctx.subject.oa, savedPos)
    if clusterEnd > savedPos:
      ctx.pos = clusterEnd
      if runCont(ctx, cont):
        return true
    ctx.pos = savedPos
    return false

  var code: int32
  var next: int
  if not decodeChar(ctx, savedPos, code, next):
    return false
  let classifiable = codeIsClassifiable(code, next - savedPos)

  # Newline sequence: \R matches \r\n, \r, \n, \v, \f, or a Unicode line
  # separator.  It reads as a positive class over those code points, so an
  # unclassifiable character — an overlong "\xC0\x8A", a stray 0x85 byte —
  # matches none of them.
  if ct == ctNewlineSeq:
    if not classifiable:
      return false
    if code == 0x0D:
      ctx.pos = next
      if ctx.pos < ctx.subjectEnd and ctx.subject[ctx.pos] == '\n':
        inc ctx.pos
      if runCont(ctx, cont):
        return true
      ctx.pos = savedPos
      return false
    elif code in [0x0A'i32, 0x0B, 0x0C, 0x85, 0x2028, 0x2029]:
      ctx.pos = next
      if runCont(ctx, cont):
        return true
      ctx.pos = savedPos
      return false
    else:
      return false

  let r = Rune(code)
  # ``member`` is the positive class test; the negative types invert it.
  # Every type below except ``\w``/``\W`` and ``\O`` is a class, so its
  # members are only reachable by a character ``codeIsClassifiable`` admits.
  # ``\w`` and ``\W`` test the code point directly, the way Oniguruma's
  # OP_WORD does, and so also see a one-byte character above U+007F.
  let matched =
    case ct
    of ctDot:
      rfMultiLine in ctx.flags or not (classifiable and code == 0x0A)
    of ctNotNewline:
      not (classifiable and code == 0x0A)
    of ctWord:
      isWordChar(r, rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctNotWord:
      not isWordChar(r, rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctDigit:
      classifiable and
        isDigitChar(r, rfAsciiDigit in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctNotDigit:
      not (
        classifiable and
        isDigitChar(r, rfAsciiDigit in ctx.flags or rfAsciiPosix in ctx.flags)
      )
    of ctSpace:
      classifiable and
        isSpaceChar(r, rfAsciiSpace in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctNotSpace:
      not (
        classifiable and
        isSpaceChar(r, rfAsciiSpace in ctx.flags or rfAsciiPosix in ctx.flags)
      )
    of ctHexDigit:
      classifiable and isHexDigitChar(r)
    of ctNotHexDigit:
      not (classifiable and isHexDigitChar(r))
    of ctAnyChar:
      true
    of ctNewlineSeq, ctGraphemeCluster:
      false # unreachable: handled above
  if matched:
    ctx.pos = next
    if runCont(ctx, cont):
      return true
  ctx.pos = savedPos
  false

proc matchAnchor(ctx: MatchContext, kind: AnchorKind, cont: ContId): bool =
  let matched =
    case kind
    of akLineBegin:
      ctx.pos == 0 or (ctx.pos > 0 and ctx.subject[ctx.pos - 1] == '\n')
    of akLineEnd:
      ctx.pos >= ctx.subjectEnd or ctx.subject[ctx.pos] == '\n'
    of akStringBegin:
      ctx.pos == 0
    of akStringEnd:
      ctx.pos >= ctx.subjectEnd
    of akStringEndOrNewline:
      ctx.pos >= ctx.subjectEnd or
        (ctx.pos == ctx.subjectEnd - 1 and ctx.subject[ctx.pos] == '\n')
    of akSearchBegin:
      ctx.pos == ctx.searchStart
    of akKeep:
      true
    of akWordBoundary, akNotWordBoundary:
      false # handled in matchWithCont dispatch before reaching here
    of akGraphemeBoundary:
      if ctx.graphemeMode == gmWord:
        isWordBoundaryUax29(ctx.subject.oa, ctx.pos)
      else:
        isGraphemeBoundary(ctx.subject.oa, ctx.pos)
    of akNotGraphemeBoundary:
      if ctx.graphemeMode == gmWord:
        not isWordBoundaryUax29(ctx.subject.oa, ctx.pos)
      else:
        not isGraphemeBoundary(ctx.subject.oa, ctx.pos)
  if matched:
    if kind == akKeep:
      ctx.keepStart = ctx.pos
    return runCont(ctx, cont)
  false

proc tryCaptureChangingMatch(ctx: MatchContext, body: Node): bool {.inline.} =
  ## Attempt ``body`` and accept only if captures changed (via
  ## ``ckCapturesChanged``), popping the frame and snapshot before
  ## returning.  Lets zero-width quantifier subloops force the body to
  ## pick a different alternative each iteration.
  let snapStart = ctx.captureSnapshots.len.int32
  for c in ctx.captures:
    ctx.captureSnapshots.add(c)
  let fid = pushFrame(
    ctx, Frame(kind: ckCapturesChanged, parent: TrueCont, ccSnapshotStart: snapStart)
  )
  result = matchWithCont(ctx, body, fid)
  ctx.frames.setLen(fid)
  ctx.captureSnapshots.setLen(snapStart)

proc matchQuantGreedyIter(
    ctx: MatchContext, body: Node, minRep, maxRep, startCount: int, cont: ContId
): bool =
  ## Iterative greedy fallback for large repetition counts.
  ## Matches body greedily, then tries cont from longest to shortest.
  ## States stay replayable, so it uses ``rewind`` and frees the run at once.
  let baseOff = ctx.capSaves.len.int32
  var states: seq[SavedState]
  states.add(save(ctx))
  var reps = 0

  while (maxRep < 0 or startCount + reps < maxRep) and reps < MaxQuantRepetitions:
    let before = save(ctx)
    if not matchWithCont(ctx, body, TrueCont):
      restore(ctx, before)
      break
    if ctx.pos == before.pos:
      # Zero-width match: try cont, then force capture changes (matches recursive version)
      if startCount + reps >= minRep:
        if runCont(ctx, cont):
          ctx.capSaves.setLen(baseOff)
          return true
      for _ in 0 ..< ctx.captures.len:
        let s2 = save(ctx)
        if not tryCaptureChangingMatch(ctx, body):
          restore(ctx, s2)
          break
        if ctx.pos != s2.pos:
          restore(ctx, s2)
          break
        inc reps
        if startCount + reps >= minRep:
          if runCont(ctx, cont):
            ctx.capSaves.setLen(baseOff)
            return true
        drop(ctx, s2)
      restore(ctx, before)
      break
    drop(ctx, before)
    states.add(save(ctx))
    inc reps

  for i in countdown(states.high, 0):
    if startCount + i >= minRep:
      rewind(ctx, states[i])
      if runCont(ctx, cont):
        ctx.capSaves.setLen(baseOff)
        return true

  rewind(ctx, states[0])
  ctx.capSaves.setLen(baseOff)
  false

proc matchQuantLazyIter(
    ctx: MatchContext, body: Node, minRep, maxRep, startCount: int, cont: ContId
): bool =
  ## Iterative lazy fallback for large repetition counts.
  var reps = 0

  while startCount + reps < minRep and (maxRep < 0 or startCount + reps < maxRep) and
      reps < MaxQuantRepetitions:
    let before = save(ctx)
    if not matchWithCont(ctx, body, TrueCont):
      restore(ctx, before)
      return false
    drop(ctx, before)
    if ctx.pos == before.pos:
      break
    inc reps

  if startCount + reps < minRep:
    return false

  while reps < MaxQuantRepetitions:
    let saved = save(ctx)
    if runCont(ctx, cont):
      drop(ctx, saved)
      return true
    restore(ctx, saved)

    if maxRep >= 0 and startCount + reps >= maxRep:
      break

    let before = save(ctx)
    if not matchWithCont(ctx, body, TrueCont):
      restore(ctx, before)
      break
    if ctx.pos == before.pos:
      # Zero-width match: try cont, then force capture changes (matches recursive version)
      if runCont(ctx, cont):
        drop(ctx, before)
        return true
      for _ in 0 ..< ctx.captures.len:
        let s2 = save(ctx)
        if not tryCaptureChangingMatch(ctx, body):
          restore(ctx, s2)
          break
        if ctx.pos != s2.pos:
          restore(ctx, s2)
          break
        inc reps
        if runCont(ctx, cont):
          drop(ctx, before)
          return true
        drop(ctx, s2)
      restore(ctx, before)
      break
    drop(ctx, before)
    inc reps

  false

const QuantRecursionThreshold = 300
  ## Switch from recursive (fully correct) to iterative (stack-safe) after
  ## this many repetitions. 300 × ~4 frames ≈ 1200, safe within Nim debug
  ## call-depth limit of 2000.

proc matchQuantGreedy(
    ctx: MatchContext, body: Node, minRep, maxRep, count: int, cont: ContId
): bool =
  if count >= QuantRecursionThreshold:
    return matchQuantGreedyIter(ctx, body, minRep, maxRep, count, cont)
  # Greedy: try one more repetition first, then fall back to continuation
  if maxRep < 0 or count < maxRep:
    let saved = save(ctx)
    let fid = pushFrame(
      ctx,
      Frame(
        kind: ckQuantGreedyMore,
        parent: cont,
        qBody: body,
        qMinRep: int32(minRep),
        qMaxRep: int32(maxRep),
        qCount: int32(count),
        qSavedPos: saved.pos,
      ),
    )
    let ok = matchWithCont(ctx, body, fid)
    ctx.frames.setLen(fid)
    if ok:
      drop(ctx, saved)
      return true
    restore(ctx, saved)

  # Fall back: stop repeating, try continuation
  if count >= minRep:
    return runCont(ctx, cont)
  false

proc matchQuantLazy(
    ctx: MatchContext, body: Node, minRep, maxRep, count: int, cont: ContId
): bool =
  if count >= QuantRecursionThreshold:
    return matchQuantLazyIter(ctx, body, minRep, maxRep, count, cont)
  # Lazy: try continuation first, then one more repetition
  if count >= minRep:
    let saved = save(ctx)
    if runCont(ctx, cont):
      drop(ctx, saved)
      return true
    restore(ctx, saved)

  if maxRep < 0 or count < maxRep:
    let saved = save(ctx)
    let fid = pushFrame(
      ctx,
      Frame(
        kind: ckQuantLazyMore,
        parent: cont,
        qBody: body,
        qMinRep: int32(minRep),
        qMaxRep: int32(maxRep),
        qCount: int32(count),
        qSavedPos: saved.pos,
      ),
    )
    let ok = matchWithCont(ctx, body, fid)
    ctx.frames.setLen(fid)
    if ok:
      drop(ctx, saved)
      return true
    restore(ctx, saved)
  false

proc matchQuantPossessive(
    ctx: MatchContext, body: Node, minRep, maxRep: int, bodyWrites: bool, cont: ContId
): bool =
  # Possessive: match greedily, no backtracking on count.  ``bodyWrites`` is
  # the compiler's verdict on whether the body can touch anything besides
  # ``pos``; it is loop-invariant, hence two loops rather than a branch inside
  # one.
  let savedScalars = saveScalars(ctx)
  var count = 0
  if bodyWrites:
    # Two slots: the full rollback at the end, plus one scratch slot the loop
    # overwrites in place — a ``save``/``drop`` pair per iteration would add
    # two ``setLen`` calls on top of the copy that is actually needed.
    let savedCapOff = pushCaptures(ctx)
    let attemptOff = pushCaptures(ctx)
    let n = ctx.captures.len
    while maxRep < 0 or count < maxRep:
      # Per-iteration rollback: a body failing part-way can still have moved
      # ``keepStart`` or written captures.
      let attemptScalars = saveScalars(ctx)
      copyCaptures(ctx.capSaves[int(attemptOff)], ctx.captures[0], n)
      if not matchWithCont(ctx, body, TrueCont):
        restoreScalars(ctx, attemptScalars)
        copyCaptures(ctx.captures[0], ctx.capSaves[int(attemptOff)], n)
        break
      count += 1
      if ctx.pos == attemptScalars.pos:
        break # zero-width: count as one rep, then stop
    ctx.capSaves.setLen(attemptOff) # release the scratch slot
    if count >= minRep and runCont(ctx, cont):
      ctx.capSaves.setLen(savedCapOff)
      return true
    # Full rollback: the successful repetitions kept no snapshot of their own.
    restoreScalars(ctx, savedScalars)
    popCapturesTo(ctx, savedCapOff)
    return false
  # The body only moves ``pos``, so every rollback here is a scalar copy
  # and nothing is pushed onto the side stack at all.
  while maxRep < 0 or count < maxRep:
    let attemptPos = ctx.pos
    if not matchWithCont(ctx, body, TrueCont):
      ctx.pos = attemptPos
      break
    count += 1
    if ctx.pos == attemptPos:
      break # zero-width: count as one rep, then stop
  if count >= minRep and runCont(ctx, cont):
    return true
  restoreScalars(ctx, savedScalars)
  false

proc runQuantGreedyMore(ctx: MatchContext, contId: ContId): bool =
  ## Continuation invoked after a single greedy quantifier body match.
  ## Captures the body's outcome ("zero-width" vs progress) and decides
  ## whether to try one more repetition or fall back to ``cont``.
  let fr = ctx.frames[contId]
  let savedPos = fr.qSavedPos
  let body = fr.qBody
  let minRep = int(fr.qMinRep)
  let maxRep = int(fr.qMaxRep)
  let count = int(fr.qCount)
  let parent = fr.parent
  if ctx.pos == savedPos:
    # Zero-width body match. Try cont, then try more iterations
    # in a bounded loop to set different captures (no recursive backtracking).
    if runCont(ctx, parent):
      return true
    # Force body to pick alternatives that change captures
    for _ in 0 ..< ctx.captures.len:
      let s2 = save(ctx)
      if not tryCaptureChangingMatch(ctx, body):
        restore(ctx, s2)
        break
      if ctx.pos != s2.pos:
        restore(ctx, s2)
        break
      if runCont(ctx, parent):
        drop(ctx, s2)
        return true
      drop(ctx, s2)
    return false
  matchQuantGreedy(ctx, body, minRep, maxRep, count + 1, parent)

proc runQuantLazyMore(ctx: MatchContext, contId: ContId): bool =
  let savedPos = ctx.frames[contId].qSavedPos
  let body = ctx.frames[contId].qBody
  let minRep = int(ctx.frames[contId].qMinRep)
  let maxRep = int(ctx.frames[contId].qMaxRep)
  let count = int(ctx.frames[contId].qCount)
  let parent = ctx.frames[contId].parent
  if ctx.pos == savedPos:
    if runCont(ctx, parent):
      return true
    for _ in 0 ..< ctx.captures.len:
      let s2 = save(ctx)
      if not tryCaptureChangingMatch(ctx, body):
        restore(ctx, s2)
        break
      if ctx.pos != s2.pos:
        restore(ctx, s2)
        break
      if runCont(ctx, parent):
        drop(ctx, s2)
        return true
      drop(ctx, s2)
    return false
  matchQuantLazy(ctx, body, minRep, maxRep, count + 1, parent)

proc matchCcAtom(r: Rune, atom: CcAtom, flags: RegexFlags): bool =
  case atom.kind
  of ccLiteral:
    r == atom.rune or caseInsensitiveMatch(r, atom.rune, flags)
  of ccRange:
    let lo = int32(atom.rangeFrom)
    let hi = int32(atom.rangeTo)
    let ri = int32(r)
    if ri >= lo and ri <= hi:
      true
    elif rfIgnoreCase in flags:
      if rfIgnoreCaseAscii in flags:
        # ASCII-only: only fold ASCII characters
        if ri <= 127:
          let fi = int32(simpleFold(r))
          fi >= lo and fi <= hi
        else:
          false
      else:
        # Check if any case variant of r falls in the original range
        for variant in caseFoldVariants(r):
          if int32(variant) >= lo and int32(variant) <= hi:
            return true
        false
    else:
      false
  of ccCharType:
    case atom.charType
    of ctWord:
      # Inside [...] Oniguruma uses the raw CR_Word ranges: no Latin-1 extras.
      isWordChar(r, rfAsciiWord in flags or rfAsciiPosix in flags, latin1Digits = false)
    of ctNotWord:
      not isWordChar(
        r, rfAsciiWord in flags or rfAsciiPosix in flags, latin1Digits = false
      )
    of ctDigit:
      isDigitChar(r, rfAsciiDigit in flags or rfAsciiPosix in flags)
    of ctNotDigit:
      not isDigitChar(r, rfAsciiDigit in flags or rfAsciiPosix in flags)
    of ctSpace:
      isSpaceChar(r, rfAsciiSpace in flags or rfAsciiPosix in flags)
    of ctNotSpace:
      not isSpaceChar(r, rfAsciiSpace in flags or rfAsciiPosix in flags)
    of ctHexDigit:
      isHexDigitChar(r)
    of ctNotHexDigit:
      not isHexDigitChar(r)
    of ctDot, ctAnyChar:
      true
    of ctNotNewline:
      r != Rune(0x0A)
    of ctNewlineSeq:
      let c = int32(r)
      c == 0x0A or c == 0x0D or c == 0x0B or c == 0x0C or c == 0x85 or c == 0x2028 or
        c == 0x2029
    of ctGraphemeCluster:
      true # \X in character classes: any character
  of ccPosix:
    matchPosixClass(r, atom.posixClass, posixAsciiOnly(atom.posixClass, flags))
  of ccNegPosix:
    not matchPosixClass(r, atom.posixClass, posixAsciiOnly(atom.posixClass, flags))
  of ccUnicodeProp:
    matchUnicodeProp(r, atom.prop, flags)
  of ccNegUnicodeProp:
    not matchUnicodeProp(r, atom.prop, flags)
  of ccNestedClass:
    var anyMatch = false
    for nested in atom.nestedAtoms:
      if matchCcAtom(r, nested, flags):
        anyMatch = true
        break
    if atom.nestedNegated:
      not anyMatch
    else:
      anyMatch
  of ccIntersection:
    # Character must match BOTH left and right sides
    var leftMatch = false
    for a in atom.interLeft:
      if matchCcAtom(r, a, flags):
        leftMatch = true
        break
    if atom.interLeftNeg:
      leftMatch = not leftMatch
    var rightMatch = false
    for a in atom.interRight:
      if matchCcAtom(r, a, flags):
        rightMatch = true
        break
    if atom.interRightNeg:
      rightMatch = not rightMatch
    leftMatch and rightMatch

proc matchCcAtomWithFold(r: Rune, atom: CcAtom, flags: RegexFlags): bool =
  ## Match a character class atom, checking case-fold variants for
  ## POSIX, char type, and Unicode property atoms when case-insensitive.
  if matchCcAtom(r, atom, flags):
    return true
  if rfIgnoreCase in flags:
    # With rfIgnoreCaseAscii, only fold ASCII characters
    if rfIgnoreCaseAscii in flags and int32(r) > 127:
      return false
    case atom.kind
    of ccPosix, ccNegPosix, ccCharType, ccUnicodeProp, ccNegUnicodeProp:
      # Check case-fold variants
      for variant in caseFoldVariants(r):
        if variant != r and matchCcAtom(variant, atom, flags):
          return true
    of ccNestedClass:
      for variant in caseFoldVariants(r):
        if variant != r and matchCcAtom(variant, atom, flags):
          return true
    else:
      discard
  false

proc tryMultiCharFold(ctx: MatchContext, node: Node, cont: ContId): bool =
  ## Try multi-character case fold expansions for bracket character classes.
  ## e.g., (?i:[ß]) should match "ss" because ß folds to "ss".
  if not (rfIgnoreCase in ctx.flags and node.bracketClass and not node.negated):
    return false
  for fold in MultiCharFolds:
    let (srcCP, expCP, expLen) = fold
    let srcRune = Rune(srcCP)
    # Check if the source rune matches any atom in the class
    var atomMatch = false
    for atom in node.atoms:
      if matchCcAtomWithFold(srcRune, atom, ctx.flags):
        atomMatch = true
        break
    if not atomMatch:
      continue
    # Check if the expansion matches at the current position (case-insensitively)
    var p = ctx.pos
    var ok = true
    for i in 0 ..< expLen:
      if p >= ctx.subjectEnd:
        ok = false
        break
      var subjRune: Rune
      nextCharAt(ctx.subject.oa, p, subjRune)
      let expRune = Rune(expCP[i])
      if subjRune != expRune and simpleFold(subjRune) != simpleFold(expRune):
        ok = false
        break
    if ok:
      let savedPos = ctx.pos
      ctx.pos = p
      if runCont(ctx, cont):
        return true
      ctx.pos = savedPos
  false

proc classHasByte(node: Node, b: uint8, flags: RegexFlags): bool =
  ## Whether a *one-byte* character stands in the class's byte container.
  ##
  ## Below U+0080 every container agrees, so the ordinary member test
  ## answers it.  At or above, only a range written across the ASCII
  ## boundary reaches: Oniguruma fills its byte set from ``lo`` to
  ## ``min(hi, 0xFF)`` whenever ``lo`` is single-byte, so ``[a-ÿ]`` accepts a
  ## stray ``0xFF`` byte while ``[ÿ]`` and ``[[:alpha:]]`` do not.
  if b < 0x80:
    let r = Rune(int32(b))
    for atom in node.atoms:
      if node.bracketClass and matchCcAtomWithFold(r, atom, flags):
        return true
      elif not node.bracketClass and matchCcAtom(r, atom, flags):
        return true
    return false
  for atom in node.atoms:
    if atom.kind == ccRange and int32(atom.rangeFrom) < 0x80 and
        int32(b) <= int32(atom.rangeTo):
      return true
  false

proc matchCharClass(ctx: MatchContext, node: Node, cont: ContId): bool =
  if ctx.pos >= ctx.subjectEnd:
    return false
  # Try multi-char case fold first (e.g., ß → ss)
  if rfIgnoreCase in ctx.flags:
    if tryMultiCharFold(ctx, node, cont):
      return true
  let savedPos = ctx.pos
  var code: int32
  var next: int
  if not decodeChar(ctx, savedPos, code, next):
    return false

  # A class keeps its members in two containers and picks one by the
  # character's encoded length, not by its value.  A one-byte character is
  # looked up in the byte set; a longer one in the code-point ranges, which
  # hold nothing below U+0080 — so an overlong ``"\xC0\xB1"`` matches no
  # member.  Negation applies on top of the lookup either way, which is why
  # ``[^a]`` accepts a stray ``0x80`` byte that ``[\x{80}]`` rejects.
  var anyMatch = false
  if next - savedPos == 1:
    anyMatch = classHasByte(node, uint8(code), ctx.flags)
  elif code >= 0x80:
    let r = Rune(code)
    for atom in node.atoms:
      if node.bracketClass and matchCcAtomWithFold(r, atom, ctx.flags):
        anyMatch = true
        break
      elif not node.bracketClass and matchCcAtom(r, atom, ctx.flags):
        anyMatch = true
        break

  let matched =
    if node.negated:
      not anyMatch
    else:
      anyMatch
  if matched:
    ctx.pos = next
    if runCont(ctx, cont):
      return true
  ctx.pos = savedPos
  false

proc prevCharCode(s: openArray[char], pos: int): int32 =
  ## The code point of the character ending just before ``pos``, or -1 when
  ## ``pos`` is 0 and there is no such character.
  ##
  ## For ``pos > 0`` there is always an answer, so callers need no -1 check
  ## there: `prevCharAt` either finds a character ending exactly at ``pos``
  ## or reads the byte covered by nothing as its own value.
  if pos <= 0:
    return -1
  var q: int
  prevCharAt(s, pos, q)

proc matchWordBoundary(ctx: MatchContext): bool =
  let asciiOnly = rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags
  let prevIsWord =
    if ctx.pos > 0:
      isWordChar(Rune(prevCharCode(ctx.subject.oa, ctx.pos)), asciiOnly)
    else:
      false
  let nextIsWord =
    if ctx.pos < ctx.subjectEnd:
      var code: int32
      var next: int
      # ``\b`` reads the code point directly, like ``\w``: no class
      # containers are involved, so a one-byte character above U+007F counts.
      decodeChar(ctx, ctx.pos, code, next) and isWordChar(Rune(code), asciiOnly)
    else:
      false
  prevIsWord xor nextIsWord

proc resolveCapture(ctx: MatchContext, capIdx: int, level: int): Span =
  ## Resolve a capture, optionally using recursion-level stack.
  ## level > 0: access the level-th entry (1-based) in the capture stack for this group.
  ## level 0: use the current capture value.
  if level > 0 and capIdx > 0 and capIdx - 1 < ctx.captureStacks.len:
    let stack = ctx.captureStacks[capIdx - 1] # captureStacks is 0-based by group
    if level <= stack.len:
      return stack[level - 1] # 1-based: level 1 = first entry
    return UnsetSpan
  if capIdx >= ctx.captures.len:
    return UnsetSpan
  ctx.captures[capIdx]

proc matchBackref(ctx: MatchContext, capIdx: int, cont: ContId, level: int = 0): bool =
  let cap = resolveCapture(ctx, capIdx, level)
  if cap.a < 0:
    return false # unset capture
  let capLen = cap.b - cap.a
  if rfIgnoreCase in ctx.flags:
    # Compare rune by rune with case fold. Also handle multi-character folds
    # (e.g. ß ↔ ss) symmetrically on both captured and subject sides.
    var sp = cap.a
    var mp = ctx.pos
    while sp < cap.b:
      if mp >= ctx.subjectEnd:
        return false
      let mpBefore = mp
      var sr, mr: Rune
      nextCharAt(ctx.subject.oa, sp, sr)
      nextCharAt(ctx.subject.oa, mp, mr)
      if sr == mr or caseInsensitiveMatch(sr, mr, ctx.flags):
        continue
      let asciiOnly = rfIgnoreCaseAscii in ctx.flags
      # Forward multi-char fold: captured rune folds to multiple subject runes.
      block forwardFold:
        if asciiOnly and int32(sr) > 127:
          break forwardFold
        let fold = getMultiCharFold(sr)
        if fold.len == 0:
          break forwardFold
        var tp = mpBefore
        var ok = true
        for j in 0 ..< fold.len:
          if tp >= ctx.subjectEnd:
            ok = false
            break
          var tr: Rune
          nextCharAt(ctx.subject.oa, tp, tr)
          if not caseInsensitiveMatch(tr, fold.runes[j], ctx.flags):
            ok = false
            break
        if ok:
          mp = tp
          continue
      # Reverse multi-char fold: subject rune folds to multiple captured runes.
      block reverseFold:
        if asciiOnly:
          break reverseFold
        let fold = getMultiCharFold(mr)
        if fold.len == 0:
          break reverseFold
        if not caseInsensitiveMatch(sr, fold.runes[0], ctx.flags):
          break reverseFold
        var tp = sp
        var ok = true
        for j in 1 ..< fold.len:
          if tp >= cap.b:
            ok = false
            break
          var tr: Rune
          nextCharAt(ctx.subject.oa, tp, tr)
          if not caseInsensitiveMatch(tr, fold.runes[j], ctx.flags):
            ok = false
            break
        if ok:
          sp = tp
          continue
      return false
    let savedPos = ctx.pos
    ctx.pos = mp # use actual bytes consumed, not capture byte length
    if runCont(ctx, cont):
      return true
    ctx.pos = savedPos
    false
  else:
    if ctx.pos + capLen > ctx.subjectEnd:
      return false
    for i in 0 ..< capLen:
      if ctx.subject[cap.a + i] != ctx.subject[ctx.pos + i]:
        return false
    let savedPos = ctx.pos
    ctx.pos += capLen
    if runCont(ctx, cont):
      return true
    ctx.pos = savedPos
    false

proc matchCapture(ctx: MatchContext, index: int, body: Node, cont: ContId): bool =
  let capIdx = index + 1 # boundaries[0] = overall match
  let startPos = ctx.pos
  let savedFlags = ctx.flags
  # Capture recursion depth at entry time (before continuations modify it)
  let myDepth =
    if index < ctx.groupRecursionDepth.len:
      ctx.groupRecursionDepth[index]
    else:
      -1
  let fid = pushFrame(
    ctx,
    Frame(
      kind: ckCapture,
      parent: cont,
      cCapIdx: int32(capIdx),
      cIndex: int32(index),
      cMyDepth: int32(myDepth),
      cStartPos: startPos,
      cSavedFlags: savedFlags,
    ),
  )
  let ok = matchWithCont(ctx, body, fid)
  ctx.frames.setLen(fid)
  ok

proc runCapture(ctx: MatchContext, contId: ContId): bool =
  ## Continuation for ``matchCapture``: write the capture span, chain to
  ## the parent continuation, and on failure restore the previous span.
  let capIdx = int(ctx.frames[contId].cCapIdx)
  let index = int(ctx.frames[contId].cIndex)
  let myDepth = int(ctx.frames[contId].cMyDepth)
  let startPos = ctx.frames[contId].cStartPos
  let savedFlags = ctx.frames[contId].cSavedFlags
  let parent = ctx.frames[contId].parent
  let endPos = ctx.pos
  let savedCap = ctx.captures[capIdx]
  ctx.captures[capIdx] = span(startPos, endPos)
  var savedStackEntry = UnsetSpan
  if myDepth >= 0:
    if index >= ctx.captureStacks.len:
      ctx.captureStacks.setLen(index + 1)
    if myDepth >= ctx.captureStacks[index].len:
      ctx.captureStacks[index].setLen(myDepth + 1)
    savedStackEntry = ctx.captureStacks[index][myDepth]
    ctx.captureStacks[index][myDepth] = span(startPos, endPos)
    ctx.captureStacksDirty = true
  let modFlags = ctx.flags
  ctx.flags = savedFlags # restore flags at group boundary
  let ok = runCont(ctx, parent)
  if not ok:
    ctx.captures[capIdx] = savedCap
    ctx.flags = modFlags
    if myDepth >= 0:
      ctx.captureStacks[index][myDepth] = savedStackEntry
  ok

proc endCheckFrame(targetPos: int): Frame {.inline.} =
  Frame(kind: ckEndCheckPos, parent: TrueCont, ecpTargetPos: targetPos)

proc matchLookbehindFixed(
    ctx: MatchContext, body: Node, targetEnd: int, fbl: int, cont: ContId
): bool =
  ## Fixed-length lookbehind: only one starting position to try.
  let st = targetEnd - fbl
  if st < 0:
    return false
  let stackSnap = saveStackLens(ctx)
  let saved = save(ctx)
  ctx.pos = st
  let fid = pushFrame(ctx, endCheckFrame(targetEnd))
  let bodyMatch = matchWithCont(ctx, body, fid)
  ctx.frames.setLen(fid)
  if bodyMatch:
    restoreKeepingCaptures(ctx, saved)
    restoreStackLens(ctx, stackSnap)
    return runCont(ctx, cont)
  restore(ctx, saved)
  restoreStackLens(ctx, stackSnap)
  false

proc matchNegLookbehindFixed(
    ctx: MatchContext, body: Node, targetEnd: int, fbl: int, cont: ContId
): bool =
  ## Fixed-length negative lookbehind: only one starting position to try.
  let st = targetEnd - fbl
  if st < 0:
    return runCont(ctx, cont) # can't match → negative succeeds
  let stackSnap = saveStackLens(ctx)
  let saved = save(ctx)
  ctx.pos = st
  let fid = pushFrame(ctx, endCheckFrame(targetEnd))
  let matched = matchWithCont(ctx, body, fid)
  ctx.frames.setLen(fid)
  restore(ctx, saved)
  restoreStackLens(ctx, stackSnap)
  if matched:
    return false
  runCont(ctx, cont)

proc boundsUsable(ctx: MatchContext, node: Node): bool {.inline.} =
  ## Whether the compile-time annotation on ``node`` was taken under the flags
  ## in force now.  A subexpression call can reach the same lookaround under
  ## others (``(?i)\g<1>``); a mismatch falls back to walking the tree.
  node.lookBoundsValid and node.lookBoundsFlags == ctx.flags and
    node.lookBoundsGm == ctx.graphemeMode

proc bodyBounds(ctx: MatchContext, node: Node): LenBounds {.inline.} =
  if ctx.boundsUsable(node):
    node.lookBounds
  else:
    lengthBounds(node.lookBody, ctx.flags, ctx.graphemeMode)

proc altBounds(ctx: MatchContext, node: Node, i: int, alt: Node): LenBounds {.inline.} =
  if ctx.boundsUsable(node) and i < node.lookAltBounds.len:
    node.lookAltBounds[i]
  else:
    lengthBounds(alt, ctx.flags, ctx.graphemeMode)

proc matchLookaround(ctx: MatchContext, node: Node, cont: ContId): bool =
  let kind = node.lookKind
  case kind
  of lkAhead:
    let stackSnap = saveStackLens(ctx)
    let saved = save(ctx)
    let bodyMatch = matchWithCont(ctx, node.lookBody, TrueCont)
    if bodyMatch:
      # Keep the captures the lookahead body made.
      restoreKeepingCaptures(ctx, saved)
      restoreStackLens(ctx, stackSnap)
      return runCont(ctx, cont)
    restore(ctx, saved)
    restoreStackLens(ctx, stackSnap)
    false
  of lkNegAhead:
    let stackSnap = saveStackLens(ctx)
    let saved = save(ctx)
    let bodyMatch = matchWithCont(ctx, node.lookBody, TrueCont)
    restore(ctx, saved)
    restoreStackLens(ctx, stackSnap)
    if not bodyMatch:
      return runCont(ctx, cont)
    false
  of lkBehind:
    let targetEnd = ctx.pos
    # For alternation at top level: try each branch independently with its own length
    let body = node.lookBody
    if body.kind == nkAlternation:
      for i, alt in body.alternatives:
        let altLen = ctx.altBounds(node, i, alt)
        let altFbl = altLen.fixedLen
        if altFbl >= 0:
          # Fixed-length alternative: try at exact start position
          let st = targetEnd - altFbl
          if st >= 0:
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            ctx.pos = st
            let fid = pushFrame(ctx, endCheckFrame(targetEnd))
            let bodyMatch = matchWithCont(ctx, alt, fid)
            ctx.frames.setLen(fid)
            if bodyMatch:
              restoreKeepingCaptures(ctx, saved)
              restoreStackLens(ctx, stackSnap)
              if runCont(ctx, cont):
                return true
            else:
              restore(ctx, saved)
              restoreStackLens(ctx, stackSnap)
        else:
          # Variable-length alternative: scan from shortest to longest
          let altMbl = altLen.maxLen
          let altMinPos =
            if altMbl >= 0:
              max(0, targetEnd - altMbl)
            else:
              0
          var startTry = targetEnd
          while startTry >= altMinPos:
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            ctx.pos = startTry
            let fid = pushFrame(ctx, endCheckFrame(targetEnd))
            let bodyMatch = matchWithCont(ctx, alt, fid)
            ctx.frames.setLen(fid)
            if bodyMatch:
              restoreKeepingCaptures(ctx, saved)
              restoreStackLens(ctx, stackSnap)
              return runCont(ctx, cont) # shortest priority: commit
            restore(ctx, saved)
            restoreStackLens(ctx, stackSnap)
            if startTry == 0:
              break
            startTry = prevCharStart(ctx.subject.oa, startTry)
      return false
    let bodyLen = ctx.bodyBounds(node)
    if bodyLen.fixedLen >= 0:
      return matchLookbehindFixed(ctx, body, targetEnd, bodyLen.fixedLen, cont)
    # Variable-length (non-alternation): shortest priority (commit to first match)
    let mbl = bodyLen.maxLen
    let minPos =
      if mbl >= 0:
        max(0, targetEnd - mbl)
      else:
        0
    var startTry = targetEnd
    while startTry >= minPos:
      let stackSnap = saveStackLens(ctx)
      let saved = save(ctx)
      ctx.pos = startTry
      let fid = pushFrame(ctx, endCheckFrame(targetEnd))
      let bodyMatch = matchWithCont(ctx, body, fid)
      ctx.frames.setLen(fid)
      if bodyMatch:
        restoreKeepingCaptures(ctx, saved)
        restoreStackLens(ctx, stackSnap)
        return runCont(ctx, cont) # shortest priority: commit to this match
      restore(ctx, saved)
      restoreStackLens(ctx, stackSnap)
      if startTry == 0:
        break
      startTry = prevCharStart(ctx.subject.oa, startTry)
    false
  of lkNegBehind:
    let targetEnd = ctx.pos
    let body = node.lookBody
    if body.kind == nkAlternation:
      # Try each alternative independently — if ANY matches, negative fails
      for i, alt in body.alternatives:
        let altLen = ctx.altBounds(node, i, alt)
        let altFbl = altLen.fixedLen
        if altFbl >= 0:
          let st = targetEnd - altFbl
          if st >= 0:
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            ctx.pos = st
            let fid = pushFrame(ctx, endCheckFrame(targetEnd))
            let matched = matchWithCont(ctx, alt, fid)
            ctx.frames.setLen(fid)
            restore(ctx, saved)
            restoreStackLens(ctx, stackSnap)
            if matched:
              return false
        else:
          let altMbl = altLen.maxLen
          let altMinPos =
            if altMbl >= 0:
              max(0, targetEnd - altMbl)
            else:
              0
          var startTry = targetEnd
          while startTry >= altMinPos:
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            ctx.pos = startTry
            let fid = pushFrame(ctx, endCheckFrame(targetEnd))
            let matched = matchWithCont(ctx, alt, fid)
            ctx.frames.setLen(fid)
            restore(ctx, saved)
            restoreStackLens(ctx, stackSnap)
            if matched:
              return false
            if startTry == 0:
              break
            startTry = prevCharStart(ctx.subject.oa, startTry)
      return runCont(ctx, cont)
    let bodyLen = ctx.bodyBounds(node)
    if bodyLen.fixedLen >= 0:
      return matchNegLookbehindFixed(ctx, body, targetEnd, bodyLen.fixedLen, cont)
    # Variable-length (non-alternation): scan from right to left
    let negMbl = bodyLen.maxLen
    let negMinPos =
      if negMbl >= 0:
        max(0, targetEnd - negMbl)
      else:
        0
    var startTry = targetEnd
    while startTry >= negMinPos:
      let stackSnap = saveStackLens(ctx)
      let saved = save(ctx)
      ctx.pos = startTry
      let fid = pushFrame(ctx, endCheckFrame(targetEnd))
      let matched = matchWithCont(ctx, body, fid)
      ctx.frames.setLen(fid)
      restore(ctx, saved)
      restoreStackLens(ctx, stackSnap)
      if matched:
        return false
      if startTry == 0:
        break
      startTry = prevCharStart(ctx.subject.oa, startTry)
    runCont(ctx, cont)

proc matchAtomic(ctx: MatchContext, body: Node, cont: ContId): bool =
  let saved = save(ctx)
  if matchWithCont(ctx, body, TrueCont):
    # Body matched — commit, no backtracking into body
    if runCont(ctx, cont):
      drop(ctx, saved)
      return true
  restore(ctx, saved)
  false

proc matchAbsent(ctx: MatchContext, node: Node, cont: ContId): bool =
  case node.absentKind
  of abClear:
    # (?~) or (?~|) - always matches empty, restore subject end
    ctx.subjectEnd = ctx.subject.len
    return runCont(ctx, cont)
  of abFunction:
    # (?~pattern) - match longest text not containing pattern
    let startPos = ctx.pos
    # Find first position where absent pattern matches with non-zero width
    var firstAbsentPos = ctx.subjectEnd # default: no absent found -> match to end
    var checkPos = startPos
    while checkPos < ctx.subjectEnd:
      let saved = save(ctx)
      ctx.pos = checkPos
      let fid = pushFrame(
        ctx, Frame(kind: ckNonZeroPos, parent: TrueCont, nzpStartPos: checkPos)
      )
      let bodyMatch = matchWithCont(ctx, node.absentBody, fid)
      ctx.frames.setLen(fid)
      if bodyMatch:
        firstAbsentPos = checkPos
        restore(ctx, saved)
        break
      restore(ctx, saved)
      var r: Rune
      nextCharAt(ctx.subject.oa, checkPos, r)
    # Match from startPos to firstAbsentPos (longest text before absent)
    ctx.pos = firstAbsentPos
    if runCont(ctx, cont):
      return true
    # If continuation fails, try shorter matches
    var tryPos = firstAbsentPos - 1
    while tryPos >= startPos:
      # Walk back to valid UTF-8 boundary
      if tryPos > startPos and (ctx.subject[tryPos].ord and 0xC0) == 0x80:
        dec tryPos
        continue
      ctx.pos = tryPos
      if runCont(ctx, cont):
        return true
      dec tryPos
    ctx.pos = startPos
    false
  of abExpression:
    # (?~|absent|expr) - match expr, limiting range to exclude absent
    let startPos = ctx.pos
    let absentBody = node.absentBody
    # Find first position where absent matches
    var absentPos = ctx.subjectEnd
    block findAbsent:
      var checkPos = startPos
      while checkPos < ctx.subjectEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if matchWithCont(ctx, absentBody, TrueCont):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.subjectEnd:
          break
        var r: Rune
        nextCharAt(ctx.subject.oa, checkPos, r)
    # Limit matching range to [startPos, absentPos)
    let savedEnd = ctx.subjectEnd
    ctx.pos = startPos
    ctx.subjectEnd = absentPos
    let fid = pushFrame(
      ctx,
      Frame(
        kind: ckRestoreSubjectEnd,
        parent: cont,
        reSavedEnd: savedEnd,
        reAbsentPos: absentPos,
      ),
    )
    let ok = matchWithCont(ctx, node.absentExpr, fid)
    ctx.frames.setLen(fid)
    ctx.subjectEnd = savedEnd
    return ok
  of abRange:
    # (?~|absent) - range marker: zero-width, limits subjectEnd
    let absentBody = node.absentBody
    var absentPos = ctx.subjectEnd
    block findAbsent:
      var checkPos = ctx.pos
      while checkPos < ctx.subjectEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if matchWithCont(ctx, absentBody, TrueCont):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.subjectEnd:
          break
        var r: Rune
        nextCharAt(ctx.subject.oa, checkPos, r)
    let savedEnd = ctx.subjectEnd
    ctx.subjectEnd = absentPos
    let ok = runCont(ctx, cont)
    if not ok:
      ctx.subjectEnd = savedEnd # restore only on failure
    return ok

proc matchWithCont(ctx: MatchContext, node: Node, cont: ContId): bool =
  inc ctx.steps
  if ctx.steps > ctx.stepLimit:
    raise newException(RegexLimitError, "match step limit exceeded")
  inc ctx.callDepth
  if ctx.callDepth > MaxCallDepth:
    dec ctx.callDepth
    raise newException(RegexLimitError, "match call depth exceeded")
  defer:
    dec ctx.callDepth
  case node.kind
  of nkLiteral:
    matchLiteral(ctx, node.rune, cont)
  of nkEscapedLiteral:
    matchLiteral(ctx, node.escapedRune, cont)
  of nkString:
    matchString(ctx, node.runes, cont)
  of nkConcat:
    matchSeqCont(ctx, node, 0, cont)
  of nkAlternation:
    for alt in node.alternatives:
      # Save pos, captures, keepStart — but NOT flags.
      # Isolated flag groups (?i) extend across alternation branches.
      let savedPos = ctx.pos
      let savedKeep = ctx.keepStart
      let capOff = pushCaptures(ctx)
      if matchWithCont(ctx, alt, cont):
        ctx.capSaves.setLen(capOff)
        return true
      ctx.pos = savedPos
      popCapturesTo(ctx, capOff)
      ctx.keepStart = savedKeep
    false
  of nkCharType:
    matchCharType(ctx, node.charType, cont)
  of nkCharClass:
    matchCharClass(ctx, node, cont)
  of nkGroup:
    # Groups save/restore flags — isolated flag groups inside don't leak out
    let savedFlags = ctx.flags
    let fid =
      pushFrame(ctx, Frame(kind: ckGroup, parent: cont, grpSavedFlags: savedFlags))
    let ok = matchWithCont(ctx, node.groupBody, fid)
    ctx.frames.setLen(fid)
    if not ok:
      ctx.flags = savedFlags
    ok
  of nkCapture:
    let savedFlags = ctx.flags
    let ok = matchCapture(ctx, node.captureIndex, node.captureBody, cont)
    if not ok:
      ctx.flags = savedFlags
    ok
  of nkNamedCapture:
    let savedFlags = ctx.flags
    let ok = matchCapture(ctx, node.namedCaptureIndex, node.namedCaptureBody, cont)
    if not ok:
      ctx.flags = savedFlags
    ok
  of nkFlagGroup:
    if node.flagBody == nil:
      ctx.flags = ctx.flags + node.flagsOn - node.flagsOff
      if node.graphemeMode != gmNone:
        ctx.graphemeMode = node.graphemeMode
      runCont(ctx, cont)
    else:
      let savedFlags = ctx.flags
      let savedGM = ctx.graphemeMode
      ctx.flags = ctx.flags + node.flagsOn - node.flagsOff
      if node.graphemeMode != gmNone:
        ctx.graphemeMode = node.graphemeMode
      let fid = pushFrame(
        ctx,
        Frame(
          kind: ckFlagGroup, parent: cont, fgSavedFlags: savedFlags, fgSavedGM: savedGM
        ),
      )
      let ok = matchWithCont(ctx, node.flagBody, fid)
      ctx.frames.setLen(fid)
      if not ok:
        ctx.flags = savedFlags
        ctx.graphemeMode = savedGM
      ok
  of nkAnchor:
    if node.anchor == akWordBoundary:
      if matchWordBoundary(ctx):
        return runCont(ctx, cont)
      return false
    elif node.anchor == akNotWordBoundary:
      if not matchWordBoundary(ctx):
        return runCont(ctx, cont)
      return false
    else:
      matchAnchor(ctx, node.anchor, cont)
  of nkQuantifier:
    # Oniguruma: {n,m} where n > m → possessive {0, max(n,m)}
    var qmin = node.quantMin
    var qmax = node.quantMax
    var qkind = node.quantKind
    if qmax >= 0 and qmin > qmax:
      swap(qmin, qmax)
      qkind = qkPossessive
    case qkind
    of qkGreedy:
      matchQuantGreedy(ctx, node.quantBody, qmin, qmax, 0, cont)
    of qkLazy:
      matchQuantLazy(ctx, node.quantBody, qmin, qmax, 0, cont)
    of qkPossessive:
      matchQuantPossessive(
        ctx, node.quantBody, qmin, qmax, not node.quantBodyPure, cont
      )
  of nkBackreference:
    matchBackref(ctx, node.backrefIndex, cont, node.backrefLevel)
  of nkNamedBackref:
    # Try ALL capture groups with matching name (for duplicate named captures)
    var anyFound = false
    for (name, i) in ctx.regex.namedCaptures:
      if name == node.backrefName:
        anyFound = true
        let idx = i + 1 # captures are 1-indexed in boundaries
        let saved = save(ctx)
        if matchBackref(ctx, idx, cont, node.namedBackrefLevel):
          drop(ctx, saved)
          return true
        restore(ctx, saved)
    if not anyFound:
      return false
    # All named groups exist but none captured → fail
    false
  of nkLookaround:
    matchLookaround(ctx, node, cont)
  of nkAtomicGroup:
    matchAtomic(ctx, node.atomicBody, cont)
  of nkSubexpCall:
    # \g<n> or \g<name>: match the body of the referenced capture group
    var body: Node = nil
    var captureIdx = -1 # 0-based index for matchCapture
    if node.callIndex == 0:
      # \g<0> = entire pattern recursion
      body = ctx.regex.ast
    elif node.callIndex > 0:
      let idx = node.callIndex - 1 # 0-based in groupBodies
      if idx < ctx.regex.groupBodies.len:
        body = ctx.regex.groupBodies[idx]
      captureIdx = idx
    elif node.callName.len > 0:
      for (name, i) in ctx.regex.namedCaptures:
        if name == node.callName:
          if i < ctx.regex.groupBodies.len:
            body = ctx.regex.groupBodies[i]
          captureIdx = i
          break
    if body == nil:
      return false
    inc ctx.recursionDepth
    if ctx.recursionDepth > ctx.maxRecursionDepth:
      dec ctx.recursionDepth
      return false # too deep recursion — treat as no match
    # Increment per-group recursion depth for recursion-level backrefs
    if captureIdx >= 0:
      if captureIdx >= ctx.groupRecursionDepth.len:
        ctx.groupRecursionDepth.setLen(captureIdx + 1)
      inc ctx.groupRecursionDepth[captureIdx]
    # Apply the flags that were active when the group was defined
    let savedFlags = ctx.flags
    if captureIdx >= 0 and captureIdx < ctx.regex.groupFlags.len:
      ctx.flags = ctx.regex.groupFlags[captureIdx]
    var ok: bool
    if captureIdx >= 0 and captureIdx + 1 < ctx.captures.len:
      ok = matchCapture(ctx, captureIdx, body, cont)
    else:
      ok = matchWithCont(ctx, body, cont)
    if not ok:
      ctx.flags = savedFlags
    # Decrement per-group recursion depth
    if captureIdx >= 0 and captureIdx < ctx.groupRecursionDepth.len:
      dec ctx.groupRecursionDepth[captureIdx]
    dec ctx.recursionDepth
    ok
  of nkConditional:
    var condMet = false
    case node.condKind
    of ckBackref:
      let capIdx = node.condRefIndex # 1-indexed capture
      if capIdx >= 0 and capIdx < ctx.captures.len:
        condMet = ctx.captures[capIdx].a >= 0
    of ckNamedRef:
      # Check ALL capture groups with matching name
      for (name, i) in ctx.regex.namedCaptures:
        if name == node.condRefName:
          let capIdx = i + 1
          if capIdx < ctx.captures.len and ctx.captures[capIdx].a >= 0:
            condMet = true
            break
    of ckAlwaysFalse:
      condMet = false
    of ckAlwaysTrue:
      condMet = true
    of ckRegexCond:
      # Match the condition regex at current position (consuming)
      if node.condBody != nil:
        if node.condBody.kind == nkLookaround and node.condBody.lookKind == lkNegAhead:
          # For negative lookaround conditions, evaluate the body directly.
          # When the body matches (negative lookaround fails → condition false),
          # we still need to preserve captures from the body match.
          let stackSnap = saveStackLens(ctx)
          let saved = save(ctx)
          let bodyMatch = matchWithCont(ctx, node.condBody.lookBody, TrueCont)
          if bodyMatch:
            condMet = false # negative lookaround failed, preserve captures
            restoreKeepingCaptures(ctx, saved)
          else:
            condMet = true # negative lookaround succeeded
            restore(ctx, saved)
          restoreStackLens(ctx, stackSnap)
        else:
          let stackSnap = saveStackLens(ctx)
          let saved = save(ctx)
          if matchWithCont(ctx, node.condBody, TrueCont):
            # Condition matched — condMet = true, pos is advanced past condition
            condMet = true
            drop(ctx, saved)
          else:
            restore(ctx, saved)
            restoreStackLens(ctx, stackSnap)
    if condMet:
      matchWithCont(ctx, node.condYes, cont)
    elif node.condNo != nil:
      matchWithCont(ctx, node.condNo, cont)
    elif node.condKind in {ckBackref, ckNamedRef} and (
      node.condYes == nil or
      (node.condYes.kind == nkConcat and node.condYes.children.len == 0)
    ):
      # Oniguruma fails a false backreference condition with neither an
      # else-branch nor a yes-branch: /(a)?(?(1))b/ does not match "b", while
      # /(a)?(?(1)(?:))b/ does — syntactic emptiness is what counts.
      false
    else:
      # Every other false condition with no else-branch is simply skipped:
      # Oniguruma for backreferences (/(a)?(?(1)x)b/ matches "b"), and PCRE2
      # for regex conditions and the reni-only forms, which Oniguruma has no
      # equivalent of.
      runCont(ctx, cont)
  of nkAbsent:
    matchAbsent(ctx, node, cont)
  of nkCalloutMax:
    let tag = node.maxTag
    let cur = ctx.calloutCounters.getOrDefault(tag, 0)
    if cur >= node.maxCount:
      return false
    ctx.calloutCounters[tag] = cur + 1
    let ok = runCont(ctx, cont)
    if not ok:
      ctx.calloutCounters[tag] = cur # backtrack
    ok
  of nkCalloutCount:
    let tag = node.countTag
    let cur = ctx.calloutCounters.getOrDefault(tag, 0)
    ctx.calloutCounters[tag] = cur + 1
    let ok = runCont(ctx, cont)
    if not ok:
      ctx.calloutCounters[tag] = cur # backtrack
    ok
  of nkCalloutCmp:
    let left = ctx.calloutCounters.getOrDefault(node.cmpLeft, 0)
    let right = ctx.calloutCounters.getOrDefault(node.cmpRight, 0)
    let cmpResult =
      case node.cmpOp
      of "<":
        left < right
      of ">":
        left > right
      of "==":
        left == right
      of "!=":
        left != right
      of "<=":
        left <= right
      of ">=":
        left >= right
      else:
        false
    if cmpResult:
      return runCont(ctx, cont)
    false

proc matchNode(ctx: MatchContext, node: Node): bool =
  matchWithCont(ctx, node, TrueCont)

proc writeFoundCopy(m: var Match, captures: seq[Span]) {.inline.}

proc runCont(ctx: MatchContext, cont: ContId): bool =
  ## Walk the continuation chain starting at ``cont``: each ``Frame``
  ## holds one step of post-match work plus a ``parent`` link.
  ## ``TrueCont`` (-1) means "no further work, succeed".
  if cont < 0:
    return true
  case ctx.frames[cont].kind
  of ckSeqContinue:
    let parentNode = ctx.frames[cont].sNode
    let idx = int(ctx.frames[cont].sIdx)
    let parent = ctx.frames[cont].parent
    matchSeqCont(ctx, parentNode, idx, parent)
  of ckCapture:
    runCapture(ctx, cont)
  of ckGroup:
    let savedFlags = ctx.frames[cont].grpSavedFlags
    let parent = ctx.frames[cont].parent
    let modFlags = ctx.flags
    ctx.flags = savedFlags
    let ok = runCont(ctx, parent)
    if not ok:
      ctx.flags = modFlags
    ok
  of ckFlagGroup:
    let savedFlags = ctx.frames[cont].fgSavedFlags
    let savedGM = ctx.frames[cont].fgSavedGM
    let parent = ctx.frames[cont].parent
    let modFlags = ctx.flags
    let modGM = ctx.graphemeMode
    ctx.flags = savedFlags
    ctx.graphemeMode = savedGM
    let ok = runCont(ctx, parent)
    if not ok:
      ctx.flags = modFlags
      ctx.graphemeMode = modGM
    ok
  of ckQuantGreedyMore:
    runQuantGreedyMore(ctx, cont)
  of ckQuantLazyMore:
    runQuantLazyMore(ctx, cont)
  of ckRestoreSubjectEnd:
    let savedEnd = ctx.frames[cont].reSavedEnd
    let absentPos = ctx.frames[cont].reAbsentPos
    let parent = ctx.frames[cont].parent
    ctx.subjectEnd = savedEnd
    let ok = runCont(ctx, parent)
    if not ok:
      ctx.subjectEnd = absentPos
    ok
  of ckEndCheckPos:
    ctx.pos == ctx.frames[cont].ecpTargetPos
  of ckNonZeroPos:
    ctx.pos > ctx.frames[cont].nzpStartPos
  of ckCapturesChanged:
    # Compare current captures against the side-stack snapshot.
    # ``ctx.captures.len`` is fixed for a given regex, so the snapshot
    # length always equals ``ctx.captures.len`` (no length check needed).
    let snapStart = int(ctx.frames[cont].ccSnapshotStart)
    var changed = false
    for i in 0 ..< ctx.captures.len:
      if ctx.captureSnapshots[snapStart + i] != ctx.captures[i]:
        changed = true
        break
    changed
  of ckFindLongestRec:
    let sp = ctx.frames[cont].flStartPos
    let mLen = ctx.pos - sp
    if mLen > ctx.flBestLen:
      ctx.flBestLen = mLen
      writeFoundCopy(ctx.flBestMatch, ctx.captures)
      ctx.flBestMatch.boundaries[0] = span(sp, ctx.pos)
      if ctx.keepStart != sp:
        ctx.flBestMatch.boundaries[0].a = ctx.keepStart
    false # force backtracking for more alternatives

{.pop.} # overflowChecks: off — see the matching {.push.} above

proc newMatchContext*(maxCapCount: int = 0): MatchContext =
  ## Allocate a reusable matcher scratch buffer.  Pre-sizing ``maxCapCount``
  ## avoids reallocation when the first regex has that many capture groups
  ## (default 0 means "grow on first use").
  result = MatchContext()
  # ``resetForRegex`` overwrites this; default to unlimited so a context used
  # before a reset cannot trip the step limit.
  result.stepLimit = int.high
  if maxCapCount > 0:
    result.captures = newSeq[Span](maxCapCount + 1)
    result.groupRecursionDepth = newSeq[int](maxCapCount)
    result.captureStacks = newSeq[seq[Span]](maxCapCount)

proc noteCapSavesUsage(ctx: MatchContext) =
  ## Account for one finished search against the ``capSaves`` side stack.
  ## ``setLen`` keeps the capacity, so one deep backtrack would pin tens of
  ## megabytes for the context's life; releasing on every search above
  ## ``CapSavesKeep`` would instead free and re-grow the buffer on every call,
  ## since a plain greedy quantifier over a few KB already reaches that mark.
  ## So hand the capacity back only after several small searches in a row.
  ## Quick rejects never touch the side stack but are counted here too, or a
  ## context that is only ever quick-rejected would hold its peak forever.
  if ctx.capSavesPeak > CapSavesKeep:
    ctx.capSavesQuiet = 0
    ctx.capSavesHigh = max(ctx.capSavesHigh, ctx.capSavesPeak)
  else:
    inc ctx.capSavesQuiet
    if ctx.capSavesQuiet >= CapSavesQuietRuns and ctx.capSavesHigh > CapSavesKeep:
      ctx.capSaves = newSeqOfCap[Span](CapSavesKeep)
      ctx.capSavesHigh = 0
      ctx.capSavesQuiet = 0
  ctx.capSavesPeak = 0

proc resetForRegex(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    stepLimit: int,
    maxRecursionDepth: int,
) =
  ## Reset per-regex buffers, reusing ``ctx``'s existing seq capacity.
  ctx.subject = toSubject(subject)
  ctx.flags = regex.flags
  ctx.regex = regex
  ctx.subjectEnd = subject.len
  ctx.stepLimit = if stepLimit > 0: stepLimit else: int.high
  ctx.maxRecursionDepth = maxRecursionDepth
  # Reset the per-search counters that used to be zero-initialized by
  # allocating a fresh ``MatchContext``.
  ctx.steps = 0
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  noteCapSavesUsage(ctx)
  let capCount = regex.captureCount
  # ``captures`` is sized exactly (it is copied into ``Match.boundaries``).
  # The internal buffers only grow, so their capacity survives a switch to
  # a regex with fewer captures; ``resetForPosition`` clears stale state.
  ctx.captures.setLen(capCount + 1)
  if capCount > ctx.groupRecursionDepth.len:
    ctx.groupRecursionDepth.setLen(capCount)
  if capCount > ctx.captureStacks.len:
    ctx.captureStacks.setLen(capCount)

proc initMatchContext(
    subject: string, regex: Regex, stepLimit: int, maxRecursionDepth: int
): MatchContext =
  ## Legacy entry point: allocates a fresh ``MatchContext`` each call.
  ## Retained so the value-returning ``searchImpl`` et al keep their
  ## existing semantics (no shared state between calls).
  result = newMatchContext(regex.captureCount)
  resetForRegex(result, subject, regex, stepLimit, maxRecursionDepth)

proc resetForPosition(ctx: MatchContext, startPos: int, searchStart: int) =
  ## Reset per-position state without reallocating.
  ctx.pos = startPos
  ctx.flags = ctx.regex.flags
  ctx.searchStart = searchStart
  ctx.keepStart = startPos
  ctx.subjectEnd = ctx.subject.len
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  # ``setLen(0)`` is a single length store; guarding it would cost more.
  ctx.frames.setLen(0)
  ctx.captureSnapshots.setLen(0)
  ctx.capSaves.setLen(0)
  for i in 0 ..< ctx.captures.len:
    ctx.captures[i] = UnsetSpan
  for i in 0 ..< ctx.groupRecursionDepth.len:
    ctx.groupRecursionDepth[i] = 0
  if ctx.captureStacksDirty:
    for i in 0 ..< ctx.captureStacks.len:
      ctx.captureStacks[i].setLen(0)
    ctx.captureStacksDirty = false
  if ctx.calloutCounters.len > 0:
    ctx.calloutCounters.clear()
  ctx.graphemeMode = gmNone

proc writeFoundCopy(m: var Match, captures: seq[Span]) {.inline.} =
  ## Fill ``m`` from a capture vector, reusing ``m.boundaries``' capacity.
  ## Used while ``captures`` is still live (e.g. in the findLongest frame,
  ## which may re-enter and mutate ``ctx.captures``).
  m.found = true
  m.boundaries.setLen(captures.len)
  for i in 0 ..< captures.len:
    m.boundaries[i] = captures[i]

proc writeNotFound(m: var Match) {.inline.} =
  m.found = false
  m.boundaries.setLen(0)

proc searchImplInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
) =
  ## In-place variant of ``searchImpl``: writes into ``m``, reusing
  ## ``ctx``'s buffers and ``m.boundaries``' capacity across calls.
  ## ``ctx`` must be caller-owned and single-threaded.
  let findLongest = rfFindLongest in regex.flags
  if findLongest:
    ctx.flBestLen = -1
    ctx.flBestMatch.found = false
    ctx.flBestMatch.boundaries.setLen(0)
  writeNotFound(m)
  # Quick reject: if the pattern requires a specific byte, check its presence.
  # ``extractRequiredByte`` only ever yields an ASCII byte of a case-sensitive
  # literal, and such a literal is compared byte for byte, so the byte has to
  # occur literally for any match to exist.
  let rb = regex.requiredByte
  if rb.valid:
    var found = false
    for i in start ..< subject.len:
      if subject[i].uint8 == rb.byte:
        found = true
        break
    if not found:
      noteCapSavesUsage(ctx)
      return
  resetForRegex(ctx, subject, regex, stepLimit, maxRecursionDepth)
  let fc = regex.firstCharInfo
  # A case-sensitive literal prefix is looked for as raw bytes, the way
  # Oniguruma's exact-string optimization does, so every byte offset is a
  # candidate start — including one inside a character the character walk
  # steps over.  Anything else walks characters.
  let byteScan = regex.literalScan
  var startPos = start
  if regex.semiEndAnchored and subject.len > 0 and fc.kind != fcAnchorStart:
    # ``onig_search`` resolves the anchors in one if/else chain, and ``\A``
    # wins over ``\Z``: an anchored pattern is only ever tried at ``start``.
    startPos = semiEndScanStart(subject, regex, start)
  # ``exhausted`` means the walk has no candidate left.
  var exhausted = false
  while true:
    if startPos > subject.len:
      exhausted = true
    # Fast skip based on first character optimization
    if not exhausted:
      case fc.kind
      of fcAnchorStart:
        if startPos != 0:
          exhausted = true
      of fcLineStart:
        # ``^`` only holds at the subject start and just after a newline, so
        # jump to the next line.  ``nl + 1`` is a target for
        # [advanceChainTo], not a position to jump onto.
        while startPos > 0 and subject[startPos - 1] != '\n':
          var nl = -1
          for i in startPos ..< subject.len:
            if subject[i] == '\n':
              nl = i
              break
          if nl < 0:
            exhausted = true
            break
          startPos = advanceChainTo(subject, startPos, nl + 1, byteScan)
      of fcByte:
        # Scan forward to the next candidate whose lead byte is the one the
        # pattern needs, stepping with ``nextScanPos``: a byte inside a
        # character the walk steps over is not a start position.
        var found = false
        while startPos < subject.len:
          if subject[startPos].uint8 == fc.byte:
            found = true
            break
          startPos =
            if byteScan:
              startPos + 1
            else:
              nextScanPos(subject, startPos)
        if not found:
          exhausted = true
      of fcByteSet:
        var found = false
        while startPos < subject.len:
          if subject[startPos].uint8 in fc.bytes:
            found = true
            break
          startPos =
            if byteScan:
              startPos + 1
            else:
              nextScanPos(subject, startPos)
        if not found:
          exhausted = true
      of fcNone:
        discard
    if exhausted:
      break

    resetForPosition(ctx, startPos, start)

    if findLongest:
      # Find longest: try all match alternatives at this position.  The
      # ckFindLongestRec frame mutates ``ctx.flBestMatch`` whenever a
      # longer match is found and returns false to force backtracking.
      let fid = pushFrame(
        ctx, Frame(kind: ckFindLongestRec, parent: TrueCont, flStartPos: startPos)
      )
      discard matchWithCont(ctx, regex.ast, fid)
      ctx.frames.setLen(fid)
    else:
      if matchNode(ctx, regex.ast):
        ctx.captures[0] = span(startPos, ctx.pos)
        if ctx.keepStart != startPos:
          ctx.captures[0].a = ctx.keepStart
        # Copy into m so that ctx.captures stays usable across calls.
        writeFoundCopy(m, ctx.captures)
        return

    # Advance to the next candidate start position.  Neither a plain
    # continuation-byte test nor the declared length is right alone — the
    # prefilters above land on a stray 0x80..0xBF byte and inside a truncated
    # sequence — so ``nextScanPos`` skips only what the decoder really covers.
    if startPos >= subject.len:
      break
    startPos =
      if byteScan:
        startPos + 1
      else:
        nextScanPos(subject, startPos)

  if findLongest and ctx.flBestMatch.found:
    # ctx.flBestMatch lives on the reusable context.  Copy its
    # boundaries into ``m`` so the next call may overwrite the slot.
    writeFoundCopy(m, ctx.flBestMatch.boundaries)

proc searchImpl*(
    subject: string,
    regex: Regex,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  let ctx = newMatchContext(regex.captureCount)
  searchImplInto(
    ctx,
    subject,
    regex,
    result,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc searchBackwardImplInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
) =
  ## In-place variant of ``searchBackwardImpl``.  Reuses ``ctx``.
  writeNotFound(m)
  # Quick reject: if the pattern requires a specific byte, check its presence.
  # ``extractRequiredByte`` only ever yields an ASCII byte of a case-sensitive
  # literal, and such a literal is compared byte for byte, so the byte has to
  # occur literally for any match to exist.
  let rb = regex.requiredByte
  if rb.valid:
    var found = false
    for i in 0 ..< subject.len:
      if subject[i].uint8 == rb.byte:
        found = true
        break
    if not found:
      noteCapSavesUsage(ctx)
      return
  resetForRegex(ctx, subject, regex, stepLimit, maxRecursionDepth)
  let fc = regex.firstCharInfo
  var startPos =
    if start >= 0:
      min(start, subject.len)
    else:
      subject.len
  # The backward scan steps with ``prevCharHead`` — Oniguruma's
  # ``ONIGENC_STEP_BACK(.., 1)``, the rule ``onig_search`` itself walks back
  # with.  It is deliberately *not* the ``encLen`` chain the forward scan
  # steps forward on: on malformed input the two disagree, and Oniguruma
  # disagrees with itself in exactly the same way.  Matching the forward
  # scan's positions instead would need the chain materialized from offset 0,
  # which costs O(subject) memory and moves the answers further from
  # Oniguruma's, not closer.
  #
  # ``literalScan`` takes byte-wise candidates, matching the forward scan's
  # literal search.  Each step below is guarded by ``startPos > 0``.
  let byteScan = regex.literalScan

  while startPos >= 0:
    # Fast skip based on first character optimization
    case fc.kind
    of fcAnchorStart:
      if startPos != 0:
        startPos = 0
        continue
    of fcLineStart:
      discard # backward scan walks positions one by one; no skip to make
    of fcByte:
      while startPos > 0 and startPos < subject.len and
          subject[startPos].uint8 != fc.byte:
        startPos =
          if byteScan:
            startPos - 1
          else:
            prevCharHead(subject, startPos)
      if startPos < subject.len and subject[startPos].uint8 != fc.byte:
        break
    of fcByteSet:
      while startPos > 0 and startPos < subject.len and
          subject[startPos].uint8 notin fc.bytes:
        startPos =
          if byteScan:
            startPos - 1
          else:
            prevCharHead(subject, startPos)
      if startPos < subject.len and subject[startPos].uint8 notin fc.bytes:
        break
    of fcNone:
      discard

    # \G in backward search anchors at the end of the string (the origin of
    # the backward scan), not at each candidate start position.
    resetForPosition(ctx, startPos, subject.len)

    if matchNode(ctx, regex.ast):
      ctx.captures[0] = span(startPos, ctx.pos)
      if ctx.keepStart != startPos:
        ctx.captures[0].a = ctx.keepStart
      writeFoundCopy(m, ctx.captures)
      return

    if startPos == 0:
      break
    startPos =
      if byteScan:
        startPos - 1
      else:
        prevCharHead(subject, startPos)

proc searchBackwardImpl*(
    subject: string,
    regex: Regex,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Search backward: try starting positions from right to left,
  ## return the first (rightmost) forward match found.
  ## If start >= 0, begin scanning from that position instead of the end.
  let ctx = newMatchContext(regex.captureCount)
  searchBackwardImplInto(
    ctx,
    subject,
    regex,
    result,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc matchAtImplInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
) =
  ## In-place variant of ``matchAtImpl``.  Reuses ``ctx``.
  writeNotFound(m)
  resetForRegex(ctx, subject, regex, stepLimit, maxRecursionDepth)
  resetForPosition(ctx, pos, pos)
  if matchNode(ctx, regex.ast):
    ctx.captures[0] = span(pos, ctx.pos)
    if ctx.keepStart != pos:
      ctx.captures[0].a = ctx.keepStart
    writeFoundCopy(m, ctx.captures)

proc matchAtImpl*(
    subject: string,
    regex: Regex,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Try to match only at the given position (no scanning).
  let ctx = newMatchContext(regex.captureCount)
  matchAtImplInto(
    ctx,
    subject,
    regex,
    result,
    pos = pos,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )
