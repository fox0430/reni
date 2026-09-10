## Backtracking regex matching engine.
## Uses an explicit frame stack on ``MatchContext`` for continuation
## passing, giving correct backtracking through alternations,
## quantifiers, and flag groups without per-call closure allocations.

import std/[unicode, tables]
from std/strutils import find

import types, unicode_utils, stackguard

# Re-exported so callers can read the compiled-in budget (used by tests).
export stackguard.MaxStackBytes

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
    ## Continuation frame. Frames live in a flat ``seq`` on ``MatchContext``;
    ## ``parent`` chains them. ``Node`` fields are cursors: the tree outlives
    ## every match, so ref-counting them would cost the hot path.
    parent: ContId
    case kind: ContKind
    of ckSeqContinue:
      sNode {.cursor.}: Node ## parent nkConcat node (children walked by idx)
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
      qBody {.cursor.}: Node
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
    ## Caller-owned matcher scratch buffer (engine-private, not thread-safe).
    ## Reuse across searches to keep seq capacity. ``{.acyclic.}``: nothing
    ## reachable links back.
    subject: Subject
    pos: int
    flags: RegexFlags
    captures: seq[Span]
    searchStart: int
    keepStart: int
    regex: ptr Regex
      ## Borrowed for one matcher entry point, exactly like ``subject``:
      ## holding the value would make ``resetForRegex`` deep-copy the pattern
      ## string and the group tables, which a findAll loop pays per search,
      ## not per pattern.  Each entry point passes the address of its own
      ## ``regex`` parameter, whose frame outlives every read below, and
      ## clears it again on the way out.  Only matching code may read it,
      ## and only past ``resetForRegex``: an entry point's quick-reject
      ## return runs before the reset and has to read the parameter
      ## directly.
    trackCaptureStacks: bool
      ## Mirror of ``Regex.levelBackrefs``: when false, both capture-history
      ## write sites -- ``runCapture`` and the ``ckCapture`` arm of
      ## ``runMachine``, which is the path the common case actually runs --
      ## skip the per-group history entirely.  The two have to stay in step:
      ## each records ``-1`` for the stack depth so ``chUndoCapture`` skips
      ## the matching restore.
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
    callDepth: int
      ## ``matchNodeRecursive`` nesting depth. Paces the stack sampling and
      ## guards debug builds under ``TrackCallDepth``.
    chainDepth: int
      ## Native frames currently held by ``runCont`` chain links (two for a
      ## capture link). Held-frame count, not total work; read only under
      ## ``TrackCallDepth``.
    stackBase: int
      ## Search start frame for ``stackUsed``. Recorded per start position to
      ## stay close to the running frame.
    captureStacksDirty: bool
      ## true when at least one ``captureStacks[i]`` is non-empty, letting
      ## ``resetForPosition`` skip the per-group ``setLen(0)`` loop in the
      ## common case.
    frames: seq[Frame]
      ## Frame buffer; live length is ``framesLen``. Never shrinks, so push/pop
      ## avoids destructors. Stale entries own nothing (``Node`` is a cursor).
    framesLen: int ## Live length of ``frames``.
    captureSnapshots: seq[Span]
      ## ``captures`` snapshots for ``ckCapturesChanged``, LIFO with ``frames``.
    choices: seq[Choice]
      ## Backtrack buffer; live length is ``choicesLen``. Never shrinks; stale
      ## entries own nothing (cursors and plain values only).
    choicesLen: int ## Live length of ``choices``. LIFO with ``frames`` and ``capSaves``.
    repPositions: seq[int]
      ## Repetition end positions for ``chSimpleRepeat``, LIFO with ``choices``.
      ## One ``int`` per rep; no snapshot needed since only ``pos`` changes.
      ## Live length is ``repLen`` so release is a length store.
    repLen: int ## Live length of ``repPositions``.
    repPeak: int
      ## High-water mark of ``repLen``. Needed because simple repeats push no
      ## choice point, so ``choicesPeak`` cannot see them.
    capSaves: seq[Span] ## Capture vectors for live ``SavedState`` snapshots (bulk copy).
    capSavesPeak: int ## High-water mark of ``capSaves`` for the current search.
    capSavesHigh: int ## Highest peak seen since the buffer was last released.
    stackLensSaves: seq[seq[int]]
      ## ``captureStacks`` length snapshots for ``chLookbehindAlt`` entries.
    choicesPeak: int
      ## High-water mark of ``choices``; measures whether a search was big.
    scratchQuiet: int ## Consecutive small searches within the keep marks.
    flBestLen: int ## findLongest: best match length so far (-1 if none)
    flBestMatch: Match ## findLongest: deepest match recorded

  ScalarState = object
    ## Rollback snapshot without captures; for bodies that write none.
    pos: int
    flags: RegexFlags
    keepStart: int
    subjectEnd: int
    graphemeMode: GraphemeMode

  ChoiceKind = enum
    ## Backtrack entry action. The first four offer an untried alternative;
    ## the rest undo an effect and keep failing.
    chAlt ## alternation: try the next branch
    chAltHinted ## alternation carrying first-byte hints: skip dead branches
    chLeafVariant ## literal / class: try the next way it can match
    chQuantGreedy ## greedy quantifier: stop repeating, run the continuation
    chQuantLazy ## lazy quantifier: the continuation failed, repeat once more
    chZeroWidthRep ## zero-width repetition: drive the body to change captures
    chSimpleRepeat ## greedy repetition of a single-way leaf: give one rep back
    chUndoState ## roll back to a snapshot, then keep failing
    chUndoScalars ## roll back everything but the captures, then keep failing
    chUndoFlags ## put back the flags a group boundary restored
    chUndoFlagsGM ## put back the flags and grapheme mode a flag group restored
    chUndoCapture ## put back the span, flags and stack entry a capture wrote
    chUndoSubjectEnd ## put back the subject end an absent range narrowed
    chWidenSubjectEnd ## widen the subject end an absent marker narrowed
    chAbsentFunc ## absent function: retry the continuation shorter
    chUndoPos ## rewind the position a backreference advanced
    chSubexpScope ## leave a subexpression call: depths and flags
    chLookbehindAlt ## alternation lookbehind: try the next alternative
    chUndoCallout ## put back the counter a callout incremented

  Choice = object
    ## Backtrack stack entry. Reifies the choice points and undo work the
    ## recursive matcher kept in native frames, so the matcher can run as a
    ## loop (see ``runMachine``). Restores only what its site restored; e.g.
    ## alternation leaves ``flags`` alone so ``(?i)`` spans branches.
    ## ``Node`` fields are cursors to avoid ref-count traffic on the hot path.
    case kind: ChoiceKind
    of chAlt, chAltHinted:
      aNode {.cursor.}: Node
      aIdx: int32 ## next branch to try
      aCont: ContId
      aFramesLen: int32
      aCapOff: int32
      aPos: int
      aKeepStart: int
    of chLeafVariant:
      lNode {.cursor.}: Node
      lVariant: int32 ## next way to try
      lCont: ContId
      lFramesLen: int32
      lPos: int
    of chQuantGreedy, chQuantLazy:
      qcBody {.cursor.}: Node
      qcMinRep: int32
      qcMaxRep: int32
      qcCount: int32
      qcCont: ContId
      qcFramesLen: int32
      qcPhase: int32 ## lazy only: 0 = body not yet tried, 1 = exhausted
      qcSaved: SavedState
    of chSimpleRepeat:
      srCont: ContId
      srFramesLen: int32
      srMinRep: int32
      srCount: int32 ## repetitions currently handed to the continuation
      srPosOff: int32 ## start of this repeat's run in ``MatchContext.repPositions``
      srScalars: ScalarState
        ## State at repeat start. Only ``pos`` comes from the body; the rest
        ## covers what the continuation changed (``\K``, flags). Captures need
        ## no snapshot: a single-way leaf writes none, and continuation
        ## captures have their own ``chUndoCapture`` entries.
    of chZeroWidthRep:
      zBody {.cursor.}: Node
      zCont: ContId
      zFramesLen: int32
      zIter: int32 ## capture-changing attempts made so far
      zSaved: SavedState ## the attempt behind the current captures
    of chUndoState:
      usFramesLen: int32
      usSaved: SavedState
    of chUndoScalars:
      uzFramesLen: int32
      uzScalars: ScalarState
    of chUndoFlags:
      ufFlags: RegexFlags
    of chUndoFlagsGM:
      ugFlags: RegexFlags
      ugGM: GraphemeMode
    of chUndoCapture:
      ucCapIdx: int32
      ucIndex: int32
      ucMyDepth: int32
      ucSavedCap: Span
      ucSavedStackEntry: Span
      ucFlags: RegexFlags
    of chUndoSubjectEnd:
      useAbsentPos: int
    of chWidenSubjectEnd:
      wsSavedEnd: int ## ``subjectEnd`` before narrowing; popping widens it back.
    of chAbsentFunc:
      afCont: ContId
      afFramesLen: int32
      afStart: int
      afTry: int ## Last tried end; next retry steps one back.
    of chUndoPos:
      upPos: int ## ``pos`` before a backreference advanced it.
    of chSubexpScope:
      ssCapIdx: int32 ## Referenced group (0-based), or -1 for ``\g<0>``.
      ssFlags: RegexFlags ## Flags before the called group's flags.
    of chLookbehindAlt:
      lbaNode {.cursor.}: Node ## Lookaround node under test.
      lbaNext: int32 ## Next alternative index to try.
      lbaCont: ContId
      lbaFramesLen: int32
      lbaTarget: int ## Position the lookbehind ends at (entry ``pos``).
      lbaSaved: SavedState ## Entry snapshot, replayed until exhausted.
      lbaLensOff: int32 ## Stack-length snapshot offset in `stackLensSaves`.
    of chUndoCallout:
      ucoNode {.cursor.}: Node
        ## Callout node whose counter was incremented (cursor; tree outlives match).
      ucoPrev: int
      ucoExisted: bool

  SavedState = object
    ## Rollback snapshot.  ``capOff`` is the capture vector's offset on
    ## ``MatchContext.capSaves``, so taking one is a bulk copy rather than an
    ## allocation.  Strictly LIFO: every ``save`` must release its slot before
    ## returning, via ``restore``, ``restoreKeepingCaptures`` or ``drop``
    ## (``rewind`` rolls back without releasing, to replay the snapshot).
    scalars: ScalarState
    capOff: int32

proc indexOfByte(s: string, start: int, b: uint8): int {.inline.} =
  ## Index of the first ``b`` at or after a non-negative ``start``, or -1.
  ## Goes through ``strutils.find``, which is libc's vectorized ``memchr``
  ## on the C backend and a byte loop everywhere else.
  if start >= s.len:
    -1
  else:
    find(s, char(b), start)

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
  ## Decode char at ``p``; false if truncated (nothing consumes it).
  decodeAt(toOpenArray(ctx.subject.data, 0, ctx.subjectEnd - 1), p, code, next)

proc nextScanPos(s: string, p: int): int {.inline.} =
  ## Next scan start after ``p`` via lead-byte length, clamped to end. The end
  ## itself is a start position (``\z``, ``$``, ``\b`` match there).
  min(p + encLen(s[p].uint8), s.len)

proc leftAdjustCharHead(s: string, p: int): int {.inline.} =
  ## Walk back to the nearest non-continuation byte (Oniguruma
  ## ``utf8_left_adjust_char_head``). Used by all backward walks.
  var q = p
  while q > 0 and (s[q].uint8 and 0xC0'u8) == 0x80'u8:
    dec q
  q

proc prevCharHead(s: string, p: int): int {.inline.} =
  ## Head of the char before ``p`` (backward scan step).
  if p <= 0:
    0
  else:
    leftAdjustCharHead(s, p - 1)

proc rightAdjustCharHead(s: string, p: int): int {.inline.} =
  ## Left-adjust, then step one char forward again (clamped to ``s.len``).
  let q = leftAdjustCharHead(s, p)
  if q < p:
    min(q + encLen(s[q].uint8), s.len)
  else:
    p

proc advanceChainTo(s: string, start, target: int, byteScan: bool): int {.inline.} =
  ## First scan position at/after ``target`` reachable from ``start``. Byte
  ## scans jump directly; char scans walk the ``encLen`` chain.
  if byteScan:
    return clamp(target, start, s.len)
  result = start
  while result < target and result < s.len:
    result = nextScanPos(s, result)

proc semiEndScanStart(s: string, regex: Regex, start: int): int =
  ## Forward-scan start for ``\Z``-anchored patterns (Oniguruma window:
  ## ``min_semi_end - dmax``, adjusted to a char head).
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

# Counters in this region are bounded by ``stepLimit`` / ``MaxStackBytes`` / the
# subject length, and ``lengthBounds`` guards overflow
# explicitly, so the checks would only cost the hot path instructions.
{.push overflowChecks: off.}

const CapSavesKeep = 4096 ## ``capSaves`` entries kept between searches (~64 KB).

const FramesKeep = 1600 ## ``frames`` entries kept between searches (~64 KB).

const ChoicesKeep = 768 ## ``choices`` entries kept between searches (~66 KB).

const RepPositionsKeep = 8192
  ## ``repPositions`` entries kept between searches (64 KB). Higher since one
  ## ``int`` per char of ``a*`` fills this buffer.

const ScratchQuietRuns = 16
  ## Small searches in a row before oversized buffers are released.

const TrackCallDepth = compileOption("stacktrace")
  ## Whether to also guard frame count. Debug builds abort uncatchably at
  ## ``nimCallDepthLimit`` calls, so bytes alone would let them overrun first.

const NimCallDepthLimit {.intdefine: "nimCallDepthLimit".} = 2000

const MaxNativeDepth = NimCallDepthLimit - 100
  ## Frame ceiling for ``TrackCallDepth``: 6 per ``runMachine`` entry plus
  ## ``chainDepth``. Over-approximates so Nim's abort never fires first.

template stackUsed(ctx: MatchContext): int =
  ## Stack bytes consumed since ``ctx.stackBase``.
  stackUsedFrom(ctx.stackBase)

template checkNativeDepth(ctx: MatchContext) =
  ## Raise ``RegexLimitError`` before Nim's uncatchable call-depth abort.
  ## Over-approximates held depth; checked at each entry and chain link.
  when TrackCallDepth:
    if ctx.callDepth * 6 + ctx.chainDepth > MaxNativeDepth:
      raise newException(RegexLimitError, "match call depth exceeded")

# Forward declarations
proc matchWithCont(ctx: MatchContext, node: Node, cont: ContId): bool
proc matchNodeRecursive(ctx: MatchContext, node: Node, cont: ContId): bool
proc matchSeqCont(ctx: MatchContext, parent: Node, idx: int, cont: ContId): bool
proc runContFromMachine(ctx: MatchContext, cont: ContId): bool
proc unwindAbsentFrames(ctx: MatchContext, base: int)
proc findAbsentPos(ctx: MatchContext, absentBody: Node, fromPos: int): int

proc runCont(ctx: MatchContext, cont: ContId): bool

proc pushChoice(ctx: MatchContext, choice: sink Choice) {.inline.} =
  ## Push a backtrack entry, growing only when full.
  if ctx.choicesLen >= ctx.choices.len:
    ctx.choices.setLen(max(16, ctx.choices.len * 2))
  ctx.choices[ctx.choicesLen] = choice
  inc ctx.choicesLen
  if ctx.choicesLen > ctx.choicesPeak:
    ctx.choicesPeak = ctx.choicesLen

proc pushRepPos(ctx: MatchContext, p: int) {.inline.} =
  ## Record one repetition end; popping is a length store.
  if ctx.repLen >= ctx.repPositions.len:
    ctx.repPositions.setLen(max(16, ctx.repPositions.len * 2))
  ctx.repPositions[ctx.repLen] = p
  inc ctx.repLen
  if ctx.repLen > ctx.repPeak:
    ctx.repPeak = ctx.repLen

template checkCont(ctx: MatchContext, id: ContId) =
  ## Bounds check for the explicit-length ``frames`` buffer. Dropped under danger.
  assert id < ctx.framesLen, "continuation outlives its frame"

proc pushFrame(ctx: MatchContext, frame: sink Frame): ContId {.inline.} =
  ## Push a frame and return its index.  The pusher must pop it
  ## (``ctx.framesLen = fid``) before returning to its caller.
  if ctx.framesLen >= ctx.frames.len:
    ctx.frames.setLen(max(16, ctx.frames.len * 2))
  result = ctx.framesLen.int32
  ctx.frames[ctx.framesLen] = frame
  inc ctx.framesLen

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

  # Walk consecutive absent markers iteratively so long marker runs do not
  # consume native stack where no guard observes them. Narrowed ends are kept
  # in ``ckRestoreSubjectEnd`` frames for explicit unwind.
  #
  # Serves the ``runCont`` path; the loop answers markers inline.
  let base = ctx.framesLen
  var i = idx
  # Head of the ``ckRestoreSubjectEnd`` chain for the tail walk.
  var tail = cont
  while true:
    if i >= nodes.len:
      # Run the chained tail through the loop, then unwind.
      let ok = runContFromMachine(ctx, tail)
      unwindAbsentFrames(ctx, base)
      return ok
    let node = nodes[i]
    if node.kind == nkAbsent and node.absentKind == abRange:
      # (?~|absent): narrow range to exclude absent.
      let rangeStart = ctx.pos
      let absentPos = findAbsentPos(ctx, node.absentBody, rangeStart)
      let savedEnd = ctx.subjectEnd
      ctx.subjectEnd = absentPos
      tail = pushFrame(
        ctx,
        Frame(
          kind: ckRestoreSubjectEnd,
          parent: tail,
          reSavedEnd: savedEnd,
          reAbsentPos: absentPos,
        ),
      )
      inc i
      continue
    if node.kind == nkAbsent and node.absentKind == abClear:
      # (?~|) or (?~): clear absent range limit.
      ctx.subjectEnd = ctx.subject.len
      inc i
      continue
    if i + 1 >= nodes.len:
      # Last child: its continuation *is* ``tail``, so skip the frame entirely.
      let ok = matchWithCont(ctx, nodes[i], tail)
      unwindAbsentFrames(ctx, base)
      return ok
    let fid = pushFrame(
      ctx, Frame(kind: ckSeqContinue, parent: tail, sNode: parent, sIdx: int32(i + 1))
    )
    let ok = matchWithCont(ctx, nodes[i], fid)
    unwindAbsentFrames(ctx, base)
    return ok

proc unwindAbsentFrames(ctx: MatchContext, base: int) =
  ## Pop frames pushed by ``matchSeqCont`` and restore narrowed subject ends.
  while ctx.framesLen > base:
    dec ctx.framesLen
    if ctx.frames[ctx.framesLen].kind == ckRestoreSubjectEnd:
      ctx.subjectEnd = ctx.frames[ctx.framesLen].reSavedEnd

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

const LiteralVariants = 2
  ## Ways one literal can match: direct compare plus ``(?i)`` multi-char fold.

proc literalAdvance(ctx: MatchContext, target: Rune, variant: int): int =
  ## End offset of the ``variant``-th way ``target`` matches at ``ctx.pos``,
  ## or -1. Leaves ``ctx.pos`` alone; caller keeps untried variants.
  let start = ctx.pos
  if start >= ctx.subjectEnd:
    return -1
  if rfIgnoreCase notin ctx.flags:
    return
      if variant == 0:
        matchBytes(ctx, target, start)
      else:
        -1
  var code: int32
  var next: int
  if not decodeChar(ctx, start, code, next):
    return -1
  if variant == 0:
    # Case-insensitive compare reads through class containers, so overlong
    # ASCII encodings still fail.
    let r = Rune(code)
    if codeIsClassifiable(code, next - start) and
        (r == target or caseInsensitiveMatch(r, target, ctx.flags)):
      return next
    return -1
  if variant != 1:
    return -1
  # Multi-char fold: pattern char folds to multiple chars (e.g., ß → ss)
  if rfIgnoreCaseAscii in ctx.flags and int32(target) > 127:
    return -1
  let fold = getMultiCharFold(target)
  if fold.len == 0:
    return -1
  var p = start
  for i in 0 ..< fold.len:
    if p >= ctx.subjectEnd:
      return -1
    var sc: int32
    var sn: int
    if not decodeChar(ctx, p, sc, sn) or not codeIsClassifiable(sc, sn - p) or
        not caseInsensitiveMatch(Rune(sc), fold.runes[i], ctx.flags):
      return -1
    p = sn
  p

const BulkCompareLen = 16
  ## Byte length from which a run goes through ``memcmp``; below it the call
  ## costs more than the compares it saves.

proc stringAdvance(ctx: MatchContext, node: Node): int =
  ## End offset of ``node``'s run of literals matched at ``ctx.pos``, or -1.
  ## Single parse, no variants. Leaves ``ctx.pos`` alone.
  if rfIgnoreCase notin ctx.flags:
    # Every character has one encoding here, so comparing the run's bytes is
    # the same test as comparing it character by character.
    let n = node.bytes.len
    if n == 0:
      return -1
    if ctx.pos + n > ctx.subjectEnd:
      return -1
    if n >= BulkCompareLen:
      if not equalMem(addr ctx.subject.data[ctx.pos], unsafeAddr node.bytes[0], n):
        return -1
    else:
      for i in 0 ..< n:
        if ctx.subject[ctx.pos + i] != node.bytes[i]:
          return -1
    return ctx.pos + n

  let runes {.cursor.} = node.runes
  if node.bytes.len == runes.len and ctx.pos + runes.len <= ctx.subjectEnd:
    # One byte per character: the run is pure ASCII, and no multi-character
    # fold starts from ASCII, so while the subject stays ASCII the two line up
    # byte for character.  A high byte can still match through a fold (ſ for
    # s), so it hands the run back to the general loop instead of rejecting.
    var k = 0
    while k < runes.len:
      let sb = uint8(ctx.subject[ctx.pos + k])
      if sb >= 0x80'u8:
        break
      if asciiFoldByte(sb) != uint8(node.foldedBytes[k]):
        return -1
      inc k
    if k == runes.len:
      return ctx.pos + runes.len

  var p = ctx.pos
  var i = 0
  while i < runes.len:
    if p >= ctx.subjectEnd:
      return -1
    let target = runes[i]
    let posBeforeSubjChar = p
    var code: int32
    var next: int
    if not decodeChar(ctx, p, code, next):
      return -1
    let r = Rune(code)
    let classifiable = codeIsClassifiable(code, next - p)
    p = next
    let posAfterSubjChar = next
    if classifiable and (r == target or caseInsensitiveMatch(r, target, ctx.flags)):
      inc i
      continue

    # Try forward multi-char fold: pattern char folds to multiple subject chars (e.g., ß → ss)
    if rfIgnoreCaseAscii notin ctx.flags or int32(target) <= 127:
      let fold = getMultiCharFold(target)
      if fold.len > 0:
        p = posBeforeSubjChar
        var matched = true
        for j in 0 ..< fold.len:
          if p >= ctx.subjectEnd:
            matched = false
            break
          var sc: int32
          var sn: int
          if not decodeChar(ctx, p, sc, sn) or not codeIsClassifiable(sc, sn - p) or
              not caseInsensitiveMatch(Rune(sc), fold.runes[j], ctx.flags):
            matched = false
            break
          p = sn
        if matched:
          inc i
          continue

    # Try reverse multi-char fold: subject char folds to consecutive pattern chars
    # e.g., subject "ß" matches pattern "ss" because ß full-folds to ss
    if rfIgnoreCaseAscii notin ctx.flags:
      let fold = getMultiCharFold(r)
      if fold.len > 0 and i + fold.len <= runes.len:
        var matched = true
        for j in 0 ..< fold.len:
          if not caseInsensitiveMatch(fold.runes[j], runes[i + j], ctx.flags):
            matched = false
            break
        if matched:
          p = posAfterSubjChar
          i += fold.len
          continue
    return -1
  p

proc charTypeAdvance(ctx: MatchContext, ct: CharTypeKind): int =
  ## End offset of ``ct`` matched at ``ctx.pos``, or -1. Single way only.
  ## Leaves ``ctx.pos`` alone.
  let start = ctx.pos
  if start >= ctx.subjectEnd:
    return -1
  # Grapheme cluster: \X or . in grapheme/word mode.  These work on byte
  # sequences rather than a single decoded character, so they run first.
  if ct == ctGraphemeCluster or
      (ct == ctDot and ctx.graphemeMode in {gmGrapheme, gmWord}):
    # A cluster still starts with a character, so a sequence truncated by the
    # end of the subject is no cluster either.
    var probe: int32
    var probeNext: int
    if not decodeChar(ctx, start, probe, probeNext):
      return -1
    if ct == ctDot:
      let isNewline = codeIsClassifiable(probe, probeNext - start) and probe == 0x0A
      if isNewline and rfMultiLine notin ctx.flags:
        return -1
    let clusterEnd =
      if ctx.graphemeMode == gmWord:
        nextWordSegmentEnd(ctx.subject.oa, start)
      else:
        nextGraphemeClusterEnd(ctx.subject.oa, start)
    return if clusterEnd > start: clusterEnd else: -1

  var code: int32
  var next: int
  if not decodeChar(ctx, start, code, next):
    return -1
  let classifiable = codeIsClassifiable(code, next - start)

  # Newline sequence: \R matches \r\n, \r, \n, \v, \f, or a Unicode line
  # separator.  It reads as a positive class over those code points, so an
  # unclassifiable character — an overlong "\xC0\x8A", a stray 0x85 byte —
  # matches none of them.
  if ct == ctNewlineSeq:
    if not classifiable:
      return -1
    if code == 0x0D:
      var e = next
      if e < ctx.subjectEnd and ctx.subject[e] == '\n':
        inc e
      return e
    elif code in [0x0A'i32, 0x0B, 0x0C, 0x85, 0x2028, 0x2029]:
      return next
    else:
      return -1

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
  if matched: next else: -1

proc anchorHolds(ctx: MatchContext, kind: AnchorKind): bool =
  ## Whether zero-width ``kind`` holds at ``ctx.pos``. Pure; ``akKeep`` effect
  ## belongs to the committing caller.
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

proc tryCaptureChangingMatch(ctx: MatchContext, body: Node): bool {.inline.} =
  ## Try ``body``, accepting only capture-changing matches. Drives zero-width
  ## quantifier subloops to alternate captures each iteration.
  let snapStart = ctx.captureSnapshots.len.int32
  for c in ctx.captures:
    ctx.captureSnapshots.add(c)
  let fid = pushFrame(
    ctx, Frame(kind: ckCapturesChanged, parent: TrueCont, ccSnapshotStart: snapStart)
  )
  result = matchWithCont(ctx, body, fid)
  ctx.framesLen = fid
  ctx.captureSnapshots.setLen(snapStart)

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
        # ASCII-only: the subject and the variant it folds to must both be
        # ASCII, so ``k`` never reaches U+212A and U+212A never reaches ``k``.
        #
        # Walk the variants rather than folding once.  A range is not a value
        # that can be folded alongside the subject the way [caseInsensitiveMatch]
        # folds both sides of a literal, and ``simpleFold`` maps toward one
        # case only -- testing it against the range's own endpoints answers
        # only for a range written in that case, so ``[a-z]`` would match ``Y``
        # while ``[A-Z]`` missed ``y``.
        if ri <= 127:
          for variant in caseFoldVariants(r):
            let vi = int32(variant)
            if vi <= 127 and vi >= lo and vi <= hi:
              return true
          false
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
    let asciiOnly = rfIgnoreCaseAscii in flags
    case atom.kind
    of ccPosix, ccNegPosix, ccCharType, ccUnicodeProp, ccNegUnicodeProp, ccNestedClass:
      # Check case-fold variants.  ASCII-only folding restricts both ends, not
      # just the subject: the subject is already known to be ASCII here, and a
      # variant that is not stays out, so ``k`` reaches ``K`` but never U+212A
      # and ``[[:^ascii:]]`` does not match it.
      for variant in caseFoldVariants(r):
        if variant == r or (asciiOnly and int32(variant) > 127):
          continue
        if matchCcAtom(variant, atom, flags):
          return true
    else:
      # ``ccLiteral`` and ``ccRange`` fold inside [matchCcAtom] itself.
      discard
  false

proc classHasByte(node: Node, b: uint8, flags: RegexFlags): bool =
  ## Whether one-byte char ``b`` is in the class byte set. Below U+0080 the
  ## member test answers; above only ranges crossing the ASCII boundary reach.
  if b < 0x80:
    if node.asciiSetOk and rfIgnoreCase notin flags:
      # Precomputed bitmap: exact below U+0080 as long as nothing folds.
      return b in node.asciiSet
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

proc classFoldsApply(ctx: MatchContext, node: Node): bool {.inline.} =
  ## Whether multi-char folds can apply: positive bracket class under ``(?i)``.
  rfIgnoreCase in ctx.flags and node.bracketClass and not node.negated

proc classFirstVariant(ctx: MatchContext, node: Node): int {.inline.} =
  ## First variant for ``classAdvance``: folds first, else plain match.
  if classFoldsApply(ctx, node): 0 else: MultiCharFolds.len

const ClassVariants = MultiCharFolds.len + 1 ## Fold variants plus the plain match.

proc classAdvance(ctx: MatchContext, node: Node, variant: int): int =
  ## End offset of the ``variant``-th way ``node`` matches, or -1.
  ## Leaves ``ctx.pos`` alone.
  let start = ctx.pos
  if start >= ctx.subjectEnd:
    return -1

  if variant < MultiCharFolds.len:
    # Multi-character fold expansion, e.g. (?i:[ß]) matching "ss".
    if not classFoldsApply(ctx, node):
      return -1
    let (srcCP, expCP, expLen) = MultiCharFolds[variant]
    let srcRune = Rune(srcCP)
    # Check if the source rune matches any atom in the class
    var atomMatch = false
    for atom in node.atoms:
      if matchCcAtomWithFold(srcRune, atom, ctx.flags):
        atomMatch = true
        break
    if not atomMatch:
      return -1
    # Check if the expansion matches at the current position (case-insensitively)
    var p = start
    for i in 0 ..< expLen:
      if p >= ctx.subjectEnd:
        return -1
      var subjRune: Rune
      nextCharAt(ctx.subject.oa, p, subjRune)
      let expRune = Rune(expCP[i])
      if subjRune != expRune and simpleFold(subjRune) != simpleFold(expRune):
        return -1
    return p

  var code: int32
  var next: int
  if not decodeChar(ctx, start, code, next):
    return -1

  # Classes split members by encoded length: one byte looks in the byte set,
  # longer ones in code-point ranges (nothing below U+0080). Overlong
  # encodings match nothing; negation applies after lookup.
  var anyMatch = false
  if next - start == 1:
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
  if matched: next else: -1

proc isSingleWayLeaf(ctx: MatchContext, node: Node): bool =
  ## Whether ``node`` matches at most one way here. Single-way bodies allow
  ## greedy repeats as a forward scan (one int per rep); they also leave
  ## nothing behind but ``pos`` (no captures, ``\K``, or flags).
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
    rfIgnoreCase notin ctx.flags or getMultiCharFold(r).len == 0
  of nkCharClass:
    not classFoldsApply(ctx, node)
  else:
    false

proc leafVariantAdvance(ctx: MatchContext, node: Node, variant: int): int {.inline.} =
  ## ``literalAdvance`` / ``classAdvance`` behind one signature, so a caller
  ## enumerating a leaf's ways does not have to branch on the node kind first.
  case node.kind
  of nkLiteral:
    literalAdvance(ctx, node.rune, variant)
  of nkEscapedLiteral:
    literalAdvance(ctx, node.escapedRune, variant)
  of nkCharClass:
    classAdvance(ctx, node, variant)
  else:
    -1

proc altBranchPossible(node: Node, i: int, b: uint8, hasByte: bool): bool {.inline.} =
  ## Whether alternative ``i`` can start on the byte in front of the matcher.
  ## ``altFirst`` is a superset of the bytes the branch can begin with, so a
  ## miss here is a branch that provably cannot match at this position; an
  ## alternative the analysis could not read carries ``fcNone`` and is always
  ## tried.  ``hasByte`` is false at the end of the subject, where a branch
  ## that must consume a byte cannot match either, but a zero-width one still
  ## can -- and a zero-width branch never yields a byte hint.
  case node.altFirst[i].kind
  of fcByte:
    hasByte and node.altFirst[i].byte == b
  of fcByteSet:
    hasByte and b in node.altFirst[i].bytes
  else:
    true

proc nextAltBranch(node: Node, start: int, b: uint8, hasByte: bool): int {.inline.} =
  ## First alternative at or after ``start`` that ``altBranchPossible``
  ## admits, or -1.  Callers hold the next *untried* index and run this again
  ## on every visit, so the test always sees the state at the moment it runs:
  ## ``subjectEnd`` can change while a branch executes (``(?~|)`` clears it
  ## with no undo), and a branch passed over while the end was narrow has to
  ## stay reachable once it widens.
  var i = start
  while i < node.alternatives.len:
    if altBranchPossible(node, i, b, hasByte):
      return i
    inc i
  -1

proc prevCharCode(s: openArray[char], pos: int): int32 =
  ## Code point ending just before ``pos``, or -1 at 0. Always defined for
  ## ``pos > 0``.
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

proc backrefEnd(ctx: MatchContext, capIdx: int, level: int): int =
  ## End position if capture `capIdx` matches here, else -1. Pure predicate
  ## shared by the loop and the recursive fallback.
  let cap = resolveCapture(ctx, capIdx, level)
  if cap.a < 0:
    return -1 # unset capture
  if rfIgnoreCase in ctx.flags:
    # Compare rune by rune with case fold. Also handle multi-character folds
    # (e.g. ß ↔ ss) symmetrically on both captured and subject sides.
    var sp = cap.a
    var mp = ctx.pos
    while sp < cap.b:
      if mp >= ctx.subjectEnd:
        return -1
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
      return -1
    return mp # use actual bytes consumed, not capture byte length
  else:
    let capLen = cap.b - cap.a
    if ctx.pos + capLen > ctx.subjectEnd:
      return -1
    for i in 0 ..< capLen:
      if ctx.subject[cap.a + i] != ctx.subject[ctx.pos + i]:
        return -1
    return ctx.pos + capLen

proc matchBackref(ctx: MatchContext, capIdx: int, cont: ContId, level: int = 0): bool =
  ## Recursive fallback only; the loop answers backrefs itself.
  let e = backrefEnd(ctx, capIdx, level)
  if e < 0:
    return false
  let savedPos = ctx.pos
  ctx.pos = e
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
  ctx.framesLen = fid
  ok

proc runCapture(ctx: MatchContext, contId: ContId): bool =
  ## Continuation for ``matchCapture``: write the capture span, chain to
  ## the parent continuation, and on failure restore the previous span.
  ctx.checkCont contId
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
  let trackStacks = ctx.trackCaptureStacks and myDepth >= 0
  if trackStacks:
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
    if trackStacks:
      ctx.captureStacks[index][myDepth] = savedStackEntry
  ok

proc endCheckFrame(targetPos: int): Frame {.inline.} =
  Frame(kind: ckEndCheckPos, parent: TrueCont, ecpTargetPos: targetPos)

proc lookbehindBodyMatches(
    ctx: MatchContext, body: Node, targetEnd: int, fbl: int
): bool =
  ## Whether ``body`` matches ending at ``targetEnd`` from ``fbl`` bytes
  ## before it. Restores ``ctx`` either way.
  let st = targetEnd - fbl
  if st < 0:
    return false
  let stackSnap = saveStackLens(ctx)
  let saved = save(ctx)
  ctx.pos = st
  let fid = pushFrame(ctx, endCheckFrame(targetEnd))
  let matched = matchWithCont(ctx, body, fid)
  ctx.framesLen = fid
  restore(ctx, saved)
  restoreStackLens(ctx, stackSnap)
  matched

proc boundsUsable(ctx: MatchContext, node: Node): bool {.inline.} =
  ## Whether ``node`` bounds were compiled under current flags/mode.
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

proc lookbehindVarHolds(ctx: MatchContext, node: Node, bodyLen: LenBounds): bool =
  ## Whether variable-length positive lookbehind matches ending at ``ctx.pos``.
  ## Scans shortest-first, commits to first match, takes no continuation.
  let targetEnd = ctx.pos
  let body = node.lookBody
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
    ctx.framesLen = fid
    if bodyMatch:
      restoreKeepingCaptures(ctx, saved)
      restoreStackLens(ctx, stackSnap)
      return true
    restore(ctx, saved)
    restoreStackLens(ctx, stackSnap)
    if startTry == 0:
      break
    startTry = prevCharStart(ctx.subject.oa, startTry)
  false

proc negLookbehindHolds(ctx: MatchContext, node: Node): bool =
  ## Whether negative lookbehind succeeds (body matches nowhere ending here).
  ## Takes no continuation; restores ``ctx`` either way.
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
          ctx.framesLen = fid
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
          ctx.framesLen = fid
          restore(ctx, saved)
          restoreStackLens(ctx, stackSnap)
          if matched:
            return false
          if startTry == 0:
            break
          startTry = prevCharStart(ctx.subject.oa, startTry)
    return true
  let bodyLen = ctx.bodyBounds(node)
  if bodyLen.fixedLen >= 0:
    # Fixed length: one starting position, so one attempt decides it.
    return not lookbehindBodyMatches(ctx, body, targetEnd, bodyLen.fixedLen)
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
    ctx.framesLen = fid
    restore(ctx, saved)
    restoreStackLens(ctx, stackSnap)
    if matched:
      return false
    if startTry == 0:
      break
    startTry = prevCharStart(ctx.subject.oa, startTry)
  true

type LookAltResult = enum
  ## Result of one `lookbehindAltNext` call.
  laFixed ## fixed alternative matched: run `lbaCont`
  laCommitted ## variable alternative matched and committed: run `lbaCont`
  laExhausted ## no alternative matched: keep failing

proc lookbehindAltNext(ctx: MatchContext, top: int): LookAltResult =
  ## Try remaining alternatives from `lbaNext` on. Fixed matches keep the
  ## entry for retry; variable matches commit and pop it; exhaustion restores.
  let node = ctx.choices[top].lbaNode
  let targetEnd = ctx.choices[top].lbaTarget
  var k = int(ctx.choices[top].lbaNext)
  while k < node.lookBody.alternatives.len:
    let alt = node.lookBody.alternatives[k]
    let altLen = ctx.altBounds(node, k, alt)
    let altFbl = altLen.fixedLen
    if altFbl >= 0:
      # Fixed alternative: single start position.
      let st = targetEnd - altFbl
      if st >= 0:
        let stackSnap = saveStackLens(ctx)
        let saved = save(ctx)
        ctx.pos = st
        let fid = pushFrame(ctx, endCheckFrame(targetEnd))
        let bodyMatch = matchWithCont(ctx, alt, fid)
        ctx.framesLen = fid
        if bodyMatch:
          # Keep captures; retry replays the entry snapshot.
          restoreScalars(ctx, saved.scalars)
          restoreStackLens(ctx, stackSnap)
          drop(ctx, saved)
          ctx.choices[top].lbaNext = int32(k + 1)
          return laFixed
        restore(ctx, saved)
        restoreStackLens(ctx, stackSnap)
    else:
      # Variable alternative: shortest-first scan, commit on first match.
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
        ctx.framesLen = fid
        if bodyMatch:
          restoreKeepingCaptures(ctx, saved)
          restoreStackLens(ctx, stackSnap)
          # Commit with shortest priority; pop entry.
          ctx.capSaves.setLen(ctx.choices[top].lbaSaved.capOff)
          ctx.stackLensSaves.setLen(int(ctx.choices[top].lbaLensOff))
          ctx.choicesLen = top
          return laCommitted
        restore(ctx, saved)
        restoreStackLens(ctx, stackSnap)
        if startTry == 0:
          break
        startTry = prevCharStart(ctx.subject.oa, startTry)
    inc k
  # Exhausted: restore entry state and release slots.
  rewind(ctx, ctx.choices[top].lbaSaved)
  restoreStackLens(ctx, @(ctx.stackLensSaves[int(ctx.choices[top].lbaLensOff)]))
  ctx.capSaves.setLen(ctx.choices[top].lbaSaved.capOff)
  ctx.stackLensSaves.setLen(int(ctx.choices[top].lbaLensOff))
  ctx.choicesLen = top
  laExhausted

proc findAbsentPos(ctx: MatchContext, absentBody: Node, fromPos: int): int =
  ## First pos at/after `fromPos` where `absentBody` matches, else
  ## `subjectEnd`. Closed sub-matches only; restores `pos`.
  result = ctx.subjectEnd
  let entryPos = ctx.pos
  var checkPos = fromPos
  while checkPos < ctx.subjectEnd:
    let saved = save(ctx)
    ctx.pos = checkPos
    if matchWithCont(ctx, absentBody, TrueCont):
      result = checkPos
      restore(ctx, saved)
      break
    restore(ctx, saved)
    if checkPos >= ctx.subjectEnd:
      break
    var r: Rune
    nextCharAt(ctx.subject.oa, checkPos, r)
  ctx.pos = entryPos

proc matchAbsent(ctx: MatchContext, node: Node, cont: ContId): bool =
  ## Recursive fallback only; the loop answers absent shapes itself.
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
      ctx.framesLen = fid
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
    ctx.framesLen = fid
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

proc condHolds(ctx: MatchContext, node: Node): bool =
  ## Whether the conditional holds here. Closed sub-matches only.
  case node.condKind
  of ckBackref:
    let capIdx = node.condRefIndex # 1-indexed capture
    if capIdx >= 0 and capIdx < ctx.captures.len:
      return ctx.captures[capIdx].a >= 0
    return false
  of ckNamedRef:
    # Check ALL capture groups with matching name
    for (name, i) in ctx.regex[].namedCaptures:
      if name == node.condRefName:
        let capIdx = i + 1
        if capIdx < ctx.captures.len and ctx.captures[capIdx].a >= 0:
          return true
    return false
  of ckAlwaysFalse:
    return false
  of ckAlwaysTrue:
    return true
  of ckRegexCond:
    # Match the condition regex at current position (consuming)
    if node.condBody != nil:
      if node.condBody.kind == nkLookaround and node.condBody.lookKind == lkNegAhead:
        # For negative lookaround conditions, evaluate the body directly.
        # When the body matches (negative lookaround fails -> condition
        # false), still preserve captures from the body match.
        let stackSnap = saveStackLens(ctx)
        let saved = save(ctx)
        let bodyMatch = matchWithCont(ctx, node.condBody.lookBody, TrueCont)
        if bodyMatch:
          result = false # negative lookaround failed, preserve captures
          restoreKeepingCaptures(ctx, saved)
        else:
          result = true # negative lookaround succeeded
          restore(ctx, saved)
        restoreStackLens(ctx, stackSnap)
      else:
        let stackSnap = saveStackLens(ctx)
        let saved = save(ctx)
        if matchWithCont(ctx, node.condBody, TrueCont):
          # Condition matched -- pos is advanced past it
          result = true
          drop(ctx, saved)
        else:
          result = false
          restore(ctx, saved)
          restoreStackLens(ctx, stackSnap)

proc matchNodeRecursive(ctx: MatchContext, node: Node, cont: ContId): bool =
  ## Recursive fallback only; the loop answers every node itself. Each arm
  ## takes the real continuation, so it holds a native frame until the match
  ## resolves. Guarded in ``runMachine``, the single native re-entry point.
  inc ctx.steps
  if ctx.steps > ctx.stepLimit:
    raise newException(RegexLimitError, "match step limit exceeded")
  case node.kind
  of nkBackreference:
    # Loop answers these itself.
    matchBackref(ctx, node.backrefIndex, cont, node.backrefLevel)
  of nkNamedBackref:
    # Loop answers these itself.
    var anyFound = false
    for (name, i) in ctx.regex[].namedCaptures:
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
  of nkSubexpCall:
    # Loop answers these itself.
    var body: Node = nil
    var captureIdx = -1 # 0-based index for matchCapture
    if node.callIndex == 0:
      # \g<0> = entire pattern recursion
      body = ctx.regex[].ast
    elif node.callIndex > 0:
      let idx = node.callIndex - 1 # 0-based in groupBodies
      if idx < ctx.regex[].groupBodies.len:
        body = ctx.regex[].groupBodies[idx]
      captureIdx = idx
    elif node.callName.len > 0:
      for (name, i) in ctx.regex[].namedCaptures:
        if name == node.callName:
          if i < ctx.regex[].groupBodies.len:
            body = ctx.regex[].groupBodies[i]
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
    if captureIdx >= 0 and captureIdx < ctx.regex[].groupFlags.len:
      ctx.flags = ctx.regex[].groupFlags[captureIdx]
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
    # Loop answers these itself.
    let condMet = condHolds(ctx, node)
    if condMet:
      matchWithCont(ctx, node.condYes, cont)
    elif node.condNo != nil:
      matchWithCont(ctx, node.condNo, cont)
    elif node.condKind in {ckBackref, ckNamedRef} and (
      node.condYes == nil or
      (node.condYes.kind == nkConcat and node.condYes.children.len == 0)
    ):
      # Oniguruma: false backref cond with empty yes-branch fails.
      false
    else:
      # Other false conds without else-branch are skipped.
      runCont(ctx, cont)
  of nkAbsent:
    matchAbsent(ctx, node, cont)
  of nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    # Fallback only: the loop answers these itself (see the `mMatch` arms),
    # so this proc no longer receives them from `runMachine`. Kept so a
    # direct caller still gets the old recursive semantics instead of the
    # `raiseAssert` below.
    case node.kind
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
    else:
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
  else:
    raiseAssert "runMachine drives this node kind itself: " & $node.kind

proc matchNode(ctx: MatchContext, node: Node): bool =
  matchWithCont(ctx, node, TrueCont)

proc writeFoundCopy(m: var Match, captures: seq[Span]) {.inline.}

proc runCont(ctx: MatchContext, cont: ContId): bool =
  ## Walk the continuation chain starting at ``cont``: each ``Frame``
  ## holds one step of post-match work plus a ``parent`` link.
  ## ``TrueCont`` (-1) means "no further work, succeed".
  if cont < 0:
    return true
  ctx.checkCont cont
  case ctx.frames[cont].kind
  of ckSeqContinue:
    let parentNode = ctx.frames[cont].sNode
    let idx = int(ctx.frames[cont].sIdx)
    let parent = ctx.frames[cont].parent
    matchSeqCont(ctx, parentNode, idx, parent)
  of ckCapture:
    # Two frames: ``runCapture`` plus its inner ``runCont``; exact count.
    inc ctx.chainDepth, 2
    checkNativeDepth(ctx)
    let capOk = runCapture(ctx, cont)
    dec ctx.chainDepth, 2
    capOk
  of ckGroup:
    let savedFlags = ctx.frames[cont].grpSavedFlags
    let parent = ctx.frames[cont].parent
    let modFlags = ctx.flags
    ctx.flags = savedFlags
    inc ctx.chainDepth
    checkNativeDepth(ctx)
    let ok = runCont(ctx, parent)
    dec ctx.chainDepth
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
    inc ctx.chainDepth
    checkNativeDepth(ctx)
    let ok = runCont(ctx, parent)
    dec ctx.chainDepth
    if not ok:
      ctx.flags = modFlags
      ctx.graphemeMode = modGM
    ok
  of ckQuantGreedyMore, ckQuantLazyMore:
    # Repetitions belong to the loop; hand the chain back instead of recursing.
    runContFromMachine(ctx, cont)
  of ckRestoreSubjectEnd:
    let savedEnd = ctx.frames[cont].reSavedEnd
    let absentPos = ctx.frames[cont].reAbsentPos
    let parent = ctx.frames[cont].parent
    ctx.subjectEnd = savedEnd
    inc ctx.chainDepth
    checkNativeDepth(ctx)
    let ok = runCont(ctx, parent)
    dec ctx.chainDepth
    if not ok:
      ctx.subjectEnd = absentPos
    ok
  of ckEndCheckPos:
    ctx.pos == ctx.frames[cont].ecpTargetPos
  of ckNonZeroPos:
    ctx.pos > ctx.frames[cont].nzpStartPos
  of ckCapturesChanged:
    # ``captures.len`` is fixed per regex, so snapshot length always matches.
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

type MachineMode = enum
  ## What the matcher loop does on its next turn.
  mMatch ## match ``node`` against the subject, then run ``cont``
  mSeq ## resume an ``nkConcat`` at ``seqIdx``
  mCont ## run the continuation chain from ``cont``
  mFail ## backtrack into the most recent choice

proc runMachine(
    ctx: MatchContext, startNode: Node, startCont: ContId, startMode = mMatch
): bool =
  ## Loop over an explicit backtrack stack instead of recursing. Both success
  ## (``frames``) and failure (``choices``) continuations are heap data, so
  ## native stack never grows with the subject. Every native re-entry passes
  ## through here via closed sub-matches, so the guard below bounds all
  ## matcher-owned stack. Leaf sub-matches never reach here.
  inc ctx.callDepth
  # Sample every level to depth 16, then every 16th (see ``MaxStackBytes``
  # for the overshoot margin this implies).
  if ctx.callDepth <= StackProbeInterval or
      (ctx.callDepth and (StackProbeInterval - 1)) == 0:
    if stackUsed(ctx) > MaxStackBytes:
      raise newException(RegexLimitError, "match stack budget exceeded")
  checkNativeDepth(ctx)

  let framesBase = ctx.framesLen.int32
  let capBase = ctx.capSaves.len.int32
  let repBase = ctx.repLen
  let choiceBase = ctx.choicesLen
  let stackLensBase = ctx.stackLensSaves.len

  var mode = startMode
  var node = startNode
  var cont = startCont
  var seqNode: Node = nil
  var seqIdx = 0

  template releaseToBase(): untyped =
    ## Trim stacks to entry lengths. ``capSaves`` is guarded since the common
    ## case pushed nothing and ``setLen`` walks destructors.
    ctx.framesLen = framesBase
    if ctx.capSaves.len > capBase:
      ctx.capSaves.setLen(capBase)
    ctx.repLen = repBase
    ctx.choicesLen = choiceBase
    if ctx.stackLensSaves.len > stackLensBase:
      ctx.stackLensSaves.setLen(stackLensBase)

  template unwindScopesToBase(): untyped =
    ## Exit subexpression scopes without restoring flags; depths must not leak.
    for i in choiceBase ..< ctx.choicesLen:
      if ctx.choices[i].kind == chSubexpScope:
        dec ctx.recursionDepth
        let sci = int(ctx.choices[i].ssCapIdx)
        if sci >= 0 and sci < ctx.groupRecursionDepth.len:
          dec ctx.groupRecursionDepth[sci]

  template succeed(): untyped =
    ## Downstream match succeeded; nothing below can be re-driven.
    unwindScopesToBase()
    releaseToBase()
    dec ctx.callDepth
    return true

  template delegate(call: untyped): untyped =
    ## Run a loop-external construct with the real continuation.
    if call:
      succeed()
    mode = mFail

  template startGreedy(body: Node, minRep, maxRep, count: int32, c: ContId): untyped =
    ## Greedy: try one more rep, leaving "stop and run cont" behind.
    ctx.pushChoice Choice(
      kind: chQuantGreedy,
      qcBody: body,
      qcMinRep: minRep,
      qcMaxRep: maxRep,
      qcCount: count,
      qcCont: c,
      qcFramesLen: ctx.framesLen.int32,
      qcPhase: 0,
      qcSaved: save(ctx),
    )
    if maxRep < 0 or count < maxRep:
      cont = pushFrame(
        ctx,
        Frame(
          kind: ckQuantGreedyMore,
          parent: c,
          qBody: body,
          qMinRep: minRep,
          qMaxRep: maxRep,
          qCount: count,
          qSavedPos: ctx.pos,
        ),
      )
      node = body
      mode = mMatch
    else:
      mode = mFail

  template startLazy(body: Node, minRep, maxRep, count: int32, c: ContId): untyped =
    ## Lazy: run cont first, leaving "repeat once more" behind.
    ctx.pushChoice Choice(
      kind: chQuantLazy,
      qcBody: body,
      qcMinRep: minRep,
      qcMaxRep: maxRep,
      qcCount: count,
      qcCont: c,
      qcFramesLen: ctx.framesLen.int32,
      qcPhase: 0,
      qcSaved: save(ctx),
    )
    if count >= minRep:
      cont = c
      mode = mCont
    else:
      mode = mFail

  while true:
    case mode
    of mMatch:
      inc ctx.steps
      if ctx.steps > ctx.stepLimit:
        raise newException(RegexLimitError, "match step limit exceeded")
      case node.kind
      of nkLiteral, nkEscapedLiteral, nkCharClass:
        let firstVariant =
          if node.kind == nkCharClass:
            classFirstVariant(ctx, node)
          else:
            0
        let lastVariant =
          if node.kind == nkCharClass: ClassVariants else: LiteralVariants
        var v = firstVariant
        var e = -1
        while v < lastVariant:
          e = leafVariantAdvance(ctx, node, v)
          if e >= 0:
            break
          inc v
        if e < 0:
          mode = mFail
        else:
          # Single-way leaf has no second variant; skip the choice entry.
          if v + 1 < lastVariant and not isSingleWayLeaf(ctx, node):
            ctx.pushChoice Choice(
              kind: chLeafVariant,
              lNode: node,
              lVariant: int32(v + 1),
              lCont: cont,
              lFramesLen: ctx.framesLen.int32,
              lPos: ctx.pos,
            )
          ctx.pos = e
          mode = mCont
      of nkString:
        let e = stringAdvance(ctx, node)
        if e < 0:
          mode = mFail
        else:
          ctx.pos = e
          mode = mCont
      of nkCharType:
        let e = charTypeAdvance(ctx, node.charType)
        if e < 0:
          mode = mFail
        else:
          ctx.pos = e
          mode = mCont
      of nkAnchor:
        case node.anchor
        of akWordBoundary:
          mode = if matchWordBoundary(ctx): mCont else: mFail
        of akNotWordBoundary:
          mode = if matchWordBoundary(ctx): mFail else: mCont
        else:
          if anchorHolds(ctx, node.anchor):
            if node.anchor == akKeep:
              ctx.keepStart = ctx.pos
            mode = mCont
          else:
            mode = mFail
      of nkConcat:
        seqNode = node
        seqIdx = 0
        mode = mSeq
      of nkAlternation:
        if node.alternatives.len == 0:
          mode = mFail
        elif node.altFirst.len != node.alternatives.len:
          # No usable hints here: the untouched path, which reads no subject
          # byte and tests nothing.  ``annotateTree`` leaves ``altFirst``
          # empty both for an alternation it never reached and for one whose
          # branches share a single hint, where a test could never pass over
          # anything.
          if node.alternatives.len > 1:
            # Save pos, captures, keepStart — but NOT flags.
            # Isolated flag groups (?i) extend across alternation branches.
            ctx.pushChoice Choice(
              kind: chAlt,
              aNode: node,
              aIdx: 1,
              aCont: cont,
              aFramesLen: ctx.framesLen.int32,
              aCapOff: pushCaptures(ctx),
              aPos: ctx.pos,
              aKeepStart: ctx.keepStart,
            )
          node = node.alternatives[0]
          mode = mMatch
        else:
          let hasByte = ctx.pos < ctx.subjectEnd
          let b =
            if hasByte:
              ctx.subject[ctx.pos].uint8
            else:
              0'u8
          let first = nextAltBranch(node, 0, b, hasByte)
          if first < 0:
            # Every branch was passed over, so the alternation cannot match
            # here at all -- the whole point of carrying the hints.
            mode = mFail
          else:
            if first + 1 < node.alternatives.len:
              # The stored index is the next *untried* branch, not the next
              # one the hints admitted for this state.  The filter is re-run
              # on every backtrack, so a branch it passes over here is not
              # passed over for good.
              ctx.pushChoice Choice(
                kind: chAltHinted,
                aNode: node,
                aIdx: int32(first + 1),
                aCont: cont,
                aFramesLen: ctx.framesLen.int32,
                aCapOff: pushCaptures(ctx),
                aPos: ctx.pos,
                aKeepStart: ctx.keepStart,
              )
            node = node.alternatives[first]
            mode = mMatch
      of nkGroup:
        # Groups save/restore flags — isolated flag groups inside don't leak out
        ctx.pushChoice Choice(kind: chUndoFlags, ufFlags: ctx.flags)
        cont =
          pushFrame(ctx, Frame(kind: ckGroup, parent: cont, grpSavedFlags: ctx.flags))
        node = node.groupBody
        mode = mMatch
      of nkFlagGroup:
        if node.flagBody == nil:
          ctx.flags = ctx.flags + node.flagsOn - node.flagsOff
          if node.graphemeMode != gmNone:
            ctx.graphemeMode = node.graphemeMode
          mode = mCont
        else:
          let savedFlags = ctx.flags
          let savedGM = ctx.graphemeMode
          ctx.pushChoice Choice(kind: chUndoFlagsGM, ugFlags: savedFlags, ugGM: savedGM)
          ctx.flags = ctx.flags + node.flagsOn - node.flagsOff
          if node.graphemeMode != gmNone:
            ctx.graphemeMode = node.graphemeMode
          cont = pushFrame(
            ctx,
            Frame(
              kind: ckFlagGroup,
              parent: cont,
              fgSavedFlags: savedFlags,
              fgSavedGM: savedGM,
            ),
          )
          node = node.flagBody
          mode = mMatch
      of nkCapture, nkNamedCapture:
        let index =
          if node.kind == nkCapture: node.captureIndex else: node.namedCaptureIndex
        let body =
          if node.kind == nkCapture: node.captureBody else: node.namedCaptureBody
        ctx.pushChoice Choice(kind: chUndoFlags, ufFlags: ctx.flags)
        # Capture recursion depth at entry time (before continuations modify it)
        let myDepth =
          if index < ctx.groupRecursionDepth.len:
            ctx.groupRecursionDepth[index]
          else:
            -1
        cont = pushFrame(
          ctx,
          Frame(
            kind: ckCapture,
            parent: cont,
            cCapIdx: int32(index + 1),
            cIndex: int32(index),
            cMyDepth: int32(myDepth),
            cStartPos: ctx.pos,
            cSavedFlags: ctx.flags,
          ),
        )
        node = body
        mode = mMatch
      of nkQuantifier:
        # Oniguruma: {n,m} with n > m means possessive {0, max(n,m)}.
        var qmin = node.quantMin
        var qmax = node.quantMax
        var qkind = node.quantKind
        if qmax >= 0 and qmin > qmax:
          swap(qmin, qmax)
          qkind = qkPossessive
        case qkind
        of qkGreedy:
          let body = node.quantBody
          if ctx.isSingleWayLeaf(body):
            # Single-way body: forward scan, one int per rep for backtracking.
            let scalars = saveScalars(ctx)
            let posOff = ctx.repLen.int32
            var count = 0'i32
            while qmax < 0 or count < int32(qmax):
              let before = ctx.pos
              if not matchWithCont(ctx, body, TrueCont):
                ctx.pos = before
                break
              if ctx.pos == before:
                break # zero-width: a single-way leaf cannot vary, so stop
              ctx.pushRepPos ctx.pos
              inc count
            if count < int32(qmin):
              restoreScalars(ctx, scalars)
              ctx.repLen = posOff
              mode = mFail
            else:
              ctx.pushChoice Choice(
                kind: chSimpleRepeat,
                srCont: cont,
                srFramesLen: ctx.framesLen.int32,
                srMinRep: int32(qmin),
                srCount: count,
                srPosOff: posOff,
                srScalars: scalars,
              )
              mode = mCont
          else:
            startGreedy(body, int32(qmin), int32(qmax), 0, cont)
        of qkLazy:
          startLazy(node.quantBody, int32(qmin), int32(qmax), 0, cont)
        of qkPossessive:
          # Possessive: greedy with no count backtracking; only a rollback for
          # continuation failure. Pure bodies need scalars only.
          let body = node.quantBody
          let savedScalars = saveScalars(ctx)
          var count = 0
          if not node.quantBodyPure:
            # Full rollback plus one scratch slot reused in place.
            let savedCapOff = pushCaptures(ctx)
            let attemptOff = pushCaptures(ctx)
            let n = ctx.captures.len
            while qmax < 0 or count < qmax:
              # Body may still move scalars/captures on partial failure.
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
            if count >= qmin:
              ctx.pushChoice Choice(
                kind: chUndoState,
                usFramesLen: ctx.framesLen.int32,
                usSaved: SavedState(scalars: savedScalars, capOff: savedCapOff),
              )
              mode = mCont
            else:
              # The successful repetitions kept no snapshot of their own.
              restoreScalars(ctx, savedScalars)
              popCapturesTo(ctx, savedCapOff)
              mode = mFail
          else:
            # Pure body: scalar-only rollback, no side stack.
            while qmax < 0 or count < qmax:
              let attemptPos = ctx.pos
              if not matchWithCont(ctx, body, TrueCont):
                ctx.pos = attemptPos
                break
              count += 1
              if ctx.pos == attemptPos:
                break # zero-width: count as one rep, then stop
            if count >= qmin:
              ctx.pushChoice Choice(
                kind: chUndoScalars,
                uzFramesLen: ctx.framesLen.int32,
                uzScalars: savedScalars,
              )
              mode = mCont
            else:
              restoreScalars(ctx, savedScalars)
              mode = mFail
      of nkAtomicGroup:
        # Atomic commits to first match; only a rollback on continuation failure.
        let saved = save(ctx)
        if matchWithCont(ctx, node.atomicBody, TrueCont):
          ctx.pushChoice Choice(
            kind: chUndoState, usFramesLen: ctx.framesLen.int32, usSaved: saved
          )
          mode = mCont
        else:
          restore(ctx, saved)
          mode = mFail
      of nkLookaround:
        # Lookarounds commit to the first answer; no choice point, no extra
        # rollback. Alternation lookbehind retries via ``chLookbehindAlt``.
        case node.lookKind
        of lkAhead:
          let stackSnap = saveStackLens(ctx)
          let saved = save(ctx)
          if matchWithCont(ctx, node.lookBody, TrueCont):
            # Keep the captures the lookahead body made.
            restoreKeepingCaptures(ctx, saved)
            restoreStackLens(ctx, stackSnap)
            mode = mCont
          else:
            restore(ctx, saved)
            restoreStackLens(ctx, stackSnap)
            mode = mFail
        of lkNegAhead:
          let stackSnap = saveStackLens(ctx)
          let saved = save(ctx)
          let bodyMatch = matchWithCont(ctx, node.lookBody, TrueCont)
          restore(ctx, saved)
          restoreStackLens(ctx, stackSnap)
          mode = if bodyMatch: mFail else: mCont
        of lkBehind:
          # Alternation retries later fixed alternatives via heap entry; other
          # shapes commit to the first match.
          let isAlt = node.lookBody.kind == nkAlternation
          let bodyLen =
            if isAlt:
              LenBounds(fixedLen: -1, maxLen: -1)
            else:
              ctx.bodyBounds(node)
          let fbl = bodyLen.fixedLen
          if isAlt:
            let entrySaved = save(ctx)
            let entryLensOff = ctx.stackLensSaves.len
            ctx.stackLensSaves.add(saveStackLens(ctx))
            ctx.pushChoice Choice(
              kind: chLookbehindAlt,
              lbaNode: node,
              lbaNext: 0,
              lbaCont: cont,
              lbaFramesLen: ctx.framesLen.int32,
              lbaTarget: ctx.pos,
              lbaSaved: entrySaved,
              lbaLensOff: int32(entryLensOff),
            )
            case lookbehindAltNext(ctx, ctx.choicesLen - 1)
            of laFixed, laCommitted:
              mode = mCont
            of laExhausted:
              mode = mFail
          elif fbl < 0:
            mode = if lookbehindVarHolds(ctx, node, bodyLen): mCont else: mFail
          elif ctx.pos - fbl < 0:
            mode = mFail
          else:
            # Fixed-length lookbehind: only one starting position to try.
            let targetEnd = ctx.pos
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            ctx.pos = targetEnd - fbl
            let fid = pushFrame(ctx, endCheckFrame(targetEnd))
            let bodyMatch = matchWithCont(ctx, node.lookBody, fid)
            ctx.framesLen = fid
            if bodyMatch:
              restoreKeepingCaptures(ctx, saved)
              restoreStackLens(ctx, stackSnap)
              mode = mCont
            else:
              restore(ctx, saved)
              restoreStackLens(ctx, stackSnap)
              mode = mFail
        of lkNegBehind:
          # Negative lookbehind keeps nothing; single predicate.
          mode = if negLookbehindHolds(ctx, node): mCont else: mFail
      of nkCalloutMax:
        # Zero-width counter gate; undo entry rolls back the increment.
        let cur = ctx.calloutCounters.getOrDefault(node.maxTag, 0)
        if cur >= node.maxCount:
          mode = mFail
        else:
          ctx.pushChoice Choice(
            kind: chUndoCallout,
            ucoNode: node,
            ucoPrev: cur,
            ucoExisted: ctx.calloutCounters.hasKey(node.maxTag),
          )
          ctx.calloutCounters[node.maxTag] = cur + 1
          mode = mCont
      of nkCalloutCount:
        # Same as MAX without the limit.
        let cur = ctx.calloutCounters.getOrDefault(node.countTag, 0)
        ctx.pushChoice Choice(
          kind: chUndoCallout,
          ucoNode: node,
          ucoPrev: cur,
          ucoExisted: ctx.calloutCounters.hasKey(node.countTag),
        )
        ctx.calloutCounters[node.countTag] = cur + 1
        mode = mCont
      of nkCalloutCmp:
        # Pure counter predicate; no state or frame.
        let left = ctx.calloutCounters.getOrDefault(node.cmpLeft, 0)
        let right = ctx.calloutCounters.getOrDefault(node.cmpRight, 0)
        let holds =
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
        mode = if holds: mCont else: mFail
      of nkConditional:
        # Evaluate cond via closed sub-matches, then run the taken branch.
        let condMet = condHolds(ctx, node)
        if condMet:
          node = node.condYes
          mode = mMatch
        elif node.condNo != nil:
          node = node.condNo
          mode = mMatch
        elif node.condKind in {ckBackref, ckNamedRef} and (
          node.condYes == nil or
          (node.condYes.kind == nkConcat and node.condYes.children.len == 0)
        ):
          # False backref cond with empty yes-branch fails (Oniguruma rule).
          mode = mFail
        else:
          # Other false conds without else-branch are skipped.
          mode = mCont
      of nkAbsent:
        # Absent scans run as closed sub-matches; heap entries mirror tails.
        case node.absentKind
        of abClear:
          # (?~) or (?~|): always empty; no undo.
          ctx.subjectEnd = ctx.subject.len
          mode = mCont
        of abRange:
          # (?~|absent): narrow range, widen on failure.
          let rangeStart = ctx.pos
          let absentPos = findAbsentPos(ctx, node.absentBody, rangeStart)
          let savedEnd = ctx.subjectEnd
          ctx.subjectEnd = absentPos
          ctx.pushChoice Choice(kind: chWidenSubjectEnd, wsSavedEnd: savedEnd)
          mode = mCont
        of abExpression:
          # (?~|absent|expr): match expr narrowed, widen after.
          let startPos = ctx.pos
          let absentPos = findAbsentPos(ctx, node.absentBody, startPos)
          let savedEnd = ctx.subjectEnd
          ctx.subjectEnd = absentPos
          ctx.pushChoice Choice(kind: chWidenSubjectEnd, wsSavedEnd: savedEnd)
          cont = pushFrame(
            ctx,
            Frame(
              kind: ckRestoreSubjectEnd,
              parent: cont,
              reSavedEnd: savedEnd,
              reAbsentPos: absentPos,
            ),
          )
          node = node.absentExpr
          mode = mMatch
        of abFunction:
          # (?~pattern): longest non-containing text, then shorter.
          let startPos = ctx.pos
          var firstAbsentPos = ctx.subjectEnd
          var checkPos = startPos
          while checkPos < ctx.subjectEnd:
            let saved = save(ctx)
            ctx.pos = checkPos
            let fid = pushFrame(
              ctx, Frame(kind: ckNonZeroPos, parent: TrueCont, nzpStartPos: checkPos)
            )
            let bodyMatch = matchWithCont(ctx, node.absentBody, fid)
            ctx.framesLen = fid
            if bodyMatch:
              firstAbsentPos = checkPos
              restore(ctx, saved)
              break
            restore(ctx, saved)
            var r: Rune
            nextCharAt(ctx.subject.oa, checkPos, r)
          ctx.pushChoice Choice(
            kind: chAbsentFunc,
            afCont: cont,
            afFramesLen: ctx.framesLen.int32,
            afStart: startPos,
            afTry: firstAbsentPos,
          )
          ctx.pos = firstAbsentPos
          mode = mCont
      of nkBackreference:
        # Pure predicate plus position undo; no native frame.
        let e = backrefEnd(ctx, node.backrefIndex, node.backrefLevel)
        if e < 0:
          mode = mFail
        else:
          ctx.pushChoice Choice(kind: chUndoPos, upPos: ctx.pos)
          ctx.pos = e
          mode = mCont
      of nkNamedBackref:
        # First same-named group that matches wins.
        var e = -1
        for (name, i) in ctx.regex[].namedCaptures:
          if name == node.backrefName:
            e = backrefEnd(ctx, i + 1, node.namedBackrefLevel)
            if e >= 0:
              break
        if e < 0:
          mode = mFail
        else:
          ctx.pushChoice Choice(kind: chUndoPos, upPos: ctx.pos)
          ctx.pos = e
          mode = mCont
      of nkSubexpCall:
        # Run the referenced body as the loop's next turn under a heap scope:
        # the capture frame is the existing `ckCapture` machinery, and one
        # `chSubexpScope` entry owns the recursion depths and the flag switch
        # a native frame used to hold until the whole match resolved.
        var body: Node = nil
        var captureIdx = -1
        if node.callIndex == 0:
          body = ctx.regex[].ast
        elif node.callIndex > 0:
          let idx = node.callIndex - 1
          if idx < ctx.regex[].groupBodies.len:
            body = ctx.regex[].groupBodies[idx]
          captureIdx = idx
        elif node.callName.len > 0:
          for (name, i) in ctx.regex[].namedCaptures:
            if name == node.callName:
              if i < ctx.regex[].groupBodies.len:
                body = ctx.regex[].groupBodies[i]
              captureIdx = i
              break
        if body == nil:
          mode = mFail
        elif ctx.recursionDepth + 1 > ctx.maxRecursionDepth:
          mode = mFail # too deep recursion — treat as no match
        else:
          let savedFlags = ctx.flags
          if captureIdx >= 0 and captureIdx < ctx.regex[].groupFlags.len:
            ctx.flags = ctx.regex[].groupFlags[captureIdx]
          inc ctx.recursionDepth
          if captureIdx >= 0:
            if captureIdx >= ctx.groupRecursionDepth.len:
              ctx.groupRecursionDepth.setLen(captureIdx + 1)
            inc ctx.groupRecursionDepth[captureIdx]
          ctx.pushChoice Choice(
            kind: chSubexpScope, ssCapIdx: int32(captureIdx), ssFlags: savedFlags
          )
          if captureIdx >= 0 and captureIdx + 1 < ctx.captures.len:
            let index = captureIdx
            let myDepth =
              if index < ctx.groupRecursionDepth.len:
                ctx.groupRecursionDepth[index]
              else:
                -1
            cont = pushFrame(
              ctx,
              Frame(
                kind: ckCapture,
                parent: cont,
                cCapIdx: int32(index + 1),
                cIndex: int32(index),
                cMyDepth: int32(myDepth),
                cStartPos: ctx.pos,
                cSavedFlags: ctx.flags,
              ),
            )
          node = body
          mode = mMatch
      else:
        delegate(matchNodeRecursive(ctx, node, cont))
    of mSeq:
      if seqIdx >= seqNode.children.len:
        mode = mCont
      else:
        # Fold consecutive range markers inline; first non-marker runs next.
        while seqIdx < seqNode.children.len:
          let mk = seqNode.children[seqIdx]
          if mk.kind == nkAbsent and mk.absentKind == abRange:
            let absentPos = findAbsentPos(ctx, mk.absentBody, ctx.pos)
            let savedEnd = ctx.subjectEnd
            ctx.subjectEnd = absentPos
            ctx.pushChoice Choice(kind: chWidenSubjectEnd, wsSavedEnd: savedEnd)
            cont = pushFrame(
              ctx,
              Frame(
                kind: ckRestoreSubjectEnd,
                parent: cont,
                reSavedEnd: savedEnd,
                reAbsentPos: absentPos,
              ),
            )
            inc seqIdx
          elif mk.kind == nkAbsent and mk.absentKind == abClear:
            ctx.subjectEnd = ctx.subject.len
            inc seqIdx
          else:
            break
        if seqIdx >= seqNode.children.len:
          mode = mCont
        else:
          # A last child needs no frame: its continuation *is* ``cont``.
          if seqIdx + 1 < seqNode.children.len:
            cont = pushFrame(
              ctx,
              Frame(
                kind: ckSeqContinue,
                parent: cont,
                sNode: seqNode,
                sIdx: int32(seqIdx + 1),
              ),
            )
          node = seqNode.children[seqIdx]
          mode = mMatch
    of mCont:
      if cont < 0:
        succeed()
      ctx.checkCont cont
      case ctx.frames[cont].kind
      of ckSeqContinue:
        seqNode = ctx.frames[cont].sNode
        seqIdx = int(ctx.frames[cont].sIdx)
        cont = ctx.frames[cont].parent
        mode = mSeq
      of ckCapture:
        let capIdx = int(ctx.frames[cont].cCapIdx)
        let index = int(ctx.frames[cont].cIndex)
        let myDepth = int(ctx.frames[cont].cMyDepth)
        let startPos = ctx.frames[cont].cStartPos
        let savedFlags = ctx.frames[cont].cSavedFlags
        let parent = ctx.frames[cont].parent
        let savedCap = ctx.captures[capIdx]
        ctx.captures[capIdx] = span(startPos, ctx.pos)
        var savedStackEntry = UnsetSpan
        # ``-1`` is the established "no history entry" marker, so recording it
        # in the choice point is what makes ``chUndoCapture`` skip the restore
        # in step with the write skipped here.
        var stackDepth = -1
        if ctx.trackCaptureStacks and myDepth >= 0:
          stackDepth = myDepth
          if index >= ctx.captureStacks.len:
            ctx.captureStacks.setLen(index + 1)
          if myDepth >= ctx.captureStacks[index].len:
            ctx.captureStacks[index].setLen(myDepth + 1)
          savedStackEntry = ctx.captureStacks[index][myDepth]
          ctx.captureStacks[index][myDepth] = span(startPos, ctx.pos)
          ctx.captureStacksDirty = true
        ctx.pushChoice Choice(
          kind: chUndoCapture,
          ucCapIdx: int32(capIdx),
          ucIndex: int32(index),
          ucMyDepth: int32(stackDepth),
          ucSavedCap: savedCap,
          ucSavedStackEntry: savedStackEntry,
          ucFlags: ctx.flags,
        )
        ctx.flags = savedFlags # restore flags at group boundary
        cont = parent
        mode = mCont
      of ckGroup:
        ctx.pushChoice Choice(kind: chUndoFlags, ufFlags: ctx.flags)
        ctx.flags = ctx.frames[cont].grpSavedFlags
        cont = ctx.frames[cont].parent
        mode = mCont
      of ckFlagGroup:
        ctx.pushChoice Choice(
          kind: chUndoFlagsGM, ugFlags: ctx.flags, ugGM: ctx.graphemeMode
        )
        ctx.flags = ctx.frames[cont].fgSavedFlags
        ctx.graphemeMode = ctx.frames[cont].fgSavedGM
        cont = ctx.frames[cont].parent
        mode = mCont
      of ckQuantGreedyMore, ckQuantLazyMore:
        let isGreedy = ctx.frames[cont].kind == ckQuantGreedyMore
        if ctx.pos == ctx.frames[cont].qSavedPos:
          # Zero-width: drive body to vary captures only.
          ctx.pushChoice Choice(
            kind: chZeroWidthRep,
            zBody: ctx.frames[cont].qBody,
            zCont: ctx.frames[cont].parent,
            zFramesLen: ctx.framesLen.int32,
            zIter: 0,
            zSaved: SavedState(),
          )
          cont = ctx.frames[cont].parent
          mode = mCont
        else:
          let body = ctx.frames[cont].qBody
          let minRep = ctx.frames[cont].qMinRep
          let maxRep = ctx.frames[cont].qMaxRep
          let count = ctx.frames[cont].qCount + 1
          let parent = ctx.frames[cont].parent
          if isGreedy:
            startGreedy(body, minRep, maxRep, count, parent)
          else:
            startLazy(body, minRep, maxRep, count, parent)
      of ckRestoreSubjectEnd:
        # Walking out of a marker: widen end, leaving an undo to re-narrow
        # when backtracking retries inside the narrowed region.
        if ctx.choicesLen > choiceBase:
          ctx.pushChoice Choice(
            kind: chUndoSubjectEnd, useAbsentPos: ctx.frames[cont].reAbsentPos
          )
        ctx.subjectEnd = ctx.frames[cont].reSavedEnd
        cont = ctx.frames[cont].parent
        mode = mCont
      of ckEndCheckPos:
        # Terminal predicate; answering here is the whole answer.
        if ctx.pos == ctx.frames[cont].ecpTargetPos:
          cont = ctx.frames[cont].parent
          mode = mCont
        else:
          mode = mFail
      of ckNonZeroPos:
        if ctx.pos > ctx.frames[cont].nzpStartPos:
          cont = ctx.frames[cont].parent
          mode = mCont
        else:
          mode = mFail
      of ckCapturesChanged:
        # Snapshot length always equals captures length (fixed per regex).
        let snapStart = int(ctx.frames[cont].ccSnapshotStart)
        var changed = false
        for i in 0 ..< ctx.captures.len:
          if ctx.captureSnapshots[snapStart + i] != ctx.captures[i]:
            changed = true
            break
        if changed:
          cont = ctx.frames[cont].parent
          mode = mCont
        else:
          mode = mFail
      of ckFindLongestRec:
        let sp = ctx.frames[cont].flStartPos
        let mLen = ctx.pos - sp
        if mLen > ctx.flBestLen:
          ctx.flBestLen = mLen
          writeFoundCopy(ctx.flBestMatch, ctx.captures)
          ctx.flBestMatch.boundaries[0] = span(sp, ctx.pos)
          if ctx.keepStart != sp:
            ctx.flBestMatch.boundaries[0].a = ctx.keepStart
        mode = mFail # force backtracking for more alternatives
    of mFail:
      if ctx.choicesLen <= choiceBase:
        releaseToBase()
        dec ctx.callDepth
        return false
      let top = ctx.choicesLen - 1
      case ctx.choices[top].kind
      of chAlt:
        # Snapshot survives until last branch; copy by hand, release at end.
        ctx.pos = ctx.choices[top].aPos
        ctx.keepStart = ctx.choices[top].aKeepStart
        copyCaptures(
          ctx.captures[0], ctx.capSaves[int(ctx.choices[top].aCapOff)], ctx.captures.len
        )
        ctx.framesLen = ctx.choices[top].aFramesLen
        # Index in place to avoid copying the alternatives seq per backtrack.
        let idx = int(ctx.choices[top].aIdx)
        cont = ctx.choices[top].aCont
        node = ctx.choices[top].aNode.alternatives[idx]
        if idx + 1 >= ctx.choices[top].aNode.alternatives.len:
          ctx.capSaves.setLen(ctx.choices[top].aCapOff)
          ctx.choicesLen = top
        else:
          ctx.choices[top].aIdx = int32(idx + 1)
        mode = mMatch
      of chAltHinted:
        # As ``chAlt``, but a branch is only tried when the hints admit it
        # for the state at hand.  ``aIdx`` is the next raw alternative index
        # left untried, so the filter runs again on every backtrack and its
        # verdict is never cached past a ``subjectEnd`` change: ``(?~|)``
        # widens the end with no undo, and a branch passed over under the
        # narrow end can still match under the wide one.  Telling the two
        # kinds apart is what keeps an unhinted alternation at exactly its
        # old cost -- the case dispatch already had to happen.
        ctx.pos = ctx.choices[top].aPos
        ctx.keepStart = ctx.choices[top].aKeepStart
        copyCaptures(
          ctx.captures[0], ctx.capSaves[int(ctx.choices[top].aCapOff)], ctx.captures.len
        )
        ctx.framesLen = ctx.choices[top].aFramesLen
        cont = ctx.choices[top].aCont
        let altNode = ctx.choices[top].aNode
        # ``pos`` was just restored to the alternation's own position, so the
        # byte the hints read is the one in front of the matcher here.
        let hasByte = ctx.pos < ctx.subjectEnd
        let b =
          if hasByte:
            ctx.subject[ctx.pos].uint8
          else:
            0'u8
        let nxt = nextAltBranch(altNode, int(ctx.choices[top].aIdx), b, hasByte)
        if nxt < 0:
          # No untried branch can start here: drop the choice and keep
          # failing, as ``chAlt`` does when its index runs out.
          ctx.capSaves.setLen(ctx.choices[top].aCapOff)
          ctx.choicesLen = top
          mode = mFail
        else:
          if nxt + 1 >= altNode.alternatives.len:
            ctx.capSaves.setLen(ctx.choices[top].aCapOff)
            ctx.choicesLen = top
          else:
            ctx.choices[top].aIdx = int32(nxt + 1)
          node = altNode.alternatives[nxt]
          mode = mMatch
      of chLeafVariant:
        ctx.pos = ctx.choices[top].lPos
        ctx.framesLen = ctx.choices[top].lFramesLen
        let leaf = ctx.choices[top].lNode
        let lastVariant =
          if leaf.kind == nkCharClass: ClassVariants else: LiteralVariants
        var v = int(ctx.choices[top].lVariant)
        var e = -1
        while v < lastVariant:
          e = leafVariantAdvance(ctx, leaf, v)
          if e >= 0:
            break
          inc v
        if e < 0:
          ctx.choicesLen = top
          mode = mFail
        else:
          cont = ctx.choices[top].lCont
          if v + 1 >= lastVariant:
            ctx.choicesLen = top
          else:
            ctx.choices[top].lVariant = int32(v + 1)
          ctx.pos = e
          mode = mCont
      of chSimpleRepeat:
        # Hand one repetition back; scalars first since downstream may change them.
        let count = ctx.choices[top].srCount
        restoreScalars(ctx, ctx.choices[top].srScalars)
        if count <= ctx.choices[top].srMinRep:
          ctx.repLen = int(ctx.choices[top].srPosOff)
          ctx.choicesLen = top
          mode = mFail
        else:
          let back = count - 1
          let posOff = int(ctx.choices[top].srPosOff)
          ctx.choices[top].srCount = back
          if back > 0:
            ctx.pos = ctx.repPositions[posOff + int(back) - 1]
          ctx.repLen = posOff + int(back)
          ctx.framesLen = ctx.choices[top].srFramesLen
          cont = ctx.choices[top].srCont
          mode = mCont
      of chQuantGreedy:
        restore(ctx, ctx.choices[top].qcSaved)
        ctx.framesLen = ctx.choices[top].qcFramesLen
        let count = ctx.choices[top].qcCount
        let minRep = ctx.choices[top].qcMinRep
        cont = ctx.choices[top].qcCont
        ctx.choicesLen = top
        # Stop repeating, try continuation.
        mode = if count >= minRep: mCont else: mFail
      of chQuantLazy:
        restore(ctx, ctx.choices[top].qcSaved)
        ctx.framesLen = ctx.choices[top].qcFramesLen
        let body = ctx.choices[top].qcBody
        let minRep = ctx.choices[top].qcMinRep
        let maxRep = ctx.choices[top].qcMaxRep
        let count = ctx.choices[top].qcCount
        let parent = ctx.choices[top].qcCont
        let phase = ctx.choices[top].qcPhase
        ctx.choicesLen = top
        if phase == 0 and (maxRep < 0 or count < maxRep):
          ctx.pushChoice Choice(
            kind: chUndoState, usFramesLen: ctx.framesLen.int32, usSaved: save(ctx)
          )
          cont = pushFrame(
            ctx,
            Frame(
              kind: ckQuantLazyMore,
              parent: parent,
              qBody: body,
              qMinRep: minRep,
              qMaxRep: maxRep,
              qCount: count,
              qSavedPos: ctx.pos,
            ),
          )
          node = body
          mode = mMatch
        else:
          mode = mFail
      of chZeroWidthRep:
        ctx.framesLen = ctx.choices[top].zFramesLen
        if ctx.choices[top].zIter > 0:
          # Keep captures; each attempt builds on the previous one.
          drop(ctx, ctx.choices[top].zSaved)
        if ctx.choices[top].zIter >= ctx.captures.len.int32:
          ctx.choicesLen = top
          mode = mFail
        else:
          let s2 = save(ctx)
          if not tryCaptureChangingMatch(ctx, ctx.choices[top].zBody) or
              ctx.pos != s2.pos:
            restore(ctx, s2)
            ctx.choicesLen = top
            mode = mFail
          else:
            ctx.choices[top].zIter += 1
            ctx.choices[top].zSaved = s2
            cont = ctx.choices[top].zCont
            mode = mCont
      of chUndoState:
        restore(ctx, ctx.choices[top].usSaved)
        ctx.framesLen = ctx.choices[top].usFramesLen
        ctx.choicesLen = top
        mode = mFail
      of chUndoScalars:
        restoreScalars(ctx, ctx.choices[top].uzScalars)
        ctx.framesLen = ctx.choices[top].uzFramesLen
        ctx.choicesLen = top
        mode = mFail
      of chUndoFlags:
        ctx.flags = ctx.choices[top].ufFlags
        ctx.choicesLen = top
        mode = mFail
      of chUndoFlagsGM:
        ctx.flags = ctx.choices[top].ugFlags
        ctx.graphemeMode = ctx.choices[top].ugGM
        ctx.choicesLen = top
        mode = mFail
      of chUndoCapture:
        let index = int(ctx.choices[top].ucIndex)
        let myDepth = int(ctx.choices[top].ucMyDepth)
        ctx.captures[int(ctx.choices[top].ucCapIdx)] = ctx.choices[top].ucSavedCap
        ctx.flags = ctx.choices[top].ucFlags
        if myDepth >= 0:
          ctx.captureStacks[index][myDepth] = ctx.choices[top].ucSavedStackEntry
        ctx.choicesLen = top
        mode = mFail
      of chUndoSubjectEnd:
        ctx.subjectEnd = ctx.choices[top].useAbsentPos
        ctx.choicesLen = top
        mode = mFail
      of chWidenSubjectEnd:
        ctx.subjectEnd = ctx.choices[top].wsSavedEnd
        ctx.choicesLen = top
        mode = mFail
      of chAbsentFunc:
        # Retry the continuation with the next shorter end position.
        var tryPos = ctx.choices[top].afTry - 1
        let startPos = ctx.choices[top].afStart
        while tryPos > startPos and (ctx.subject[tryPos].ord and 0xC0) == 0x80:
          dec tryPos
        if tryPos < startPos:
          ctx.pos = startPos
          ctx.choicesLen = top
          mode = mFail
        else:
          ctx.choices[top].afTry = tryPos
          ctx.pos = tryPos
          ctx.framesLen = ctx.choices[top].afFramesLen
          cont = ctx.choices[top].afCont
          mode = mCont
      of chUndoPos:
        ctx.pos = ctx.choices[top].upPos
        ctx.choicesLen = top
        mode = mFail
      of chSubexpScope:
        dec ctx.recursionDepth
        let sci = int(ctx.choices[top].ssCapIdx)
        if sci >= 0 and sci < ctx.groupRecursionDepth.len:
          dec ctx.groupRecursionDepth[sci]
        ctx.flags = ctx.choices[top].ssFlags
        ctx.choicesLen = top
        mode = mFail
      of chLookbehindAlt:
        let kCont = ctx.choices[top].lbaCont
        let kFramesLen = ctx.choices[top].lbaFramesLen
        case lookbehindAltNext(ctx, top)
        of laFixed, laCommitted:
          cont = kCont
          ctx.framesLen = kFramesLen
          mode = mCont
        of laExhausted:
          mode = mFail
      of chUndoCallout:
        let n = ctx.choices[top].ucoNode
        let tag =
          case n.kind
          of nkCalloutMax: n.maxTag
          of nkCalloutCount: n.countTag
          else: ""
        if ctx.choices[top].ucoExisted:
          ctx.calloutCounters[tag] = ctx.choices[top].ucoPrev
        else:
          ctx.calloutCounters.del(tag)
        ctx.choicesLen = top
        mode = mFail

proc matchWithCont(ctx: MatchContext, node: Node, cont: ContId): bool =
  ## Match ``node``, then run ``cont``. Leaves answer here so possessive,
  ## atomic, and simple-repeat bodies cost one small frame per repetition.
  # Leaf under ``TrueCont`` is the whole answer; no loop bookkeeping applies.
  if cont == TrueCont:
    case node.kind
    of nkString, nkCharType, nkLiteral, nkEscapedLiteral, nkCharClass:
      inc ctx.steps
      if ctx.steps > ctx.stepLimit:
        raise newException(RegexLimitError, "match step limit exceeded")
      var e = -1
      case node.kind
      of nkString:
        e = stringAdvance(ctx, node)
      of nkCharType:
        e = charTypeAdvance(ctx, node.charType)
      else:
        let lastVariant =
          if node.kind == nkCharClass: ClassVariants else: LiteralVariants
        var v =
          if node.kind == nkCharClass:
            classFirstVariant(ctx, node)
          else:
            0
        while v < lastVariant:
          e = leafVariantAdvance(ctx, node, v)
          if e >= 0:
            break
          inc v
      if e < 0:
        return false
      ctx.pos = e
      return true
    else:
      discard
  runMachine(ctx, node, cont)

proc runContFromMachine(ctx: MatchContext, cont: ContId): bool =
  ## Run a continuation chain in the loop (for delegated quantifier frames).
  runMachine(ctx, nil, cont, mCont)

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

proc scratchCaps*(ctx: MatchContext): tuple[frames, choices, repPositions: int] =
  ## Buffer sizes (not live lengths); observe the release policy.
  (ctx.frames.len, ctx.choices.len, ctx.repPositions.len)

proc noteScratchUsage(ctx: MatchContext) =
  ## Release oversized scratch buffers after several small searches in a row.
  ## ``choicesPeak`` stands in for frames/capSaves (they grow together);
  ## ``repPeak`` has its own mark since simple repeats push no choices.
  ## Also resets live lengths left behind by ``RegexLimitError``.
  if ctx.capSavesPeak > CapSavesKeep or ctx.choicesPeak > ChoicesKeep or
      ctx.repPeak > RepPositionsKeep:
    ctx.scratchQuiet = 0
    ctx.capSavesHigh = max(ctx.capSavesHigh, ctx.capSavesPeak)
  else:
    inc ctx.scratchQuiet
    if ctx.scratchQuiet >= ScratchQuietRuns:
      if ctx.capSavesHigh > CapSavesKeep:
        ctx.capSaves = newSeqOfCap[Span](CapSavesKeep)
        ctx.capSavesHigh = 0
      if ctx.frames.len > FramesKeep:
        ctx.frames = newSeq[Frame](FramesKeep)
        ctx.framesLen = 0
      if ctx.choices.len > ChoicesKeep:
        ctx.choices = newSeq[Choice](ChoicesKeep)
        ctx.choicesLen = 0
      if ctx.repPositions.len > RepPositionsKeep:
        ctx.repPositions = newSeq[int](RepPositionsKeep)
        ctx.repLen = 0
      ctx.scratchQuiet = 0
  ctx.capSavesPeak = 0
  ctx.choicesPeak = 0
  ctx.repPeak = 0

proc resetForRegex(
    ctx: MatchContext,
    subject: string,
    regex: ptr Regex,
    stepLimit: int,
    maxRecursionDepth: int,
) =
  ## Reset per-regex buffers, reusing ``ctx``'s existing seq capacity.
  ## ``regex`` is borrowed, so every caller passes the address of its own
  ## parameter, never of a local that dies before the match runs.
  ctx.subject = toSubject(subject)
  ctx.flags = regex[].flags
  ctx.regex = regex
  ctx.trackCaptureStacks = regex[].levelBackrefs
  ctx.subjectEnd = subject.len
  ctx.stepLimit = if stepLimit > 0: stepLimit else: int.high
  ctx.maxRecursionDepth = maxRecursionDepth
  # Reset the per-search counters that used to be zero-initialized by
  # allocating a fresh ``MatchContext``.
  ctx.steps = 0
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  ctx.chainDepth = 0
  ctx.choicesLen = 0
  ctx.stackBase = currentStackAddr()
  noteScratchUsage(ctx)
  let capCount = regex[].captureCount
  # ``captures`` is sized exactly (it is copied into ``Match.boundaries``).
  # The internal buffers only grow, so their capacity survives a switch to
  # a regex with fewer captures; ``resetForPosition`` clears stale state.
  ctx.captures.setLen(capCount + 1)
  if capCount > ctx.groupRecursionDepth.len:
    ctx.groupRecursionDepth.setLen(capCount)
  if capCount > ctx.captureStacks.len:
    ctx.captureStacks.setLen(capCount)

proc resetForPosition(ctx: MatchContext, startPos: int, searchStart: int) =
  ## Reset per-position state without reallocating.
  ctx.pos = startPos
  ctx.flags = ctx.regex[].flags
  ctx.searchStart = searchStart
  ctx.keepStart = startPos
  ctx.subjectEnd = ctx.subject.len
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  ctx.chainDepth = 0
  ctx.choicesLen = 0
  ctx.stackBase = currentStackAddr()
  # ``setLen(0)`` is a single length store; guarding it would cost more.
  ctx.framesLen = 0
  ctx.captureSnapshots.setLen(0)
  ctx.capSaves.setLen(0)
  ctx.stackLensSaves.setLen(0)
  ctx.repLen = 0
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
  # ``ctx.subject`` and ``ctx.regex`` borrow this call's parameters, so they
  # must not survive the return: clearing them turns a stale read into a nil
  # dereference instead of a silent read of a dead frame.
  defer:
    ctx.regex = nil
    ctx.subject = Subject(data: nil, size: 0)
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
  if rb.valid and indexOfByte(subject, start, rb.byte) < 0:
    noteScratchUsage(ctx)
    return
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
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
          let nl = indexOfByte(subject, startPos, uint8('\n'))
          if nl < 0:
            exhausted = true
            break
          startPos = advanceChainTo(subject, startPos, nl + 1, byteScan)
      of fcByte:
        # Scan forward to the next candidate whose lead byte is the one the
        # pattern needs.  [advanceChainTo] turns a hit into a scan position,
        # since a byte inside a character the walk steps over is not a start
        # position.
        var found = false
        while startPos < subject.len:
          let hit = indexOfByte(subject, startPos, fc.byte)
          if hit < 0:
            break
          startPos = advanceChainTo(subject, startPos, hit, byteScan)
          if startPos >= subject.len:
            break
          if subject[startPos].uint8 == fc.byte:
            found = true
            break
        if not found:
          exhausted = true
      of fcByteSet:
        # One load per byte: the lead byte decides both whether the position is
        # a candidate and how far the next one is.
        var found = false
        while startPos < subject.len:
          let b = subject[startPos].uint8
          if b in fc.bytes:
            found = true
            break
          let step =
            if byteScan or b < 0x80'u8:
              1
            else:
              encLen(b)
          startPos += step
        if startPos > subject.len:
          startPos = subject.len
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
      ctx.framesLen = fid
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
  # ``ctx.subject`` and ``ctx.regex`` borrow this call's parameters, so they
  # must not survive the return: clearing them turns a stale read into a nil
  # dereference instead of a silent read of a dead frame.
  defer:
    ctx.regex = nil
    ctx.subject = Subject(data: nil, size: 0)
  writeNotFound(m)
  # Quick reject: if the pattern requires a specific byte, check its presence.
  # ``extractRequiredByte`` only ever yields an ASCII byte of a case-sensitive
  # literal, and such a literal is compared byte for byte, so the byte has to
  # occur literally for any match to exist.
  let rb = regex.requiredByte
  if rb.valid and indexOfByte(subject, 0, rb.byte) < 0:
    noteScratchUsage(ctx)
    return
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
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
  # ``ctx.subject`` and ``ctx.regex`` borrow this call's parameters, so they
  # must not survive the return: clearing them turns a stale read into a nil
  # dereference instead of a silent read of a dead frame.
  defer:
    ctx.regex = nil
    ctx.subject = Subject(data: nil, size: 0)
  writeNotFound(m)
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
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
