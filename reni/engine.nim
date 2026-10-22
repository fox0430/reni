## Backtracking regex matching engine.
## Uses an explicit frame stack on ``MatchContext`` for continuation
## passing, giving correct backtracking through alternations,
## quantifiers, and flag groups without per-call closure allocations.

import std/[unicode, tables, macros, bitops]
from std/strutils import find
from std/typetraits import supportsCopyMem

import types, unicode_utils, stackguard, leafgate

# Re-exported so callers can read the compiled-in budget (used by tests).
export stackguard.MaxStackBytes

type
  ContId = int32
    ## Index into ``MatchContext.frames`` identifying a continuation.
    ## ``TrueCont`` (-1) is the sentinel for "no further work, succeed".

  CapOff = distinct int32
    ## Where a capture snapshot's slot starts on ``MatchContext.capSaves``,
    ## counted in ``Span`` elements.  A slot is ``ctx.captures.len`` elements
    ## wide, not one; distinct so that ``off + 1`` does not compile and the
    ## width stays inside ``releaseTo`` / ``retainSlot`` / ``capturesBackTo``.

  ContKind = enum
    ## Continuation kinds.  Each kind encodes a specific post-match
    ## action that closures used to perform via captured locals.
    ckSeqContinue ## After a child node, resume the next sibling.
    ckCapture ## After capture body, write capture span and chain.
    ckGroup ## After group body, restore flags before chaining.
    ckFlagGroup ## After flag group body, restore flags / grapheme mode.
    ckQuantGreedyMore ## Greedy quantifier: try one more rep, then fall back.
    ckQuantLazyMore ## Lazy quantifier: try one more rep, then fall back.
    ckRestoreAbsentEnd ## Absent abRange/abExpression: restore ``absentEnd``.
    ckEndCheckPos ## Lookbehind: succeed iff ctx.pos == targetPos.
    ckFindLongestRec ## findLongest top level: record longest, return false.

  Frame = object
    ## Continuation frame. Frames live in a flat ``seq`` on ``MatchContext``;
    ## ``parent`` chains them. A frame names an AST node by [NodeId] rather
    ## than holding one -- see ``Choice`` below for what that buys.
    parent: ContId
    case kind: ContKind
    of ckSeqContinue:
      sNode: NodeId ## parent nkConcat node (children walked by idx)
      sIdx: int32 ## next child index to match
    of ckCapture:
      cCapIdx: int32
      cIndex: int32
      cMyDepth: int32
      cOpened: int32 ## [openStamp] of this entry; the close records it.
      cStartPos: int
      cSavedFlags: RegexFlags
    of ckGroup:
      grpSavedFlags: RegexFlags
    of ckFlagGroup:
      fgSavedFlags: RegexFlags
      fgSavedGM: GraphemeMode
    of ckQuantGreedyMore, ckQuantLazyMore:
      qBody: NodeId
      qMinRep: int32
      qMaxRep: int32
      qCount: int32
      qPure: bool
        ## Mirror of the quantifier's ``quantBodyPure``: the repetition is
        ## re-entered from this frame, with the node no longer in hand, so the
        ## verdict travels along. Sits in ``qCount``'s padding, so ``Frame``
        ## does not grow.
      qSnap: CapOff
        ## The captures as this iteration found them: the slot of the rollback
        ## the repetition left behind it, or ``NoCapOff`` for a pure body,
        ## which writes none.  Read only where the iteration consumed nothing
        ## ([emptyPassProgressed]).  In the same padding as ``qPure``.
      qSavedPos: int
    of ckRestoreAbsentEnd:
      reSavedEnd: int
      reAbsentPos: int
    of ckEndCheckPos:
      ecpTargetPos: int
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
    matchOptions: MatchOptions
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
    trackOpenOrder: bool
      ## Mirror of ``Regex.openOrder``: when true, ``captures`` also holds an
      ## [openedSlot] for each of ``Regex.openedGroups``, written by the same
      ## two sites.
    openClock: int32 ## The last [openStamp] handed out this attempt.
    trackCloses: bool
      ## ``trackCaptureStacks or trackOpenOrder``: the loop's close tests
      ## this once, so a pattern with neither pays one test for both.
    openedBase: int32
      ## [openedSlot] less the group number: ``groupSlots`` less the first of
      ## ``Regex.openedGroups``.  In ``trackCloses``'s padding, so the fields
      ## after it keep their offsets: moving them measured up to 0.7% on
      ## items with no reference.
    groupSlots: int ## The slots of ``captures`` that hold groups, the whole match first.
    capturesLen: int
      ## ``captures.len``: ``groupSlots``, and under ``trackOpenOrder`` the
      ## [openedSlot]s past them.  Set once per tree in ``resetForRegex``:
      ## working it out per bind measured up to 0.7% dearer on items with no
      ## reference.
    absentEnd: int
      ## The end the absent operator narrows: ``(?~|absent)`` and
      ## ``(?~|absent|expr)`` move it in, the range clear ``(?~|)`` puts it
      ## back at the end of the subject.  ``(?~)`` is not a clear -- it is
      ## the absent function with an empty pattern, and leaves this alone, as
      ## Oniguruma's does.  Like ``lookLimit`` it bounds consumption, not the
      ## zero-width shapes: ``$``, ``\z``, ``\Z`` and ``\b`` answer from the
      ## real subject, as Oniguruma's do -- its absent operator moves only
      ## ``right_range``, which they do not read.  The one exception is ``\b``
      ## at position 0; see [matchWordBoundary].
    lookLimit: int
      ## The window a running look-behind body may not consume past, or
      ## ``NoLookLimit`` outside one.  Bounds consumption only, apart from
      ## ``\b`` at position 0 ([matchWordBoundary]).
      ##
      ## Written by [enterLookaroundBody], by [lookbehindBodyEndsAt] putting
      ## back what it found, and by the per-search resets.  A look-behind
      ## *narrows* rather than replaces: a nested one reads the same span its
      ## enclosing body is clipped to, and one that needs no window of its own
      ## keeps running under the enclosing clip, which is what Oniguruma does
      ## with ``right_range``.  A look-ahead is the exception and replaces it
      ## with ``NoLookLimit``; [enterLookaroundBody] has the list.  How far the
      ## matcher may consume is [subjectEnd], which derives from this and
      ## ``absentEnd`` rather than being stored beside them.
    absentScan: int
      ## Nesting depth of a running absent-pattern scan -- the walk that looks
      ## for the first position an absent operator's own pattern matches.
      ## Zero outside one, and cleared again for any body whose backtracking
      ## its caller discards ([matchDiscardedBody]).
      ##
      ## While it is above zero, an absent operator refuses ([absentSuppressed]).
      ## Oniguruma reaches the same answer by construction rather than by a
      ## flag: it compiles ``(?~X)`` into a loop that narrows the range and
      ## then fails on purpose, so that a *nested* absent operator, whose own
      ## tail restores the range as the failure unwinds through it, takes the
      ## narrowing back with it.  A path holding one therefore never narrows,
      ## which is what refusing the path amounts to here -- and a path that
      ## can reach the same match without one still narrows, since the scan
      ## simply backtracks into it.
    recursionDepth: int ## for detecting never-ending recursion
    captureStacks: seq[seq[Span]]
      ## per-group capture history for recursion-level backrefs
    groupRecursionDepth: seq[int] ## per-group recursion depth counter
    steps: int ## match step counter for ReDoS protection
    graphemeMode: GraphemeMode ## current grapheme mode from (?y{g}) or (?y{w})
    stepLimit: int
      ## Where ``steps`` raises.  A search loop may raise it to the budget of
      ## the attempt it runs ([stepBudget]); it is never above that budget.
    attemptStepLimit: int
      ## The caller's step limit for one attempt (``int.high`` = unlimited).
    budgetOrigin: int
      ## Where the search started; its step budget grows with every byte an
      ## attempt's start has moved away from here.
    rerunCount: int ## Backs [stepReruns]; nothing resets it.
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
    capturesDirty: bool
      ## true when ``captures`` may hold something other than ``UnsetSpan``,
      ## letting ``resetForPosition`` skip the clearing loop.  Set wherever a
      ## capture span is written; a copy back from ``capSaves`` needs none,
      ## since what was pushed there went through one of those sites.
    groupDepthDirty: bool
      ## true when some ``groupRecursionDepth[i]`` may be non-zero. Only
      ## subexpression recursion ever increments one.
    frames: seq[Frame]
      ## Frame buffer; live length is ``framesLen``. Never shrinks, so push/pop
      ## avoids destructors. Stale entries own nothing, under every memory
      ## management: a frame is plain values down to the last field.
    framesLen: int ## Live length of ``frames``.
    choices: seq[Choice]
      ## Backtrack buffer; live length is ``choicesLen``. Never shrinks; stale
      ## entries own nothing, in the same way ``frames`` above notes.
    choicesLen: int ## Live length of ``choices``. LIFO with ``frames`` and ``capSaves``.
    repPositions: seq[int]
      ## Repetition end positions for ``chSimpleRepeat``, LIFO with ``choices``.
      ## One ``int`` per rep; no snapshot needed since only ``pos`` changes.
      ## Live length is ``repLen`` so release is a length store.
    repLen: int ## Live length of ``repPositions``.
    repPeak: int
      ## High-water mark of ``repLen``. Needed because simple repeats push no
      ## choice point, so ``choicesPeak`` cannot see them.
    capSaves: seq[Span]
      ## Capture vectors for live ``SavedState`` snapshots (bulk copy).  Live
      ## length is ``capSavesLen``, so release is a length store and growth
      ## zero-fills only when the buffer is full.
    capSavesLen: int ## Live length of ``capSaves``.
    capSavesPeak: int ## High-water mark of ``capSaves`` for the current search.
    capUndos: seq[CapUndo]
      ## Pre-images for the groups a kept body actually wrote, for
      ## ``chUndoSparse`` entries. LIFO with ``choices``; live length is
      ## ``capUndosLen``, so release is a length store.
    capUndosLen: int ## Live length of ``capUndos``.
    capUndosPeak: int
      ## High-water mark of ``capUndosLen``. Its own mark because one
      ## ``chUndoSparse`` entry can push many groups.
    capUndosHigh: int ## Highest peak seen since the buffer was last released.
    stackLensSaves: seq[seq[int]]
      ## ``captureStacks`` length snapshots for ``chLookbehindAlt`` entries.
    choicesPeak: int
      ## High-water mark of ``choices``; measures whether a search was big.
    scratchQuiet: int ## Consecutive small searches within the keep marks.
    flBestLen: int ## findLongest: best match length so far (-1 if none)
    flBestMatch: Match ## findLongest: deepest match recorded
    leadRun: NodeId
      ## Cached ``Regex.leadRun``, as an index: the comparison below is an
      ## identity test, which an index answers without the question of what a
      ## recycled address might have been reused for.
    leadRunEnd: int
      ## End of ``leadRun``'s run at this start, or -1 if never reached.
      ## Valid only after a failed attempt.
    leadLeaf: NodeId
      ## Cached ``Regex.leadLeaf`` as an index, or ``NoNodeId``. Tested before
      ## each attempt unless the counters below turn it off.
    leadLeafFor: pointer
      ## The ``Regex.ast`` all cached fields below belong to. Identity-compared,
      ## never dereferenced. Load-bearing: it also gates ``captures`` sizing,
      ## whose writes are unguarded, so ``boundAst`` must keep the address live.
    leadLeafTried: int32
      ## Positions answered and refusals for ``leadLeafFor``. Outlives one
      ## search since a ``findAll`` loop pays the cost a few positions at a time.
    leadLeafSkips: int32
    leadLeafOff: bool
      ## Whether the counters turned the prefilter off. Retried after
      ## ``leadLeafCool`` positions: a refusing-nothing prefix says nothing
      ## about what follows.
    leadAnchorsLen: int32 ## Filled entries in ``leadAnchors``.
    leadAnchors: array[AnchorKind.high.ord + 1, AnchorKind]
      ## ``Regex.leadAnchors`` unpacked, derived once per pattern beside the
      ## lead indices. A ``set`` here cost ``leadAnchorsHold`` a walk of the
      ## whole enum range per admitted position. Shares the ``leadLeaf``
      ## counters as one prefilter.
    leadLeafCool: int32 ## Positions left before retrying an off prefilter.
    leadRepeat: NodeId
      ## Cached ``Regex.leadRepeat``, or ``NoNodeId``. Replaces ``leadLeaf``
      ## on the same counters.
    boundAst: Node
      ## Holds the tree ``leadLeafFor`` names so its address cannot be recycled.
    gates: ptr UncheckedArray[LeafGate]
      ## The bound pattern's [LeafGate] table, borrowed the way ``regex`` above
      ## is, and retaken on every bind rather than with the per-tree
      ## derivations: two ``Regex`` values can share one ``ast`` -- a copy does
      ## -- and own a table each.  ``nil`` where the pattern carries no table.
    gatesLen: int
      ## Slots behind ``gates``, which as an unchecked array carries no bound
      ## of its own; [gateAt] checks an id against this.
    seqCacheNode: NodeId
      ## The repeat ``seqCacheElems`` describes, or ``NoNodeId``.  One slot,
      ## keyed on the node id: the bind that switches trees clears it.
    seqCacheK: int32 ## Elements behind ``seqCacheElems``.
    seqCacheElems: array[MaxSeqRunElems, SeqRunElem]
    seqCacheAccept: array[MaxSeqRunElems, set[uint8]]
      ## Accept sets under ``boundFlags``.
    seqCacheUnion: set[uint8] ## Union of those sets; bounds a whole walk.
    seqRegionFrom: int
    seqRegionEnd: int
      ## Stretch walked so far: every byte in ``[seqRegionFrom, seqRegionEnd)``
      ## is in ``seqRegionUnion``.  ``seqRegionEnd < 0`` means nothing cached.
      ## Grown across one scan (``sameSubject``); rebuilding per match is
      ## quadratic on a long run.
    seqRegionUnion: set[uint8]
      ## Union the stretch was walked under.  Keyed on the set, not the node.
    seqRegionDone: bool
      ## Byte at ``seqRegionEnd`` is known and outside the union.  False when
      ## the walk stopped at ``subjectEnd`` or ran out of budget.
    seqRegionHigh: bool
      ## Terminator is non-ASCII, so no accept set decides it.  Read only
      ## under ``seqRegionDone``.
    seqRegionData: pointer
      ## Buffer the stretch was walked on.  ``releaseBorrowed`` clears
      ## ``subject``, so ``sameSubject`` is checked against this pointer.
    boundFlags: RegexFlags
      ## The flags ``gates`` was derived under. A scoped ``(?i:...)`` moves
      ## ``ctx.flags`` under a node the compiler already answered, so every
      ## reader compares the two first.
    reqHit: int
      ## Where ``requiredLit`` was found, in the buffer at ``reqHitData`` for
      ## the tree at ``reqHitFor``.  A search over that buffer from at or
      ## before it compares the literal there instead of reading up to it.
      ## The bytes decide, not the key: a caller may have rewritten them, or
      ## freed them and handed their address to another subject, so the key
      ## is a pointer, held by nothing.
    reqHitData: pointer
    reqHitFor: pointer

  CapUndo = object
    ## One group's pre-image.  A nested machine leaves no ``chUndoCapture``
    ## entries behind, so a caller that keeps what the body captured records
    ## the changed groups instead of a whole vector -- see ``keepCaptures``.
    cuIdx: int32
    cuSpan: Span

  ScalarState = object
    ## Rollback snapshot without captures; for bodies that write none.
    pos: int
    flags: RegexFlags
    keepStart: int
    absentEnd: int
    lookLimit: int
    graphemeMode: GraphemeMode

  ChoiceKind = enum
    ## Backtrack entry action. The first four offer an untried alternative;
    ## the rest undo an effect and keep failing.
    chAlt ## alternation: try the next branch
    chAltHinted ## alternation carrying first-byte hints: skip dead branches
    chAltTrie ## alternation of literals: ask the trie for the next branch
    chLeafVariant ## literal / class: try the next way it can match
    chQuantGreedy ## greedy quantifier: stop repeating, run the continuation
    chQuantLazy ## lazy quantifier: the continuation failed, repeat once more
    chSimpleRepeat ## greedy repetition of a single-way leaf: give one rep back
    chLazyScan
      ## lazy repetition of a single-way leaf: scan to the next admissible position
    chSeqRun ## greedy sequence of leaf runs: hand the next split back
    chUndoState ## roll back to a snapshot, then keep failing
    chUndoSparse ## roll back the scalars and only the groups a body wrote
    chUndoScalars ## roll back everything but the captures, then keep failing
    chUndoFlags ## put back the flags a group boundary restored
    chUndoFlagsGM ## put back the flags and grapheme mode a flag group restored
    chUndoCapture ## put back the span, flags and stack entry a capture wrote
    chUndoAbsentEnd ## put back the ``absentEnd`` an absent range narrowed
    chWidenAbsentEnd ## widen the ``absentEnd`` an absent marker narrowed
    chAbsentFunc ## absent function: retry the continuation shorter
    chUndoPos ## rewind the position a backreference advanced
    chSubexpScope ## leave a subexpression call: depths and flags
    chLookbehindAlt ## divided lookbehind: try the next alternative
    chUndoCallout ## put back the counter a callout incremented

  Choice = object
    ## Backtrack stack entry. Reifies the choice points and undo work the
    ## recursive matcher kept in native frames, so the matcher can run as a
    ## loop (see ``runMachine``). Restores only what its site restored; e.g.
    ## alternation leaves ``flags`` alone so ``(?i)`` spans branches.
    ##
    ## An AST node is named by [NodeId], not held: the tree outlives every
    ## match, so a reference here would only cost the hot path an atomic pair
    ## per push.  An index makes an entry plain data, which is what lets
    ## ``storeSlot`` move one with ``copyMem`` under every memory management,
    ## and lets an arm read a node out of an entry it has already popped.
    case kind: ChoiceKind
    of chAlt, chAltHinted, chAltTrie:
      aNode: NodeId
      aIdx: int32 ## next branch to try
      aCont: ContId
      aFramesLen: int32
      aPos: int
      aKeepStart: int
      when not defined(release):
        aCapCheck: CapOff
          ## Debug builds only: the captures at the push, which every pop
          ## asserts it finds again; see [altCheckPush].
    of chLeafVariant:
      lNode: NodeId
      lVariant: int32 ## next way to try
      lCont: ContId
      lFramesLen: int32
      lPos: int
    of chQuantGreedy, chQuantLazy:
      qcBody: NodeId
      qcMinRep: int32
      qcMaxRep: int32
      qcCount: int32
      qcCont: ContId
      qcFramesLen: int32
      qcPhase: int32 ## lazy only: 0 = body not yet tried, 1 = exhausted
      qcPure: bool
        ## Body writes no captures (``Node.quantBodyPure``), so ``qcSaved``
        ## holds scalars only and is rolled back with ``restoreScalars``.
      qcSaved: SavedState
        ## Rollback point. ``capOff`` is ``NoCapOff`` when ``qcPure``, so a
        ## stray ``restore`` fails loudly instead of copying a slice that was
        ## never pushed.
    of chSimpleRepeat:
      srCont: ContId
      srFramesLen: int32
      srMinRep: int32
      srCount: int32 ## repetitions currently handed to the continuation
      srPosOff: int32 ## start of this repeat's tail in ``MatchContext.repPositions``
      srRunCount: int32
        ## Leading repetitions taken as one ASCII run, storing no position:
        ## each is one byte wide, so repetition ``k <= srRunCount`` ends ``k``
        ## bytes past ``srScalars.pos``. ``srPosOff`` indexes the rest.
      srFollow: int16
        ## ``Node.quantFollowByte``, or -1.  A give-back hands the continuation
        ## the character at its stop position, so a position not holding this
        ## byte is skipped rather than dispatched -- see [retreatToFollowByte].
      srScalars: ScalarState
        ## State at repeat start. Only ``pos`` comes from the body; the rest
        ## covers what the continuation changed (``\K``, flags). Captures need
        ## no snapshot: a single-way leaf writes none, and continuation
        ## captures have their own ``chUndoCapture`` entries.
    of chLazyScan:
      lsBody: NodeId
      lsNext: NodeId ## continuation leaf, ``Node.quantNextLeaf``
      lsCont: ContId
      lsFramesLen: int32
      lsCount: int32 ## repetitions currently handed to the continuation
      lsMaxRep: int32
      lsPos: int ## stop position of those reps; the scan only moves forward
      lsScalars: ScalarState ## state at repeat start; see ``srScalars``
    of chSeqRun:
      qrNode: NodeId ## the repeat
      qrCont: ContId
      qrFramesLen: int32
      qrIters: int32 ## iterations the current state holds
      qrPosOff: int32
        ## Start of this repeat's element ends in ``MatchContext.repPositions``:
        ## one ``int`` per element per iteration.  A give-back is a decrement.
      qrRegion: int ## First position no element accepts; carried from [seqRunRegion].
      qrScalars: ScalarState ## state at repeat start; see ``srScalars``
    of chUndoState:
      usFramesLen: int32
      usSaved: SavedState
    of chUndoSparse:
      upFramesLen: int32
      upUndoOff: int32
        ## Where this entry's run starts in ``MatchContext.capUndos``; popping
        ## walks back to it.
      upScalars: ScalarState
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
        ## The history entry to put back, or ``-1`` for none; ``-2`` for none
        ## but the group's [openedSlot], which ``ucSavedStackEntry`` holds.
      ucSavedCap: Span
      ucSavedStackEntry: Span
      ucFlags: RegexFlags
    of chUndoAbsentEnd:
      useAbsentPos: int
    of chWidenAbsentEnd:
      wsSavedEnd: int ## ``absentEnd`` before narrowing; popping widens it back.
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
      lbaNode: NodeId ## Lookaround node under test.
      lbaNext: int32 ## Next alternative index to try.
      lbaCont: ContId
      lbaFramesLen: int32
      lbaTarget: int ## Position the lookbehind ends at (entry ``pos``).
      lbaSaved: SavedState ## Entry snapshot, replayed until exhausted.
      lbaLensOff: int32 ## Stack-length snapshot offset in `stackLensSaves`.
    of chUndoCallout:
      ucoNode: NodeId ## Callout node whose counter was incremented.
      ucoPrev: int
      ucoExisted: bool

  SavedState = object
    ## Rollback snapshot.  ``capOff`` locates the capture vector's slot on
    ## ``MatchContext.capSaves``, so taking one is a bulk copy rather than an
    ## allocation.  Strictly LIFO: every ``save`` must release its slot before
    ## returning, via ``restore``, ``keepCaptures`` or ``drop`` (``rewind``
    ## rolls back without releasing, to replay the snapshot; a snapshot handed
    ## to a choice entry is released when that entry pops).  ``NoCapOff`` means
    ## the snapshot carries scalars only.
    scalars: ScalarState
    capOff: CapOff

proc indexOfByte(s: string, start: int, b: uint8): int {.inline.} =
  ## Index of the first ``b`` at or after a non-negative ``start``, or -1.
  ## Goes through ``strutils.find``, which is libc's vectorized ``memchr``
  ## on the C backend and a byte loop everywhere else.
  if start >= s.len:
    -1
  else:
    find(s, char(b), start)

proc indexOfAnyByte(s: string, start: int, bs: set[uint8]): int =
  ## Index of the first byte of ``bs`` at or after ``start``, or -1.
  for i in start ..< s.len:
    if uint8(s[i]) in bs:
      return i
  -1

proc lastIndexOfAnyByte(s: string, start: int, bs: set[uint8]): int =
  ## Index of the last byte of ``bs`` at or after ``start``, or -1.
  for i in countdown(s.high, start):
    if uint8(s[i]) in bs:
      return i
  -1

const ReqCandidates = 4
  ## Places [findString] compares before it hands the rest to ``memmem``.

proc findString(s: string, lit: RequiredLiteral, start: int): int =
  ## Index of the first ``lit.str`` at or after ``start``, or -1.  A scan
  ## asks once per match, and glibc's ``memmem`` builds a shift table on
  ## every call, as costly as a small match; ``memchr`` for the string's
  ## least likely byte and a compare around it cost nothing to set up.  After
  ## a few places that fail, the rest goes to ``memmem``, so the search stays
  ## linear in the subject.
  let n = lit.str.len
  let k = lit.at
  var c = start # The first place not yet ruled out.
  for _ in 0 ..< ReqCandidates:
    let p = indexOfByte(s, c + k, uint8(lit.str[k]))
    if p < 0 or p - k > s.len - n:
      return -1
    c = p - k
    if equalMem(unsafeAddr s[c], unsafeAddr lit.str[0], n):
      return c
    inc c
  find(s, lit.str, c)

proc findRequired(s: string, lit: RequiredLiteral, start: int): int {.inline.} =
  ## Index of the first occurrence of ``lit`` at or after ``start``, or -1.
  if lit.kind == rlString:
    findString(s, lit, start)
  else:
    indexOfAnyByte(s, start, lit.set)

proc requiredAt(s: string, lit: RequiredLiteral, p: int): bool {.inline.} =
  ## Whether ``lit`` occurs at ``p``.
  if lit.kind == rlString:
    p + lit.str.len <= s.len and
      equalMem(unsafeAddr s[p], unsafeAddr lit.str[0], lit.str.len)
  else:
    p < s.len and uint8(s[p]) in lit.set

proc requiredLitRead(
    ctx: MatchContext, subject: string, regex: Regex, start: int, held: bool
): bool {.noinline.} =
  ## [requiredLitAbsent] where the occurrence it holds does not answer:
  ## reads the subject, and holds what it finds.
  var q: int
  if held and start > ctx.reqHit and regex.requiredLit.kind == rlSet:
    # Past the occurrence it holds, a scan wants the last one, which answers
    # every start up to it; a byte set is read back from the end for it,
    # once.  A string is read forward from the start, so a scan reads each
    # stretch once: ``rfind`` compares the whole string at every position,
    # and tails read from the end would read a tail that lacks it again on
    # every step through occurrences close together.
    q = lastIndexOfAnyByte(subject, start, regex.requiredLit.set)
  else:
    q = findRequired(subject, regex.requiredLit, start)
  if q < 0:
    return true
  ctx.reqHit = q
  ctx.reqHitData = cast[pointer](unsafeAddr subject[0])
  ctx.reqHitFor = cast[pointer](regex.ast)
  false

proc requiredLitAbsent(
    ctx: MatchContext, subject: string, regex: Regex, start: int
): bool {.noinline.} =
  ## Whether ``subject`` lacks ``regex.requiredLit`` at or after ``start``,
  ## so that no match can begin there.  Off the hot path: the caller tests
  ## the kind first.
  if start >= subject.len:
    return true
  let held =
    ctx.reqHitData == cast[pointer](unsafeAddr subject[0]) and
    ctx.reqHitFor == cast[pointer](regex.ast)
  if held and start <= ctx.reqHit and requiredAt(subject, regex.requiredLit, ctx.reqHit):
    return false
  requiredLitRead(ctx, subject, regex, start, held)

const RepeatPairStride = 8
  ## Positions a word step of [nextRepeatPairPos] answers at once.

proc nextRepeatPairPos(s: string, start: int): int =
  ## First position at or after ``start`` where a ``(leaf)\1`` prefilter can
  ## still hold, or -1 when the subject holds none: an ASCII byte equal to the
  ## byte after it, or a byte at or above 0x80, which [leadRepeatHolds] hands
  ## back unanswered because the byte test cannot measure its width.
  ##
  ## An ASCII position holds a one-byte character, so the single-character leaf
  ## [leadRepeatLeaf] matches one byte there and the backreference then needs
  ## ``s[p] == s[p + 1]``: what this skips is refused, not merely prefiltered.
  ## The last position is refused for want of room, so the walk stops one short.
  var p = max(start, 0)
  let n = s.len
  # A non-ASCII candidate answers itself, so loading a window would be pure
  # overhead on a subject that holds no ASCII to skip over.
  if p + 1 < n and s[p].uint8 >= 0x80'u8:
    return p
  when cpuEndian == littleEndian:
    # Eight positions a step: exclusive-or the window against itself shifted
    # one byte, and a zero byte marks a pair; the unshifted window's high bits
    # mark where the byte test stops.  Both masks set bit 8i+7 for position
    # ``p + i``, so the lowest set bit names the first candidate -- and only
    # that one may be read, because the borrow out of a zero byte propagates
    # upward and can set the bit of a higher byte that is neither a pair nor
    # high (window ``"aa\x60..."`` sets bit 15).  Such a false positive never
    # sits below the zero byte that caused it.
    const Ones = 0x0101010101010101'u64
    const Highs = 0x8080808080808080'u64
    while p + RepeatPairStride + 1 <= n:
      var v, u: uint64
      copyMem(addr v, unsafeAddr s[p], RepeatPairStride)
      copyMem(addr u, unsafeAddr s[p + 1], RepeatPairStride)
      let x = v xor u
      let m = ((x - Ones) and not x and Highs) or (v and Highs)
      if m != 0:
        return p + (countTrailingZeroBits(m) shr 3)
      p += RepeatPairStride
  while p + 1 < n:
    let b = s[p].uint8
    if b >= 0x80'u8 or b == s[p + 1].uint8:
      return p
    inc p
  -1

var emptySubjectByte: char
  ## Target for the ``data`` pointer of an empty subject, so a ``Subject``
  ## view never holds a nil pointer.

proc toSubject(s: string): Subject {.inline.} =
  ## Borrow ``s``'s buffer.  The result must not outlive ``s``.
  if s.len > 0:
    Subject(data: cast[ptr UncheckedArray[char]](unsafeAddr s[0]), size: s.len)
  else:
    Subject(data: cast[ptr UncheckedArray[char]](addr emptySubjectByte), size: 0)

template nodeAt(ctx: MatchContext, id: NodeId): Node =
  ## The node ``id`` names, out of the regex's node table.  One extra load is
  ## the whole cost of naming a node by index; ``NoNodeId`` is slot 0, which
  ## holds ``nil``, so no branch is needed here.
  ##
  ## Only matching code may use it, and only past ``resetForRegex``, for the
  ## reason ``MatchContext.regex`` gives.
  ctx.regex[].nodes[id.int]

proc gateAt(ctx: MatchContext, id: NodeId): ptr LeafGate {.inline.} =
  ## The [LeafGate] ``id`` names, out of the bound table.  Checked the way
  ## ``nodeAt``'s index is and for the same reason: an id numbered in another
  ## tree should raise, not read past the table into a silent wrong answer.
  rangeCheck id.int > 0 and id.int < ctx.gatesLen
  addr ctx.gates[id.int]

template len(s: Subject): int =
  s.size

template `[]`(s: Subject, i: int): char =
  s.data[i]

template oa(s: Subject): untyped =
  ## The view as an ``openArray[char]``, for the Unicode helpers.
  toOpenArray(s.data, 0, s.size - 1)

const NoLookLimit = int.high ## ``lookLimit`` outside a look-behind body.

template subjectEnd(ctx: MatchContext): int =
  ## How far the matcher may *consume*. Consumption reads this; zero-width
  ## shapes read the real subject, apart from ``\b`` at position 0
  ## ([matchWordBoundary]). Derived, not stored.
  min(ctx.absentEnd, ctx.lookLimit)

proc decodeCharUpTo(
    ctx: MatchContext, p, limit: int, code: var int32, next: var int
): bool {.inline.} =
  ## Decode char at ``p`` against a subject that ends at ``limit``; false if
  ## truncated there.
  decodeAt(toOpenArray(ctx.subject.data, 0, limit - 1), p, code, next)

proc decodeChar(
    ctx: MatchContext, p: int, code: var int32, next: var int
): bool {.inline.} =
  ## Decode char at ``p``; false if truncated (nothing consumes it).
  decodeCharUpTo(ctx, p, ctx.subjectEnd, code, next)

proc nextScanPos*(s: string, p: int): int {.inline.} =
  ## Next scan start after ``p`` via the lead byte's *declared* length, as
  ## ``onig_search`` steps: a sequence truncated by the end of ``s`` is one
  ## character to [nextCharAt] but a full step here, so the scan can step over
  ## a tail the matcher would accept. Clamped to the end, which is itself a
  ## start position (``\z``, ``$``, ``\b`` match there) with no lead byte to
  ## step off, so ``p == s.len`` stays put. Exported so the first-byte-hint
  ## test can sweep the positions the scan visits rather than restate the rule.
  if p >= s.len:
    return s.len
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

proc isLeadByte(b: uint8): bool {.inline.} =
  ## Whether ``b`` is at or above 0xC0, the boundary the chain walk has no
  ## choice below: ``encLen`` answers 1 for every byte under it -- ASCII, but
  ## stray continuation bytes too -- which is why it is not 0x80. A superset
  ## of the true multi-byte leads: 0xF5..0xFF answer true here yet have
  ## ``encLen`` 1, which only costs them the slow branch.
  (b and 0xC0'u8) == 0xC0'u8

proc firstLeadByte(s: string, first, last: int): int {.noinline.} =
  ## Index of the first byte at or above 0xC0 in ``[first, last)``, or ``last``
  ## when there is none. That index need not start a multi-byte character --
  ## see ``isLeadByte``. A machine word at a time: shifting left by one lines
  ## each byte's 0x40 bit up with its 0x80 bit, so a byte survives the mask
  ## exactly when both are set. ``noinline`` is measured: inlined it shifts
  ## gcc's inlining budget for the module and costs two items that never call
  ## it +0.70% and +0.17% ``Ir``.
  const HighBits = 0x8080808080808080'u64
  var i = first
  while i + 8 <= last:
    var w: uint64
    copyMem(addr w, unsafeAddr s[i], 8)
    if (w and (w shl 1) and HighBits) != 0'u64:
      break
    i += 8
  while i < last:
    if isLeadByte(s[i].uint8):
      return i
    inc i
  last

proc advanceChainTo*(s: string, start, target: int, byteScan: bool): int {.inline.} =
  ## First scan position at/after ``target`` reachable from ``start``. Byte
  ## scans jump directly; char scans walk the ``encLen`` chain, but skip the
  ## stretches where it has no choice -- see ``isLeadByte`` -- because there
  ## the walk lands on the stretch's end exactly. Malformed UTF-8 is untouched
  ## -- a truncated or overlong sequence steps by its declared length, past
  ## ``target`` if that is where it lands, and is still stepped one character
  ## at a time. Exported so the equivalence probe and the internals test drive
  ## this walk rather than a copy of it.
  if byteScan:
    return clamp(target, start, s.len)
  result = start
  let stop = min(target, s.len)
  while result < stop:
    # A lead byte is its own answer; skipping only pays where ASCII runs, and
    # calling out for it on every character costs a dense non-ASCII subject.
    if isLeadByte(s[result].uint8):
      result = nextScanPos(s, result)
      continue
    let h = firstLeadByte(s, result, stop)
    if h >= stop:
      return stop
    result = nextScanPos(s, h)

proc regionStopHolds(s: string, l: int, prefix: set[uint8]): bool {.inline.} =
  ## Whether walk-back stop ``l`` holds. False inside a character or on a
  ## consumed multi-byte tail; always true on well-formed UTF-8.
  let lo = max(0, l - MaxCharByteLen)
  for i in countdown(l - 1, lo):
    let n = encLen(s[i].uint8)
    if n == 1:
      continue
    if i + n > l:
      return false # inside a character
    if i + n == l and i < l - 1:
      # Test the non-ASCII family; the decode skips checks and misreads overlongs.
      if 0x80'u8 in prefix:
        return false # a match consumes the character ending at ``l``
  true

proc lbHolds(s: string, p, offset: int, byte: uint8): bool {.inline.} =
  ## Whether ``p`` is a start the leading look-behind allows.
  p >= offset and s[p - offset].uint8 == byte

proc charHeadAt(s: string, p: int): bool {.inline.} =
  ## Whether the character walk can land on ``p``. On malformed input it may
  ## refuse a position the forward chain reaches, so a refusal stands the
  ## skip down rather than moving it.
  let lo = max(0, p - MaxCharByteLen)
  for i in countdown(p - 1, lo):
    let n = encLen(s[i].uint8)
    if n > 1 and i + n > p:
      return false
  true

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

proc enterLookaroundBody(ctx: MatchContext, limit: int) {.inline.} =
  ## Set the window a lookaround body runs under -- the general path's only
  ## move of ``lookLimit`` during a match ([leafBodyMatchesHere] lifts it in
  ## place for a leaf look-ahead):
  ##
  ## * ``lkAhead`` / ``lkNegAhead`` (and the ``(?(...)...)`` test): no window
  ##   (``NoLookLimit``). A look-ahead reads forward, outside the enclosing
  ##   body's span.
  ## * ``lkBehind`` / ``lkNegBehind``: ``limit`` when [bodyWindow] grants one,
  ##   else the running window untouched. A nested look-behind only narrows,
  ##   since its end sits inside the enclosing clip.
  ##
  ## Anchors are untouched; callers restore the window via ``save`` or by hand.
  ctx.lookLimit = limit

# Counters in this region are bounded by ``stepLimit`` / ``MaxStackBytes`` / the
# subject length, and ``lengthBounds`` guards overflow
# explicitly, so the checks would only cost the hot path instructions.
{.push overflowChecks: off.}

const CapSavesKeep = 4096 ## ``capSaves`` entries kept between searches (~64 KB).

const FramesKeep = 1600 ## ``frames`` entries kept between searches (~64 KB).

const ChoicesKeep = 768 ## ``choices`` entries kept between searches (~66 KB).

const CapUndosKeep = 2048
  ## ``capUndos`` entries kept between searches (~48 KB). One entry per group
  ## a kept body wrote, so it fills far more slowly than ``capSaves``.

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

template absentSuppressed(ctx: MatchContext): bool =
  ## Whether an absent operator here must refuse: it runs on the path of an
  ## enclosing absent's scan. See ``absentScan``.
  ctx.absentScan > 0

proc matchDiscardedBody(ctx: MatchContext, body: Node, cont: ContId): bool {.inline.} =
  ## Run a body whose backtracking the caller discards on success -- a
  ## lookaround, an atomic group, one possessive iteration. An absent
  ## operator inside one is unreachable by unwinding, so it runs unsuppressed.
  let saved = ctx.absentScan
  ctx.absentScan = 0
  result = matchWithCont(ctx, body, cont)
  ctx.absentScan = saved

proc pushCapUndo(ctx: MatchContext, idx: int32, span: Span) {.inline.} =
  ## Record one group's pre-image, growing only when full.
  if ctx.capUndosLen >= ctx.capUndos.len:
    # Half again rather than double: a run is retained for as long as its
    # entry lives, so the slack is paid for at the peak, not just held.
    ctx.capUndos.setLen(max(16, ctx.capUndos.len + ctx.capUndos.len div 2))
  ctx.capUndos[ctx.capUndosLen] = CapUndo(cuIdx: idx, cuSpan: span)
  inc ctx.capUndosLen
  if ctx.capUndosLen > ctx.capUndosPeak:
    ctx.capUndosPeak = ctx.capUndosLen

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

macro requireBitwiseCopyable(t: typedesc): untyped =
  ## Assert at compile time that every field of ``t`` owns nothing, so the
  ## whole object survives a bitwise copy.  Walks the variant, so branch
  ## fields are covered too, and the base objects, so an inherited field
  ## cannot slip past unchecked.
  ##
  ## A ``{.cursor.}`` borrow is *not* exempt, though ORC would make the field
  ## copyable: ``refc`` implements no ``{.cursor.}``, so such a field
  ## reinstates exactly the corruption ``storeSlot`` below describes.
  result = newStmtList()
  let
    checks = result
    tname = t.getTypeInst[1].strVal
  proc walk(n: NimNode) =
    case n.kind
    of nnkRecList, nnkRecCase, nnkRecWhen:
      for c in n:
        walk(c)
    of nnkOfBranch, nnkElifBranch, nnkElse:
      walk(n[^1])
    of nnkIdentDefs:
      # ``a, b: T`` declares every name but the last two nodes, which are the
      # type and the default value.
      let typ = parseExpr(n[^2].repr)
      for i in 0 ..< n.len - 2:
        var name = n[i]
        if name.kind == nnkPragmaExpr:
          # ``field {.pragma.}: T`` -- the pragma wraps the identifier.  No
          # pragma exempts a field from the check, so only the name matters.
          name = name[0]
        if name.kind == nnkPostfix:
          # ``payload*: T`` -- the export marker wraps the identifier, and
          # ``name.strVal`` would abort the macro instead of checking the field.
          name = name[1]
        checks.add nnkStaticStmt.newTree(
          newCall(
            # ``doAssert``, not ``assert``: ``--assertions:off`` (implied by
            # ``-d:danger``, a build mode the benchmarks use) erases the
            # latter even inside ``static``, dropping the guard exactly where
            # the ``copyMem`` below would turn into silent corruption.
            bindSym"doAssert",
            newCall(bindSym"supportsCopyMem", typ.copyNimTree),
            newLit(tname & "." & name.strVal & " is not bitwise-copyable"),
          )
        )
    else:
      discard

  proc walkObject(sym: NimNode) =
    ## Walk one object's own fields, then its base's.  Reaching for the
    ## typedef's ``RecList`` directly would silently skip everything inherited,
    ## and an owning inherited field would then pass the guard.
    let impl = sym.getImpl
    if impl.kind != nnkTypeDef or impl[2].kind != nnkObjectTy:
      error(
        tname & " is not a plain object: the bitwise-copy guard does not " &
          "know how to walk it",
        sym,
      )
    walk(impl[2][2])
    if impl[2][1].kind == nnkOfInherit:
      walkObject(impl[2][1][0])

  walkObject(t.getTypeInst[1])

template storeSlot(dst, src: untyped) =
  ## Move ``src`` into the popped buffer slot ``dst``.
  ##
  ## A ``copyMem``, under every memory management: assignment would call the
  ## ``=sink`` Nim gives every variant object, which zeroes the destination's
  ## old branch -- dead work on a popped slot that owns nothing -- before
  ## copying the new one in field by field.  A slot holds plain values only,
  ## which ``requireBitwiseCopyable`` keeps true, so the whole store is one
  ## ``sizeof(dst)`` move.
  ##
  ## Naming a node by [NodeId] is what lets this be unconditional.  While the
  ## slots held a ``Node``, ``refc``'s marker visited that field in every
  ## slot, stale ones included, so a raw store wrote the pointer without the
  ## matching increment and the marker's later decrement freed a live node.
  # Both ends are sized from ``dst``, so a ``src`` of a different type would
  # be overread.  This is what keeps that from happening.
  static:
    doAssert typeof(dst) is typeof(src),
      "storeSlot: " & $typeof(src) & " does not fit a " & $typeof(dst) & " slot"
  copyMem(addr dst, addr src, sizeof(dst))

# The precondition for ``pushFrame``'s ``copyMem`` store below.  An owning
# field added to the variant (a ``seq``, say) would otherwise compile silently
# and then leak the overwritten slot and double-free the pushed temporary.
requireBitwiseCopyable(Frame)

proc pushFrame(ctx: MatchContext, frame: sink Frame): ContId {.inline.} =
  ## Push a frame and return its index.  The pusher must pop it
  ## (``ctx.framesLen = fid``) before returning to its caller.
  ##
  ## ``sink`` keeps the parameter callee-owned: an lvalue argument -- say
  ## ``pushFrame(ctx, ctx.frames[i])`` -- is materialised into a temporary, so
  ## the growth below cannot reallocate the buffer out from under the store's
  ## source.  The temporary costs nothing to discard for the same reason the
  ## store below is a plain move.
  ##
  ## ``storeSlot`` above explains the store.
  if ctx.framesLen >= ctx.frames.len:
    ctx.frames.setLen(max(16, ctx.frames.len * 2))
  result = ctx.framesLen.int32
  storeSlot(ctx.frames[ctx.framesLen], frame)
  inc ctx.framesLen

# The same precondition, for ``pushChoice``'s store below.  ``Choice`` has more
# branches than ``Frame``, so an owning field is that much likelier to land in
# one of them.
requireBitwiseCopyable(Choice)

proc pushChoice(ctx: MatchContext, choice: sink Choice) {.inline.} =
  ## Push a backtrack entry, growing only when full.
  ##
  ## ``sink`` and ``storeSlot`` for the reasons ``pushFrame`` above gives;
  ## like ``Frame``, ``Choice`` holds plain values only.
  if ctx.choicesLen >= ctx.choices.len:
    ctx.choices.setLen(max(16, ctx.choices.len * 2))
  storeSlot(ctx.choices[ctx.choicesLen], choice)
  inc ctx.choicesLen
  if ctx.choicesLen > ctx.choicesPeak:
    ctx.choicesPeak = ctx.choicesLen

template copyCaptures(dst, src, n: untyped) =
  ## ``Span`` is a plain two-int value, so a snapshot moves in one block.
  ## A template so the ``addr`` operands are only taken when ``n > 0``.
  if n > 0:
    copyMem(addr dst, addr src, n * sizeof(Span))

proc `==`(a, b: CapOff): bool {.borrow.}
proc `<`(a, b: CapOff): bool {.borrow.}

const NoCapOff = CapOff(-1)
  ## "This snapshot pushed no slot."  The ``doAssert``s below catch a use of
  ## one; the bounds check cannot, since ``-d:danger`` removes it and a
  ## ``copyMem`` from ``capSaves[-1]`` then corrupts the heap silently.

proc capMark(ctx: MatchContext): CapOff {.inline.} =
  ## The current top of ``capSaves``, for trimming back to later.
  CapOff(ctx.capSavesLen)

template checkSlot(ctx: MatchContext, off: CapOff) =
  ## Bounds check for a slot of the explicit-length ``capSaves`` buffer: the
  ## seq itself is never shrunk, so its own check cannot see a released slot.
  ## Dropped under danger.
  assert int(off) + ctx.captures.len <= ctx.capSavesLen, "read a released capture slot"

proc releaseTo(ctx: MatchContext, off: CapOff) {.inline.} =
  ## Release ``off``'s slot and everything above it.
  doAssert off != NoCapOff, "released a snapshot that pushed no slot"
  ctx.capSavesLen = int(off)

proc retainSlot(ctx: MatchContext, off: CapOff) {.inline.} =
  ## Release everything above ``off``'s slot but keep the slot itself, so a
  ## later rollback can still read it.  The one place that knows a slot is
  ## ``captures.len`` elements wide rather than one.
  doAssert off != NoCapOff, "retained a snapshot that pushed no slot"
  ctx.capSavesLen = int(off) + ctx.captures.len

proc capturesBackTo(ctx: MatchContext, off: CapOff) {.inline.} =
  ## Copy the slot at ``off`` back into ``ctx.captures``, leaving it in place.
  doAssert off != NoCapOff, "restored a snapshot that pushed no slot"
  ctx.checkSlot off
  copyCaptures(ctx.captures[0], ctx.capSaves[int(off)], ctx.captures.len)

proc pushCaptures(ctx: MatchContext): CapOff {.inline.} =
  ## Copy ``ctx.captures`` onto the side stack and return its slot offset.
  result = capMark(ctx)
  let n = ctx.captures.len
  let top = int(result) + n
  if top > ctx.capSaves.len:
    ctx.capSaves.setLen(max(top, max(64, ctx.capSaves.len * 2)))
  copyCaptures(ctx.capSaves[int(result)], ctx.captures[0], n)
  ctx.capSavesLen = top
  if top > ctx.capSavesPeak:
    ctx.capSavesPeak = top

proc popCapturesTo(ctx: MatchContext, off: CapOff) {.inline.} =
  ## Copy the slot at ``off`` back into ``ctx.captures`` and release it.
  capturesBackTo(ctx, off)
  releaseTo(ctx, off)

template altCheckPush(ctx: MatchContext) =
  ## Debug builds only: snapshot the captures for the alternation choice just
  ## pushed.  An alternation takes no snapshot of its own, since every capture
  ## written after its choice point carries an undo popped first; the debug
  ## pops assert that, so a writer that leaves none fails the suites rather
  ## than an answer.
  when not defined(release):
    ctx.choices[ctx.choicesLen - 1].aCapCheck = pushCaptures(ctx)

template altCheckPop(ctx: MatchContext, top: int) =
  ## Debug builds only: the captures are what [altCheckPush] saw.
  when not defined(release):
    let off = int(ctx.choices[top].aCapCheck)
    for i in 0 ..< ctx.captures.len:
      doAssert ctx.capSaves[off + i] == ctx.captures[i],
        "a capture written after an alternation left no undo"

template altCheckDrop(ctx: MatchContext, top: int) =
  ## Debug builds only: release [altCheckPush]'s slot with its choice.
  when not defined(release):
    releaseTo(ctx, ctx.choices[top].aCapCheck)

proc saveScalars(ctx: MatchContext): ScalarState {.inline.} =
  ## Snapshot everything but the capture vector.  Nothing is pushed onto
  ## ``capSaves``, so the result rolls back with ``restoreScalars`` only.
  ScalarState(
    pos: ctx.pos,
    flags: ctx.flags,
    keepStart: ctx.keepStart,
    absentEnd: ctx.absentEnd,
    lookLimit: ctx.lookLimit,
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
  ctx.absentEnd = s.absentEnd
  ctx.lookLimit = s.lookLimit
  ctx.graphemeMode = s.graphemeMode

proc restoreScalarsKeepingStart(ctx: MatchContext, s: ScalarState) {.inline.} =
  ## Roll back to ``s`` as ``restoreScalars`` does, but leave ``keepStart``
  ## where the body left it.  Oniguruma keeps a ``\K`` inside a positive
  ## lookaround the way it keeps the captures: the assertion is zero-width, yet
  ## the match start it moved survives.  The caller's rollback still carries the
  ## old ``keepStart``, so backtracking past the lookaround undoes this along
  ## with the captures -- except on the ``lookBodyPure`` path, which pushes
  ## none, and is safe only because ``markQuantBodyPure`` calls ``akKeep``
  ## impure.
  ##
  ## A body may run past where the outer match ends, so the kept start can sit
  ## ahead of it.  Every site that reports it clamps to the match end, the way
  ## Oniguruma's ``OP_END`` does with ``(pkeep > s) ? s : pkeep``.
  let kept = ctx.keepStart
  restoreScalars(ctx, s)
  ctx.keepStart = kept

proc restore(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Roll back to ``s`` and release its slot on the side stack.
  restoreScalars(ctx, s.scalars)
  popCapturesTo(ctx, s.capOff)

proc rewind(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Roll back to ``s`` but keep its slot, so it can be replayed again.
  ## The caller is responsible for releasing the stack afterwards.
  restoreScalars(ctx, s.scalars)
  capturesBackTo(ctx, s.capOff)

proc drop(ctx: MatchContext, s: SavedState) {.inline.} =
  ## Release ``s``'s slot without rolling anything back.  Only legal when the
  ## body above it wrote no captures, or a retained snapshot below ``s``
  ## already undoes them (as a ``chLookbehindAlt`` entry does).  Otherwise the
  ## caller wants ``keepCaptures``.
  releaseTo(ctx, s.capOff)

proc keptCaptureChoice(ctx: MatchContext, s: SavedState, framesLen: int32): Choice =
  ## Build the rollback a caller leaves behind for the captures a body wrote
  ## above ``s``, consuming ``s``'s slot either way.  The caller pushes the
  ## result, or writes it over an entry it already owns.  Every construct that
  ## keeps captures past its own scope needs one: the nested machine released
  ## its ``chUndoCapture`` entries on the way out, so without an entry here
  ## the captures leak past the enclosing construct.
  ##
  ## Retaining the snapshot costs a ``Span`` per group in the pattern however
  ## few the body touched; a run of changed groups costs a wider entry each
  ## but only for those.  So count first and take the cheaper one, crossing
  ## over at a third of the vector rather than the two thirds the sizes
  ## suggest, since a run lives in a buffer that grows in steps.  The two are
  ## equivalent: a write made after this entry carries its own undo, popped
  ## first, so every group outside the run already holds the snapshot's value.
  doAssert s.capOff != NoCapOff, "kept the captures of a snapshot that pushed no slot"
  ctx.checkSlot s.capOff
  let n = ctx.captures.len
  let base = int(s.capOff)
  var changed = 0
  for i in 0 ..< n:
    if ctx.capSaves[base + i] != ctx.captures[i]:
      inc changed
  if changed * sizeof(CapUndo) * 2 >= n * sizeof(Span):
    retainSlot(ctx, s.capOff)
    return Choice(kind: chUndoState, usFramesLen: framesLen, usSaved: s)
  let off = int32(ctx.capUndosLen)
  for i in 0 ..< n:
    if ctx.capSaves[base + i] != ctx.captures[i]:
      pushCapUndo(ctx, int32(i), ctx.capSaves[base + i])
  releaseTo(ctx, s.capOff)
  Choice(
    kind: chUndoSparse, upFramesLen: framesLen, upUndoOff: off, upScalars: s.scalars
  )

proc keepCaptures(ctx: MatchContext, s: SavedState) =
  ## Commit to captures written above ``s``, leaving ``s`` behind as their
  ## rollback in whichever shape ``keptCaptureChoice`` picks.
  ctx.pushChoice keptCaptureChoice(ctx, s, ctx.framesLen.int32)

proc keepLookCaptures(
    ctx: MatchContext, node: Node, s: SavedState, keepKeptStart = true
) =
  ## Finish a positive lookaround that matched: roll the scalars back to ``s``
  ## and keep what the (zero-width) body captured.  A lookaround commits to
  ## its first answer, so the entry only ever undoes; a divided look-behind
  ## (``lookDivided``), which does retry, keeps its own ``chLookbehindAlt``
  ## snapshot instead.
  ## ``\K`` is kept alongside the captures -- see
  ## ``restoreScalarsKeepingStart``.  The two are separate policies: a caller
  ## that wants only the captures passes ``keepKeptStart = false``, which is
  ## what a *failed* negative assertion does.
  if keepKeptStart:
    restoreScalarsKeepingStart(ctx, s.scalars)
  else:
    restoreScalars(ctx, s.scalars)
  if node.lookBodyPure:
    releaseTo(ctx, s.capOff)
  else:
    keepCaptures(ctx, s)

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
  # in ``ckRestoreAbsentEnd`` frames for explicit unwind.
  #
  # Serves the ``runCont`` path; the loop answers markers inline.
  let base = ctx.framesLen
  var i = idx
  # Head of the ``ckRestoreAbsentEnd`` chain for the tail walk.
  var tail = cont
  while true:
    if i >= nodes.len:
      # Run the chained tail through the loop, then unwind.
      let ok = runContFromMachine(ctx, tail)
      unwindAbsentFrames(ctx, base)
      return ok
    let node = nodes[i]
    # Under an enclosing scan the markers are not shortcuts but refusals, so
    # let the general path answer them; see ``absentScan``.
    if node.kind == nkAbsent and node.absentKind == abRange and not ctx.absentSuppressed:
      # (?~|absent): narrow range to exclude absent.
      let rangeStart = ctx.pos
      let absentPos = findAbsentPos(ctx, node.absentBody, rangeStart)
      let savedEnd = ctx.absentEnd
      ctx.absentEnd = absentPos
      tail = pushFrame(
        ctx,
        Frame(
          kind: ckRestoreAbsentEnd,
          parent: tail,
          reSavedEnd: savedEnd,
          reAbsentPos: absentPos,
        ),
      )
      inc i
      continue
    if node.kind == nkAbsent and node.absentKind == abClear and not ctx.absentSuppressed:
      # (?~|): clear absent range limit.
      ctx.absentEnd = ctx.subject.len
      inc i
      continue
    if i + 1 >= nodes.len:
      # Last child: its continuation *is* ``tail``, so skip the frame entirely.
      let ok = matchWithCont(ctx, nodes[i], tail)
      unwindAbsentFrames(ctx, base)
      return ok
    let fid = pushFrame(
      ctx,
      Frame(kind: ckSeqContinue, parent: tail, sNode: parent.id, sIdx: int32(i + 1)),
    )
    let ok = matchWithCont(ctx, nodes[i], fid)
    unwindAbsentFrames(ctx, base)
    return ok

proc unwindAbsentFrames(ctx: MatchContext, base: int) =
  ## Pop frames pushed by ``matchSeqCont`` and widen each ``absentEnd`` they
  ## narrowed.
  while ctx.framesLen > base:
    dec ctx.framesLen
    if ctx.frames[ctx.framesLen].kind == ckRestoreAbsentEnd:
      ctx.absentEnd = ctx.frames[ctx.framesLen].reSavedEnd

proc matchEncodedBytes(ctx: MatchContext, target: Rune, p: int): int =
  ## [matchBytes] for a character of more than one byte.
  var buf: array[4, char]
  let n = utf8Encode(int32(target), buf)
  if p + n > ctx.subjectEnd:
    return -1
  for i in 0 ..< n:
    if ctx.subject[p + i] != buf[i]:
      return -1
  p + n

proc matchBytes(ctx: MatchContext, target: Rune, p: int): int {.inline.} =
  ## Compare the encoding of ``target`` against the subject at ``p``.
  ## Returns the position just past it, or -1 on mismatch.  Oniguruma holds a
  ## case-sensitive literal as the bytes it was written with and compares
  ## those, so this never decodes the subject: an overlong encoding of the
  ## same code point is a different byte string and does not match.
  if int32(target) < 0x80:
    # One byte, and no encoding to build for it.
    if p < ctx.subjectEnd and ctx.subject[p] == char(int32(target)):
      p + 1
    else:
      -1
  else:
    matchEncodedBytes(ctx, target, p)

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
    # Resolve the cluster against the consumption window, not the subject:
    # one running past it ends at it.
    template clipped(): untyped =
      toOpenArray(ctx.subject.data, 0, ctx.subjectEnd - 1)

    let clusterEnd =
      if ctx.graphemeMode == gmWord:
        nextWordSegmentEnd(clipped(), start)
      else:
        nextGraphemeClusterEnd(clipped(), start)
    return if clusterEnd > start: clusterEnd else: -1

  # ASCII fast path.  A byte below 0x80 is a one-byte character that decodes
  # to itself and that ``codeIsClassifiable`` admits, so the type is one
  # membership test on it.  ``\R`` is the exception: "\r\n" is one match two
  # bytes wide.
  let lead = ctx.subject[start].uint8
  if lead < 0x80 and ct != ctNewlineSeq:
    if ct == ctDot and rfMultiLine in ctx.flags:
      return start + 1
    return
      if lead in AsciiCharTypeSets[ct]:
        start + 1
      else:
        -1

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
    ctx.pos == 0 or
      (ctx.pos > 0 and ctx.pos < ctx.subject.len and ctx.subject[ctx.pos - 1] == '\n')
  of akLineEnd:
    ctx.pos >= ctx.subject.len or ctx.subject[ctx.pos] == '\n'
  of akStringBegin:
    moNotBeginString notin ctx.matchOptions and ctx.pos == 0
  of akStringEnd:
    ctx.pos >= ctx.subject.len
  of akStringEndOrNewline:
    ctx.pos >= ctx.subject.len or
      (ctx.pos == ctx.subject.len - 1 and ctx.subject[ctx.pos] == '\n')
  of akSearchBegin:
    moNotBeginPosition notin ctx.matchOptions and ctx.pos == ctx.searchStart
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

proc progressedSince(ctx: MatchContext, snap: CapOff, groups: uint32): bool {.inline.} =
  ## Whether an iteration that ended where it began still counts as one, so
  ## the repeat goes on instead of stopping there: Oniguruma's
  ## ``STACK_EMPTY_CHECK_MEM``.  It does when a group in ``groups`` (the
  ## repeat's ``Regex.emptyStatus``) was set for the first time, or moved --
  ## unless it was empty before and is empty still, since an empty span reads
  ## the same wherever it sits.  ``snap`` holds the captures as the iteration
  ## found them; ``NoCapOff`` means a body that writes none.  No other change
  ## counts, as in Oniguruma's ``EMPTY_CHECK_END``.
  ##
  ## Not modelled: Oniguruma writes a repeat's required iterations, and every
  ## iteration of a small bounded greedy one, out as copies with no empty
  ## check, when the copies fit in ``QUANTIFIER_EXPAND_LIMIT_SIZE`` (10)
  ## opcodes.  So ``^(?:\1a|())+$`` matches "a" there and not here.  Which
  ## form a body gets depends on its compiled length, which reni does not
  ## reproduce; every iteration here is checked, as Oniguruma checks a body
  ## too long to copy.
  if groups == 0 or snap == NoCapOff:
    return false
  ctx.checkSlot snap
  let base = int(snap)
  # Groups 1 up to ``groupSlots`` and below 32, set bits only: a repeat
  # watches few of the pattern's groups.
  var rest = groups and not 1'u32
  if ctx.groupSlots < 32:
    rest = rest and ((1'u32 shl ctx.groupSlots) - 1)
  while rest != 0:
    let g = countTrailingZeroBits(rest)
    rest = rest and (rest - 1)
    let before = ctx.capSaves[base + g]
    let after = ctx.captures[g]
    if (after.a == before.a and after.b == before.b) or after.a < 0:
      continue
    if before.a < 0 or before.a != before.b or after.a != after.b:
      return true
  false

proc emptyPassProgressed(
    ctx: MatchContext, snap: CapOff, groups: uint32
): bool {.noinline.} =
  ## [progressedSince], out of line: the possessive repeat's empty check.
  progressedSince(ctx, snap, groups)

proc emptyPassProgressed(ctx: MatchContext, cont: ContId): bool {.noinline.} =
  ## [progressedSince] for the iteration repeat frame ``cont`` closes.  Out
  ## of line, with the frame reads, so the rare path costs ``runMachine``
  ## nothing it would spend on the common one.
  progressedSince(
    ctx, ctx.frames[cont].qSnap, ctx.regex[].emptyStatus(ctx.frames[cont].qBody)
  )

proc classBitmapAnswers*(node: Node, b: uint8, flags: RegexFlags): bool {.inline.} =
  ## Whether ``node``'s precomputed ASCII bitmap settles byte ``b`` on its own.
  ## The one place this gate is written; every reader of ``asciiSet`` must ask
  ## here instead of restating it.  Below 0x80 the byte is a one-byte character
  ## that decodes to itself, and the bitmap is built without case folding, so
  ## ``rfIgnoreCase`` sends the matcher back to the atoms.
  b < 0x80 and node.asciiSetOk and rfIgnoreCase notin flags

proc classHasByte(node: Node, b: uint8, flags: RegexFlags): bool =
  ## Whether one-byte char ``b`` is in the class byte set. Below U+0080 the
  ## member test answers; above only ranges crossing the ASCII boundary reach.
  ## No bitmap read here: the only caller is [classAdvance], past its fast
  ## path, so a byte the bitmap settles never arrives.
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

proc classFoldsApply(ctx: MatchContext, node: Node): bool {.inline.} =
  ## [leafgate.classFoldsApply] under the flags in force.
  classFoldsApply(node, ctx.flags)

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

  # ASCII fast path: one bit test on an exact bitmap, the same answer
  # [classHasByte] gives but without the decode, negation applied here.  The
  # gate rules out ``rfIgnoreCase``, so no fold variant exists and the variant
  # arm below is answered with -1 rather than run.
  let lead = ctx.subject[start].uint8
  if classBitmapAnswers(node, lead, ctx.flags):
    if variant < MultiCharFolds.len:
      return -1
    return
      if (lead in node.asciiSet) != node.negated:
        start + 1
      else:
        -1

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
    if node.solePropOk:
      # One property and nothing else; ``ccNegUnicodeProp`` is the same lookup
      # read the other way round.
      anyMatch =
        matchUnicodeProp(r, node.atoms[0].prop, ctx.flags) ==
        (node.atoms[0].kind == ccUnicodeProp)
    else:
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

template isSingleWayLeaf(ctx: MatchContext, node: Node): bool =
  ## Whether ``node`` matches at most one way here; see [LeafGate].
  if ctx.gates != nil and ctx.flags == ctx.boundFlags:
    ctx.gateAt(node.id).singleWay
  else:
    singleWayLeaf(node, ctx.flags)

proc leafRunAccepts(
    ctx: MatchContext, node: Node, accept: var set[uint8]
): bool {.inline.} =
  ## The ASCII bytes ``node`` accepts here, or false when no byte set decides
  ## it; see [LeafGate].
  if ctx.gates != nil and ctx.flags == ctx.boundFlags:
    let gate = ctx.gateAt(node.id)
    # ``.`` is a cluster in grapheme mode, which the table is not derived under.
    if not gate.runnable or (gate.graphemeDep and ctx.graphemeMode != gmNone):
      return false
    accept = gate.accept
    return true
  if leafRunGraphemeDep(node) and ctx.graphemeMode != gmNone:
    return false
  leafRunAccepts(node, ctx.flags, accept)

proc leafRunEnd(ctx: MatchContext, accept: set[uint8], limit: int): int {.inline.} =
  ## End of the run of bytes ``accept`` admits from ``ctx.pos``, stopping at
  ## ``limit``. A byte outside the set ends the run, not the repeat: the
  ## caller's per-repetition loop carries on from here.
  var p = ctx.pos
  while p < limit and ctx.subject[p].uint8 in accept:
    inc p
  p

template leafRunSpan(ctx: MatchContext, node: Node, qmax: int): int =
  ## Bytes of ``node``'s ASCII run from ``ctx.pos``, capped at ``qmax``
  ## repetitions (``qmax < 0`` is unbounded), or 0 when no byte set decides
  ## ``node``. ``ctx.pos`` is left to the caller; the steps are not -- one is
  ## charged per repetition, as ``matchWithCont`` charges them, so the same
  ## count raises on the same inputs.
  ##
  ## The scan stops one byte past what the budget can pay for, so the limit
  ## bounds the work and not only the verdict.
  ##
  ## A template, not a proc: both repeat arms go through here on the hot path,
  ## where a call costs more than a short run saves.
  block:
    var accept: set[uint8]
    var span = 0
    if leafRunAccepts(ctx, node, accept):
      var limit =
        if qmax < 0:
          ctx.subjectEnd
        else:
          min(ctx.subjectEnd, ctx.pos + qmax)
      # ``ctx.steps <= ctx.stepLimit`` on entry, so the budget is
      # non-negative; comparing it against the room left keeps an unlimited
      # limit from overflowing.
      let budget = ctx.stepLimit - ctx.steps
      if budget < limit - ctx.pos:
        limit = ctx.pos + budget + 1
      span = leafRunEnd(ctx, accept, limit) - ctx.pos
      if span > 0:
        ctx.steps += span
        if ctx.steps > ctx.stepLimit:
          raise newException(RegexLimitError, "match step limit exceeded")
    span

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

const LeadLeafTrial = 32'i32 ## Positions answered before reading the refusal rate.

const LeadLeafPayoff = 8'i32
  ## Minimum refusal rate to stay on: one in eight. A refusal saves a whole
  ## attempt, worth well over eight character tests.

const RegionTrial = 32 ## Occurrences answered before a useless region stands down.

const RegionPayoff = 4 ## Average skipped bytes per occurrence for the region to pay off.

const LeadLeafRetry = 4096'i32 ## Positions an off prefilter sits out before retry.

const LeadLeafCapacity = 256'i32
  ## Counter ceiling: both counters halve here, keeping the recent ratio
  ## without reaching the int32 limit.

proc leadLeafEnd(ctx: MatchContext, node: Node): int {.inline.} =
  ## End offset of the leaf matched at ``ctx.pos``, or -1. One character test,
  ## no writes. ``nkString`` tests the whole run; only the lazy scan reaches it.
  case node.kind
  of nkLiteral, nkEscapedLiteral:
    leafVariantAdvance(ctx, node, 0)
  of nkCharClass:
    leafVariantAdvance(ctx, node, classFirstVariant(ctx, node))
  of nkCharType:
    charTypeAdvance(ctx, node.charType)
  of nkString:
    stringAdvance(ctx, node)
  else:
    raiseAssert "leadLeaf is not a leaf kind"

proc leadLeafMatches(ctx: MatchContext, node: Node): bool {.inline.} =
  ## Whether the leaf matches at ``ctx.pos``.
  leadLeafEnd(ctx, node) >= 0

proc leadRepeatHolds(ctx: MatchContext, node: Node): bool {.inline.} =
  ## Whether the leaf at ``ctx.pos`` is followed by the same bytes
  ## (``(leaf)\1``). Byte comparison only; folding is excluded by the compiler.
  let e = leadLeafEnd(ctx, node)
  if e < 0:
    return false
  let w = e - ctx.pos
  if e + w > ctx.subjectEnd:
    return false
  equalMem(addr ctx.subject.data[ctx.pos], addr ctx.subject.data[e], w)

proc lazyScanAdvance(
    ctx: MatchContext, body, nextLeaf: Node, count: var int32, maxRep: int32
): bool =
  ## Step ``body`` forward to where ``nextLeaf`` matches. ``count`` and
  ## ``ctx.pos`` are left at what the walk reached; the caller restores them
  ## on a false. One scan suffices since a single-way body has no second way
  ## per repetition.
  while true:
    if ctx.pos < ctx.subjectEnd and leadLeafMatches(ctx, nextLeaf):
      return true
    if maxRep >= 0 and count >= maxRep:
      return false
    let before = ctx.pos
    if not matchWithCont(ctx, body, TrueCont):
      ctx.pos = before
      return false
    if ctx.pos == before:
      return false # zero-width: a single-way leaf cannot vary, so stop
    inc count

proc isLeafLookbehindBody(node: Node): bool {.inline.} =
  ## Whether a lookbehind body is a single leaf, and so answerable in place by
  ## [leafBodyEndsAt].  Only the kinds [lengthBounds] gives a fixed width are
  ## listed, since a fixed width is what every caller gates on.
  node != nil and node.kind in {nkString, nkLiteral, nkEscapedLiteral}

proc leafBodyEndsAt(ctx: MatchContext, body: Node, targetEnd: int, fbl: int): bool =
  ## Whether leaf ``body`` matches the ``fbl`` bytes ending at ``targetEnd``.
  ##
  ## The general path's frame, matcher re-entry and save/restore roll back
  ## what a leaf never writes: ``ctx.pos`` is all of it, restored here.  The
  ## caller must have checked [isLeafLookbehindBody].
  let st = targetEnd - fbl
  if st < 0:
    return false
  inc ctx.steps
  if ctx.steps > ctx.stepLimit:
    raise newException(RegexLimitError, "match step limit exceeded")
  let entryPos = ctx.pos
  ctx.pos = st
  # Only the first way need be tried: a literal's second is the
  # multi-character fold, and one that has it carries no fixed width.
  let matched =
    if body.kind == nkString:
      stringAdvance(ctx, body) == targetEnd
    else:
      leafVariantAdvance(ctx, body, 0) == targetEnd
  ctx.pos = entryPos
  matched

proc isLeafLookaheadBody(node: Node): bool {.inline.} =
  ## Whether a look-ahead body is a single leaf, and so answerable in place by
  ## [leafBodyMatchesHere].  Wider than [isLeafLookbehindBody], which needs a
  ## fixed width to compare an end offset against; a look-ahead has none.
  node != nil and
    node.kind in {nkString, nkLiteral, nkEscapedLiteral, nkCharClass, nkCharType}

proc leafBodyMatchesHere(ctx: MatchContext, body: Node): bool =
  ## Whether leaf ``body`` matches at ``ctx.pos``.  The general path's frame,
  ## re-entry and save/restore roll back what a leaf never writes: it holds no
  ## capture, no ``\K``, no flag group and no absent operator -- the whole of
  ## what ``markQuantBodyPure`` reads -- and the advances leave ``ctx.pos``
  ## alone.  The caller must have checked [isLeafLookaheadBody].
  inc ctx.steps
  if ctx.steps > ctx.stepLimit:
    raise newException(RegexLimitError, "match step limit exceeded")
  # Lift the look-behind window as ``enterLookaroundBody`` does for the general
  # path: ``subjectEnd`` reads it back through ``lookLimit``.
  let savedLimit = ctx.lookLimit
  ctx.lookLimit = NoLookLimit
  case body.kind
  of nkString:
    result = stringAdvance(ctx, body) >= 0
  of nkCharType:
    result = charTypeAdvance(ctx, body.charType) >= 0
  else:
    # Every way, not just the first: [leafBodyEndsAt] may stop there because a
    # multi-character fold carries no fixed width, and this has no width to
    # gate on -- under ``(?i)``, ``(?=ß)`` has to reach "ss".
    let lastVariant = if body.kind == nkCharClass: ClassVariants else: LiteralVariants
    var v =
      if body.kind == nkCharClass:
        classFirstVariant(ctx, body)
      else:
        0
    result = false
    while v < lastVariant:
      if leafVariantAdvance(ctx, body, v) >= 0:
        result = true
        break
      inc v
  ctx.lookLimit = savedLimit

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

proc nextTrieBranch(
    ctx: MatchContext, trie: AltTrie, start: int32
): tuple[idx: int32, endPos: int] =
  ## Lowest-numbered alternative at or after ``start`` whose literal the
  ## subject spells at ``ctx.pos``, and the offset just past it.  ``idx`` is
  ## -1 when none does.  One walk answers the whole alternation: the caller
  ## never compares those bytes again.
  ##
  ## The order is the alternation's own, not the trie's -- two branches can
  ## both match here (``int`` and ``int8`` at ``int8``) -- which is why the
  ## terminals carry their index.
  ##
  ## Re-walked on each backtrack rather than cached, for the reason
  ## [nextAltBranch] gives: ``subjectEnd`` moves under a running match.
  result = (idx: -1'i32, endPos: 0)
  var p = ctx.pos
  if p >= ctx.subjectEnd or uint8(ctx.subject[p]) notin trie.firstBytes:
    # Nothing the root can step on, and ``buildAltTrie`` refuses an empty
    # branch, so there is no root terminal either.
    return
  var state = 0'i32
  while true:
    let st = trie.states[state]
    for k in st.termOff ..< st.termOff + st.termLen:
      let ti = trie.terms[k]
      if ti < start:
        continue
      if result.idx < 0 or ti < result.idx:
        result.idx = ti
        result.endPos = ctx.pos + int(st.depth)
      else:
        # The run is ascending, so nothing further in it can beat ``idx``.
        break
    if result.idx == start:
      # ``start`` is the floor the caller asked from, so nothing deeper can
      # be admitted earlier.  Stopping here keeps ``(a|aaaaaaaa...)`` from
      # spelling out the long branch at every position and every backtrack.
      return
    if p >= ctx.subjectEnd:
      return
    let b = uint8(ctx.subject[p])
    # A wide state steps from its row in one load; a narrow one walks its
    # ascending edges, which gives up in a compare or two.
    var nxt = -1'i32
    if st.rowOff >= 0:
      nxt = trie.rows[st.rowOff + int32(b)]
    else:
      for e in st.edgeOff ..< st.edgeOff + st.edgeLen:
        if trie.edges[e].label == b:
          nxt = trie.edges[e].next
          break
        if trie.edges[e].label > b:
          break
    if nxt < 0:
      return
    state = nxt
    inc p

proc prevCharCode(s: openArray[char], pos: int): int32 =
  ## Code point ending just before ``pos``, or -1 at 0. Always defined for
  ## ``pos > 0``.
  if pos <= 0:
    return -1
  var q: int
  prevCharAt(s, pos, q)

proc matchWordBoundary(ctx: MatchContext): bool =
  let asciiOnly = rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags
  # ``\b`` is zero-width, so it reads the real next character: an absent
  # range and a look-behind window bound only consumption.  The start of the
  # subject is the exception, as in Oniguruma (``DATA_ENSURE(1)`` in
  # ``WORD_BOUNDARY``): an empty range there is an empty string, which has no
  # boundary.  Fixed-length look-behind bodies take no window (see
  # tuneLookBehinds) and still hold at 0.
  if ctx.pos == 0 and ctx.subjectEnd == 0:
    return false
  let prevIsWord =
    if ctx.pos > 0:
      # UTF-8 is self-synchronising: a byte below 0x80 is a whole character
      # that [isWordChar] answers from the ASCII table whatever
      # ``asciiOnly`` says. The same answer, without the backward walk.
      let prev = ctx.subject[ctx.pos - 1].uint8
      if prev < 0x80:
        asciiHas(int32(prev), acWord)
      else:
        isWordChar(Rune(prevCharCode(ctx.subject.oa, ctx.pos)), asciiOnly)
    else:
      false
  let nextIsWord =
    if ctx.pos < ctx.subject.len:
      let lead = ctx.subject[ctx.pos].uint8
      if lead < 0x80:
        # As above, and a one-byte decode cannot be truncated.
        asciiHas(int32(lead), acWord)
      else:
        var code: int32
        var next: int
        # ``\b`` reads the code point directly, like ``\w``: no class
        # containers are involved, so a one-byte character above U+007F counts.
        decodeAt(ctx.subject.oa, ctx.pos, code, next) and
          isWordChar(Rune(code), asciiOnly)
    else:
      false
  prevIsWord xor nextIsWord

proc leadAnchorsHold(ctx: MatchContext): bool {.inline.} =
  ## Whether every leading assertion holds at ``ctx.pos``.
  for i in 0 ..< ctx.leadAnchorsLen:
    let a = ctx.leadAnchors[i]
    let holds =
      case a
      of akWordBoundary:
        matchWordBoundary(ctx)
      of akNotWordBoundary:
        not matchWordBoundary(ctx)
      else:
        anchorHolds(ctx, a)
    if not holds:
      return false
  true

proc openSpan(held: Span): Span {.inline.} =
  ## The slot of a set group ``Regex.opensUnset`` names while the group is
  ## open: unset to every reader that tests ``a >= 0`` -- a plain reference,
  ## a conditional -- yet still holding ``held``, the span the group last
  ## closed with, for a reference with a level ([lastClosed]).  In the slot
  ## itself, so every snapshot and rollback carries it along.
  Span(a: -2 - held.a, b: held.b)

proc lastClosed(s: Span): Span {.inline.} =
  ## What a reference with a level reads in a capture slot: the span, or for
  ## an open group the one [openSpan] holds.  Oniguruma's
  ## ``BACKREF_WITH_LEVEL`` walks its stack for the last span the group
  ## closed, so the open group does not hide it there.  It counts call depth
  ## on that walk and this does not; see ``backrefLeveled``.
  if s.a <= -2:
    Span(a: -2 - s.a, b: s.b)
  else:
    s

proc openedSlot(ctx: MatchContext, capIdx: int): int {.inline.} =
  ## Where ``trackOpenOrder`` keeps when group ``capIdx``'s span opened: in
  ## ``captures`` past the groups, so every snapshot and rollback carries it
  ## along with the span.  ``a`` holds the [openStamp], or -1 while the group
  ## has closed no span.  A subtraction (see ``Regex.openedLast``): a table
  ## of slots measured 5% dearer on ``(?:(?<n>a)|(?<n>\w))\k<n+0>``.
  int(ctx.openedBase) + capIdx

proc openClockSpent(ctx: MatchContext) {.noinline.} =
  ## [openStamp]'s clock is at ``int32.high``.  Under ``trackOpenOrder`` a
  ## wrapped stamp would lose the order, or read 0 and record no close, so
  ## the attempt raises; without it nothing compares the stamps, and the
  ## clock starts over.  Out of line, so the test adds no raise to the loop.
  if ctx.trackOpenOrder:
    raise newException(RegexLimitError, "match group entry limit exceeded")
  ctx.openClock = 0

proc openStamp(ctx: MatchContext): int32 {.inline.} =
  ## The stamp of a group something reads, entered now ([clearOnOpen]):
  ## later than every stamp before it in the attempt.  Only
  ## ``trackOpenOrder`` reads it, but testing the flag here measured dearer
  ## than the increment.  With no ``stepLimit`` to stop it, an attempt can
  ## enter groups 2^31 times and run the clock out ([openClockSpent]); an
  ## ``int`` stamp measured dearer than the test, up to 1.9% on items with
  ## no reference.
  if ctx.openClock == high(int32):
    ctx.openClockSpent()
  inc ctx.openClock
  ctx.openClock

proc recordOpened(ctx: MatchContext, capIdx: int, opened: int32): Span {.inline.} =
  ## Note that group ``capIdx`` closed a span its entry stamped ``opened``,
  ## and return the slot's old value for the caller's undo.
  let slot = ctx.openedSlot(capIdx)
  result = ctx.captures[slot]
  ctx.captures[slot] = Span(a: opened, b: opened)

proc resolveCapture(ctx: MatchContext, capIdx: int, level: int, leveled: bool): Span =
  ## Resolve a capture, optionally using recursion-level stack.
  ## level > 0: access the level-th entry (1-based) in the capture stack for this group.
  ## level 0: use the current capture value.
  ## ``leveled``: the reference was written with a level (``backrefLeveled``).
  if level > 0 and capIdx > 0 and capIdx - 1 < ctx.captureStacks.len:
    let stack = ctx.captureStacks[capIdx - 1] # captureStacks is 0-based by group
    if level <= stack.len:
      return stack[level - 1] # 1-based: level 1 = first entry
    return UnsetSpan
  if capIdx >= ctx.groupSlots:
    return UnsetSpan
  if leveled:
    lastClosed(ctx.captures[capIdx])
  else:
    ctx.captures[capIdx]

proc backrefEnd(ctx: MatchContext, capIdx: int, level: int, leveled: bool): int =
  ## End position if capture `capIdx` matches here, else -1. Pure predicate
  ## shared by the loop and the recursive fallback.
  let cap = resolveCapture(ctx, capIdx, level, leveled)
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

proc leveledBackrefEnd(ctx: MatchContext, node: Node): int =
  ## [namedBackrefEnd] for a ``\k<name>`` written with a level.
  let level = node.namedBackrefLevel
  if level != 0:
    for i in ctx.regex[].nameRefsOf(node.backrefRefs):
      let e = backrefEnd(ctx, int(i) + 1, level, true)
      if e >= 0:
        return e
    return -1
  if not ctx.trackOpenOrder:
    # No ``\k<name+0>`` here reads a name two groups declare, so this one
    # reads one group, or none; its only span is the last.
    # ``markGroupReads`` asserts it at compile time: here the assert measured
    # 2% on ``(?<n>\w)\k<n+0>``.
    let first = ctx.regex[].nameRefFirst(node.backrefRefs)
    if first < 0:
      return -1
    return backrefEnd(ctx, int(first) + 1, 0, true)
  var last = -1
  var lastOpened = 0
  for i in ctx.regex[].nameRefsOf(node.backrefRefs):
    let capIdx = int(i) + 1 # captures are 1-indexed in boundaries
    if lastClosed(ctx.captures[capIdx]).a >= 0:
      let opened = ctx.captures[ctx.openedSlot(capIdx)].a
      # The reference marks every group of the name read, and each close of
      # a read group records its stamp; a set group without one would drop
      # out of the comparison unseen.
      assert opened > 0, "a set group with no open stamp"
      if opened > lastOpened:
        last = capIdx
        lastOpened = opened
  if last < 0:
    return -1
  backrefEnd(ctx, last, 0, true)

proc namedBackrefEnd(ctx: MatchContext, node: Node): int {.inline.} =
  ## End position if the ``\k<name>`` ``node`` matches here, else -1.  Pure
  ## predicate shared by the loop and the recursive fallback.  A name that
  ## several groups declare reads one of them, and a continuation that fails
  ## does not try another.  Which one, as Oniguruma 6.9.10 picks it:
  ##
  ## - Without a level (``BACKREF_MULTI``): the last-declared group that is
  ##   set and whose text matches here ([nameRefsBackward]).
  ## - With level 0, ``\k<name+0>`` (``BACKREF_WITH_LEVEL``): the closed span
  ##   opened last, whether its text matches or not.
  ##   ``backref_match_at_nested_level`` walks the stack down to the first
  ##   group start with a group end above it: the inner group when two nest,
  ##   and a group a look-around entered before one entered after it, though
  ##   it starts ahead of that one.  ``Regex.openedGroups`` keep each span's
  ##   stamp for this ([openedSlot]).
  ##
  ## Level 0 counts no calls, as no leveled read here does ([lastClosed]),
  ## where Oniguruma's walk keeps to the reference's own call level and
  ## enters a level for a called group even where it is written.  So a span a
  ## deeper ``\g`` call closed can be the one opened last:
  ## ``(?<r>(?<n>a)|b(?<n>b?)\g<r>\k<n+0>)`` on "bab" reads the "a" the call
  ## matched and matches 1..2; Oniguruma reads the empty ``n`` and matches
  ## 0..2.
  ##
  ## With any other level reni reads a group its own way ([resolveCapture]),
  ## not by that walk, so no order here would be Oniguruma's.  This one takes
  ## the first group in declaration order whose text matches.
  ##
  ## Inline for the common form, without a level, which the loop answers at
  ## every step; [leveledBackrefEnd] takes the rest.
  if node.namedBackrefLeveled:
    return leveledBackrefEnd(ctx, node)
  for i in ctx.regex[].nameRefsBackward(node.backrefRefs):
    let e = backrefEnd(ctx, int(i) + 1, node.namedBackrefLevel, false)
    if e >= 0:
      return e
  -1

proc matchBackref(ctx: MatchContext, e: int, cont: ContId): bool =
  ## Recursive fallback only; the loop answers backrefs itself.  Runs
  ## ``cont`` from ``e``, the end [backrefEnd] or [namedBackrefEnd] found,
  ## or fails when there is none.
  if e < 0:
    return false
  let savedPos = ctx.pos
  ctx.pos = e
  if runCont(ctx, cont):
    return true
  ctx.pos = savedPos
  false

proc clearOnOpen(
    ctx: MatchContext, capIdx: int, leavesUndo: static bool = true
): int32 {.inline.} =
  ## Oniguruma's ``MEM_START_PUSH``, for a group ``Regex.opensUnset`` names:
  ## until the group closes again it reads as unset, but to a reference with
  ## a level ([openSpan]).  The span it held comes back on backtracking,
  ## through the undo a close leaves too.  The loop's entries leave that
  ## undo here; [matchCapture], the recursive fallback, passes
  ## ``leavesUndo = false`` and puts the span back itself.
  ##
  ## Returns the group's [openStamp] for its frame, or 0 for a group nothing
  ## reads: nothing compares when it opened, so its close records no stamp.
  if ctx.regex[].opensUnset(capIdx):
    if ctx.captures[capIdx].a >= 0:
      when leavesUndo:
        ctx.pushChoice Choice(
          kind: chUndoCapture,
          ucCapIdx: int32(capIdx),
          ucIndex: int32(capIdx - 1),
          ucMyDepth: -1,
          ucSavedCap: ctx.captures[capIdx],
          ucSavedStackEntry: UnsetSpan,
          ucFlags: ctx.flags,
        )
      ctx.captures[capIdx] = openSpan(ctx.captures[capIdx])
      ctx.capturesDirty = true
    result = ctx.openStamp()

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
  # The stamp and the clear a loop entry takes; the clear is undone here on
  # the way out.
  let held = ctx.captures[capIdx]
  let opened = ctx.clearOnOpen(capIdx, leavesUndo = false)
  let clears = ctx.captures[capIdx] != held
  let fid = pushFrame(
    ctx,
    Frame(
      kind: ckCapture,
      parent: cont,
      cCapIdx: int32(capIdx),
      cIndex: int32(index),
      cMyDepth: int32(myDepth),
      cOpened: opened,
      cStartPos: startPos,
      cSavedFlags: savedFlags,
    ),
  )
  let ok = matchWithCont(ctx, body, fid)
  ctx.framesLen = fid
  if not ok and clears:
    ctx.captures[capIdx] = held
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
  ctx.capturesDirty = true
  let opened = ctx.frames[contId].cOpened
  let recordsOpened = ctx.trackOpenOrder and opened != 0
  var savedOpened: Span
  if recordsOpened:
    savedOpened = ctx.recordOpened(capIdx, opened)
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
    if recordsOpened:
      ctx.captures[ctx.openedSlot(capIdx)] = savedOpened
  ok

proc undoCloseRecords(ctx: MatchContext, top: int) {.noinline.} =
  ## The rare half of popping the ``chUndoCapture`` at ``top``: put back the
  ## history entry (``ucMyDepth >= 0``) or the [openedSlot] (``-2``) the
  ## close wrote beside the span.  Out of line, as inline it measured up to
  ## 0.7% dearer on items that write neither.
  let myDepth = int(ctx.choices[top].ucMyDepth)
  if myDepth >= 0:
    ctx.captureStacks[int(ctx.choices[top].ucIndex)][myDepth] =
      ctx.choices[top].ucSavedStackEntry
  else:
    ctx.captures[ctx.openedSlot(int(ctx.choices[top].ucCapIdx))] =
      ctx.choices[top].ucSavedStackEntry

proc endCheckFrame(targetPos: int): Frame {.inline.} =
  Frame(kind: ckEndCheckPos, parent: TrueCont, ecpTargetPos: targetPos)

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
  if ctx.boundsUsable(node) and i < node.lookAlts.len:
    node.lookAlts[i]
  else:
    lengthBounds(alt, ctx.flags, ctx.graphemeMode)

proc bodyWindow(ctx: MatchContext, node: Node): bool {.inline.} =
  ## Whether this look-behind body runs under a window; see
  ## [lookbehindBodyEndsAt].  Oniguruma asks one question here -- is the body
  ## fixed-length? -- and compiles the two cases differently
  ## (``compile_anchor_look_behind_node``): a fixed one steps back a known
  ## amount and runs against the real subject, anything else runs clipped to
  ## the position it has to end at.  A fixed-length body that backtracks must
  ## not get a window, so the test is not "may as well clip".
  ##
  ## ``(?~)`` is the absent function with an empty pattern.  It consumes
  ## nothing, yet does not count as fixed-length (see ``nkAbsent`` in
  ## [lengthBounds]), so a body holding one is clipped: ``(?<=(?~)\b)``
  ## never holds at 0, where ``(?<=\b)`` holds before a word character.
  ctx.bodyBounds(node).fixedLen < 0

proc altWindow(ctx: MatchContext, node: Node, i: int, alt: Node): bool {.inline.} =
  ## As [bodyWindow] for one alternative; each answers on its own.
  ctx.altBounds(node, i, alt).fixedLen < 0

proc lookbehindBodyEndsAt(
    ctx: MatchContext, body: Node, startPos, targetEnd: int, window: bool
): bool =
  ## Whether ``body`` matches from ``startPos`` and ends exactly at ``targetEnd``.
  ## With ``window``, consumption is clipped to ``[0, targetEnd)`` while
  ## zero-width shapes still read the real subject -- apart from ``\b`` and
  ## ``\B`` at position 0 when ``targetEnd`` is 0: that window is an empty
  ## string, which has no word boundary ([matchWordBoundary]). Restores the
  ## window on exit.
  let savedLimit = ctx.lookLimit
  ctx.pos = startPos
  if window:
    ctx.enterLookaroundBody(targetEnd)
  let fid = pushFrame(ctx, endCheckFrame(targetEnd))
  result = matchDiscardedBody(ctx, body, fid)
  ctx.framesLen = fid
  ctx.lookLimit = savedLimit

proc lookbehindBodyMatches(
    ctx: MatchContext, body: Node, targetEnd: int, fbl: int, window: bool
): bool =
  ## Whether ``body`` matches ending at ``targetEnd`` from ``fbl`` bytes
  ## before it. Restores ``ctx`` either way.
  if isLeafLookbehindBody(body):
    return leafBodyEndsAt(ctx, body, targetEnd, fbl)
  let st = targetEnd - fbl
  if st < 0:
    return false
  let stackSnap = saveStackLens(ctx)
  let saved = save(ctx)
  let matched = lookbehindBodyEndsAt(ctx, body, st, targetEnd, window)
  restore(ctx, saved)
  restoreStackLens(ctx, stackSnap)
  matched

proc lookbehindVarHolds(ctx: MatchContext, node: Node, bodyLen: LenBounds): bool =
  ## Whether variable-length positive lookbehind matches ending at ``ctx.pos``.
  ## Scans shortest-first, commits to first match, takes no continuation.
  let targetEnd = ctx.pos
  let body {.cursor.} = node.lookBody
  let window = ctx.bodyWindow(node)
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
    let bodyMatch = lookbehindBodyEndsAt(ctx, body, startTry, targetEnd, window)
    if bodyMatch:
      keepLookCaptures(ctx, node, saved)
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
  let body = peelBareGroups(node.lookBody)
  if body != nil and body.kind == nkAlternation:
    # Try each alternative independently — if ANY matches, negative fails
    for i, alt in body.alternatives.view:
      let altLen = ctx.altBounds(node, i, alt)
      let altFbl = altLen.fixedLen
      if altFbl >= 0:
        if lookbehindBodyMatches(
          ctx, alt, targetEnd, altFbl, ctx.altWindow(node, i, alt)
        ):
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
          let matched = lookbehindBodyEndsAt(
            ctx, alt, startTry, targetEnd, ctx.altWindow(node, i, alt)
          )
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
    return not lookbehindBodyMatches(
      ctx, body, targetEnd, bodyLen.fixedLen, ctx.bodyWindow(node)
    )
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
    let matched =
      lookbehindBodyEndsAt(ctx, body, startTry, targetEnd, ctx.bodyWindow(node))
    restore(ctx, saved)
    restoreStackLens(ctx, stackSnap)
    if matched:
      return false
    if startTry == 0:
      break
    startTry = prevCharStart(ctx.subject.oa, startTry)
  true

proc lookbehindAltNext(ctx: MatchContext, top: int): bool =
  ## Try the branches of a divided look-behind ([lookDivided]) from `lbaNext`
  ## on, each as a look-behind of its own: a fixed-length one at its single
  ## start, any other shortest-first, and either one committing to its first
  ## match.  A match keeps the entry, so the next branch is tried once the
  ## continuation fails; exhaustion restores the entry state and pops it.
  let node {.cursor.} = ctx.nodeAt(ctx.choices[top].lbaNode)
  let targetEnd = ctx.choices[top].lbaTarget
  let alts = peelBareGroups(node.lookBody)
  var k = int(ctx.choices[top].lbaNext)
  if k > 0 and k < alts.alternatives.len:
    # Re-entered for the next alternative.  The one before it kept its
    # captures on this entry's snapshot, and nothing else undoes them, so roll
    # back before another alternative writes over them.  With no alternative
    # left the exhaustion tail below does the same, so skip it here.
    rewind(ctx, ctx.choices[top].lbaSaved)
    restoreStackLens(ctx, @(ctx.stackLensSaves[int(ctx.choices[top].lbaLensOff)]))
  while k < alts.alternatives.len:
    let alt {.cursor.} = alts.alternatives[k]
    let altLen = ctx.altBounds(node, k, alt)
    let altFbl = altLen.fixedLen
    # A fixed-length branch has one start; any other is scanned from the
    # shortest start back.
    let altMinPos =
      if altFbl >= 0:
        targetEnd - altFbl
      elif altLen.maxLen >= 0:
        max(0, targetEnd - altLen.maxLen)
      else:
        0
    var startTry = if altFbl >= 0: altMinPos else: targetEnd
    while startTry >= max(altMinPos, 0):
      let stackSnap = saveStackLens(ctx)
      let saved = save(ctx)
      let bodyMatch =
        lookbehindBodyEndsAt(ctx, alt, startTry, targetEnd, ctx.altWindow(node, k, alt))
      if bodyMatch:
        # Keep captures (and ``\K``); retry replays the entry snapshot.
        restoreScalarsKeepingStart(ctx, saved.scalars)
        restoreStackLens(ctx, stackSnap)
        drop(ctx, saved)
        ctx.choices[top].lbaNext = int32(k + 1)
        return true
      restore(ctx, saved)
      restoreStackLens(ctx, stackSnap)
      if startTry == 0:
        break
      startTry = prevCharStart(ctx.subject.oa, startTry)
    inc k
  # Exhausted: restore entry state and release slots.
  rewind(ctx, ctx.choices[top].lbaSaved)
  restoreStackLens(ctx, @(ctx.stackLensSaves[int(ctx.choices[top].lbaLensOff)]))
  releaseTo(ctx, ctx.choices[top].lbaSaved.capOff)
  ctx.stackLensSaves.setLen(int(ctx.choices[top].lbaLensOff))
  ctx.choicesLen = top
  false

proc absentBodyMatches(ctx: MatchContext, absentBody: Node): bool {.inline.} =
  ## Whether the absent pattern matches at ``ctx.pos`` by a path that may
  ## narrow. An empty match counts; a path through an absent operator of its
  ## own does not (see ``absentScan``).
  inc ctx.absentScan
  result = matchWithCont(ctx, absentBody, TrueCont)
  dec ctx.absentScan

proc findAbsentPos(ctx: MatchContext, absentBody: Node, fromPos: int): int =
  ## First pos at/after `fromPos` where `absentBody` matches, else
  ## `absentEnd`. Closed sub-matches only; restores `pos`. Measured against
  ## ``absentEnd``: a look-behind window must not narrow an absent range.
  result = ctx.absentEnd
  let entryPos = ctx.pos
  var checkPos = fromPos
  while checkPos < ctx.absentEnd:
    let saved = save(ctx)
    ctx.pos = checkPos
    if ctx.absentBodyMatches(absentBody):
      result = checkPos
      restore(ctx, saved)
      break
    restore(ctx, saved)
    if checkPos >= ctx.absentEnd:
      break
    var r: Rune
    nextCharAt(ctx.subject.oa, checkPos, r)
  ctx.pos = entryPos

proc matchAbsent(ctx: MatchContext, node: Node, cont: ContId): bool =
  ## Recursive fallback only; the loop answers absent shapes itself.
  if ctx.absentSuppressed:
    return false
  case node.absentKind
  of abClear:
    # (?~|) - always matches empty, widens ``absentEnd`` to the subject end
    ctx.absentEnd = ctx.subject.len
    return runCont(ctx, cont)
  of abFunction:
    if node.isEmptyAbsentFunc:
      # (?~), (?~a*) - match empty and nothing else ([isEmptyAbsentFunc]).
      return runCont(ctx, cont)
    # (?~pattern) - match longest text not containing pattern (see
    # ``absentBodyMatches`` for what counts as containing).
    let startPos = ctx.pos
    # Find first position where absent pattern matches
    var firstAbsentPos = ctx.subjectEnd # default: no absent found -> match to end
    var checkPos = startPos
    while checkPos < ctx.subjectEnd:
      let saved = save(ctx)
      ctx.pos = checkPos
      let bodyMatch = ctx.absentBodyMatches(node.absentBody)
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
    let absentBody {.cursor.} = node.absentBody
    # Find first position where absent matches
    var absentPos = ctx.absentEnd
    block findAbsent:
      var checkPos = startPos
      while checkPos < ctx.absentEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if ctx.absentBodyMatches(absentBody):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.absentEnd:
          break
        var r: Rune
        nextCharAt(ctx.subject.oa, checkPos, r)
    # Limit matching range to [startPos, absentPos)
    let savedEnd = ctx.absentEnd
    ctx.pos = startPos
    ctx.absentEnd = absentPos
    let fid = pushFrame(
      ctx,
      Frame(
        kind: ckRestoreAbsentEnd,
        parent: cont,
        reSavedEnd: savedEnd,
        reAbsentPos: absentPos,
      ),
    )
    let ok = matchWithCont(ctx, node.absentExpr, fid)
    ctx.framesLen = fid
    ctx.absentEnd = savedEnd
    return ok
  of abRange:
    # (?~|absent) - range marker: zero-width, narrows ``absentEnd``
    let absentBody {.cursor.} = node.absentBody
    var absentPos = ctx.absentEnd
    block findAbsent:
      var checkPos = ctx.pos
      while checkPos < ctx.absentEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if ctx.absentBodyMatches(absentBody):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.absentEnd:
          break
        var r: Rune
        nextCharAt(ctx.subject.oa, checkPos, r)
    let savedEnd = ctx.absentEnd
    ctx.absentEnd = absentPos
    let ok = runCont(ctx, cont)
    if not ok:
      ctx.absentEnd = savedEnd # restore only on failure
    return ok

proc condHolds(ctx: MatchContext, node: Node): bool =
  ## Whether the conditional holds here. Closed sub-matches only.
  case node.condKind
  of ckBackref:
    let capIdx = node.condRefIndex # 1-indexed capture
    if capIdx >= 0 and capIdx < ctx.groupSlots:
      return ctx.captures[capIdx].a >= 0
    return false
  of ckNamedRef:
    # Holds if any group of that name captured; the name resolved to them
    # at compile time (see ``resolveNameRefs``).
    for i in ctx.regex[].nameRefsOf(node.condRefs):
      let capIdx = int(i) + 1
      if capIdx < ctx.groupSlots and ctx.captures[capIdx].a >= 0:
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
        ctx.enterLookaroundBody(NoLookLimit) # as ``lkNegAhead`` proper
        let bodyMatch = matchDiscardedBody(ctx, node.condBody.lookBody, TrueCont)
        if bodyMatch:
          result = false # negative lookaround failed, preserve captures
          # Captures only: the assertion did not hold, so a ``\K`` its body
          # ran over keeps nothing, the way ``lkNegAhead`` proper restores.
          keepLookCaptures(ctx, node.condBody, saved, keepKeptStart = false)
        else:
          result = true # negative lookaround succeeded
          restore(ctx, saved)
        restoreStackLens(ctx, stackSnap)
      else:
        # Only the failure path trims the capture stacks: a consuming
        # condition that holds is part of the match proper, so the levels it
        # pushed stay readable through ``\k<n+1>``.  The zero-width shapes
        # above restore unconditionally, since nothing of theirs survives.
        let stackSnap = saveStackLens(ctx)
        let saved = save(ctx)
        if matchDiscardedBody(ctx, node.condBody, TrueCont):
          # Matched: ``pos`` stays advanced past the condition and what the
          # body captured is kept, so those captures need a rollback of their
          # own, as a lookaround's do.
          result = true
          if node.condBodyPure:
            # Nothing written, so the snapshot only gives its slot back.
            drop(ctx, saved)
          else:
            keepCaptures(ctx, saved)
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
    matchBackref(
      ctx,
      backrefEnd(ctx, node.backrefIndex, node.backrefLevel, node.backrefLeveled),
      cont,
    )
  of nkNamedBackref:
    # Loop answers these itself.
    matchBackref(ctx, namedBackrefEnd(ctx, node), cont)
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
      let i = int(ctx.regex[].nameRefFirst(node.callRefs))
      if i >= 0:
        if i < ctx.regex[].groupBodies.len:
          body = ctx.regex[].groupBodies[i]
        captureIdx = i
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
      ctx.groupDepthDirty = true
    # Apply the flags that were active when the group was defined
    let savedFlags = ctx.flags
    if captureIdx >= 0 and captureIdx < ctx.regex[].groupFlags.len:
      ctx.flags = ctx.regex[].groupFlags[captureIdx]
    var ok: bool
    if captureIdx >= 0 and captureIdx + 1 < ctx.groupSlots:
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

proc writeFoundCopy(m: var Match, captures: seq[Span], n, startChar: int) {.inline.}

proc runCont(ctx: MatchContext, cont: ContId): bool =
  ## Walk the continuation chain starting at ``cont``: each ``Frame``
  ## holds one step of post-match work plus a ``parent`` link.
  ## ``TrueCont`` (-1) means "no further work, succeed".
  if cont < 0:
    return true
  ctx.checkCont cont
  case ctx.frames[cont].kind
  of ckSeqContinue:
    let parentNode {.cursor.} = ctx.nodeAt(ctx.frames[cont].sNode)
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
  of ckRestoreAbsentEnd:
    let savedEnd = ctx.frames[cont].reSavedEnd
    let absentPos = ctx.frames[cont].reAbsentPos
    let parent = ctx.frames[cont].parent
    ctx.absentEnd = savedEnd
    inc ctx.chainDepth
    checkNativeDepth(ctx)
    let ok = runCont(ctx, parent)
    dec ctx.chainDepth
    if not ok:
      ctx.absentEnd = absentPos
    ok
  of ckEndCheckPos:
    ctx.pos == ctx.frames[cont].ecpTargetPos
  of ckFindLongestRec:
    let sp = ctx.frames[cont].flStartPos
    let mLen = ctx.pos - sp
    if mLen > ctx.flBestLen:
      ctx.flBestLen = mLen
      writeFoundCopy(ctx.flBestMatch, ctx.captures, ctx.groupSlots, sp)
      ctx.flBestMatch.boundaries[0] = span(sp, ctx.pos)
      if ctx.keepStart != sp:
        ctx.flBestMatch.boundaries[0].a = min(ctx.keepStart, ctx.pos)
    false # force backtracking for more alternatives

type MachineMode = enum
  ## What the matcher loop does on its next turn.
  mMatch ## match ``node`` against the subject, then run ``cont``
  mSeq ## resume an ``nkConcat`` at ``seqIdx``
  mCont ## run the continuation chain from ``cont``
  mFail ## backtrack into the most recent choice

proc lazyScanResume(ctx: MatchContext, top: int): bool {.noinline.} =
  ## Resume the scan at ``ctx.choices[top]`` with one more rep, then scan on.
  ## Out of line to keep ``runMachine``'s switch small enough for ``pushChoice``
  ## to stay inlined.
  restoreScalars(ctx, ctx.choices[top].lsScalars)
  ctx.framesLen = ctx.choices[top].lsFramesLen
  ctx.pos = ctx.choices[top].lsPos
  let body {.cursor.} = ctx.nodeAt(ctx.choices[top].lsBody)
  let nextLeaf {.cursor.} = ctx.nodeAt(ctx.choices[top].lsNext)
  let maxRep = ctx.choices[top].lsMaxRep
  var count = ctx.choices[top].lsCount
  if maxRep < 0 or count < maxRep:
    let before = ctx.pos
    if matchWithCont(ctx, body, TrueCont) and ctx.pos != before:
      inc count
      if lazyScanAdvance(ctx, body, nextLeaf, count, maxRep):
        ctx.choices[top].lsCount = count
        ctx.choices[top].lsPos = ctx.pos
        return true
    else:
      ctx.pos = before
  restoreScalars(ctx, ctx.choices[top].lsScalars)
  false

proc retreatToFollowByte(
    ctx: MatchContext, top: int, back, minRep: int32
): int32 {.noinline.} =
  ## Last give-back at or below ``back`` the ``chSimpleRepeat`` continuation
  ## can use.  It requires ``srFollow`` at the position it is handed, so every
  ## other position fails at its first leaf and is skipped rather than
  ## dispatched.  ``ctx.pos`` is the repeat's start, which ``restoreScalars``
  ## has just put back.
  ##
  ## The caller passes ``back = count - 1``, so every position read below ends
  ## a repetition the repeat already took and is inside the subject; the
  ## position past the run, where the continuation would have nothing to
  ## consume, is never a candidate.
  ##
  ## Out of line for the same reason [lazyScanResume] is: only an annotated
  ## repeat calls it, and the arm stays the size the other items pay for.
  let want = char(ctx.choices[top].srFollow)
  let runCount = ctx.choices[top].srRunCount
  let posOff = int(ctx.choices[top].srPosOff)
  let start = ctx.pos
  result = back
  # The tail stores one position per repetition; a position past the run may
  # be multibyte, and a multibyte lead never equals an ASCII ``want``.
  while result > runCount and result >= minRep:
    if ctx.subject[ctx.repPositions[posOff + int(result - runCount) - 1]] == want:
      return
    dec result
  # The run is contiguous bytes, so this is a backward scan over one stretch.
  while result >= minRep and ctx.subject[start + int(result)] != want:
    dec result

proc ensureRepCap(ctx: MatchContext, n: int) {.inline.} =
  ## Room for ``n`` entries in ``repPositions``.
  if n > ctx.repPositions.len:
    ctx.repPositions.setLen(max(16, max(n, ctx.repPositions.len * 2)))
  if n > ctx.repPeak:
    ctx.repPeak = n

proc seqRunLoad(ctx: MatchContext, node: Node): int {.inline.} =
  ## ``node``'s elements and accept sets, in the context's one slot.
  if ctx.seqCacheNode != node.id:
    ctx.seqCacheK = int32(seqRunShape(node, ctx.seqCacheElems))
    # A shape of none would spin: ``j == k`` advances nothing.
    doAssert ctx.seqCacheK >= 2, "quantSeqOk on a body of fewer than two leaf runs"
    ctx.seqCacheUnion = {}
    for j in 0 ..< int(ctx.seqCacheK):
      ctx.seqCacheAccept[j] = ctx.gateAt(ctx.seqCacheElems[j].leaf).accept
      ctx.seqCacheUnion = ctx.seqCacheUnion + ctx.seqCacheAccept[j]
    ctx.seqCacheNode = node.id
  int(ctx.seqCacheK)

proc seqRunRegion(ctx: MatchContext, node: Node): int {.noinline.} =
  ## First position at or after ``ctx.pos`` that no element of ``node``
  ## accepts, or -1 when this cannot answer (non-ASCII terminator, or the
  ## step budget ended the walk).  Grows [MatchContext.seqRegionEnd]
  ## rather than rewalking; a give-back reuses the stretch on the ``Choice``.
  discard ctx.seqRunLoad(node)
  let start = ctx.pos
  let stop = ctx.subjectEnd
  if ctx.seqRegionEnd < 0 or ctx.seqCacheUnion != ctx.seqRegionUnion or
      start > ctx.seqRegionEnd:
    ctx.seqRegionUnion = ctx.seqCacheUnion
    ctx.seqRegionFrom = start
    ctx.seqRegionEnd = start
    ctx.seqRegionDone = false
  elif start < ctx.seqRegionFrom:
    var p = start
    while p < ctx.seqRegionFrom and ctx.subject[p].uint8 in ctx.seqRegionUnion:
      inc p
    if p < ctx.seqRegionFrom:
      # A terminator between the two: this start reaches a shorter stretch.
      ctx.seqRegionFrom = start
      ctx.seqRegionEnd = p
      ctx.seqRegionDone = true
      ctx.seqRegionHigh = ctx.subject[p].uint8 >= 0x80'u8
    else:
      ctx.seqRegionFrom = start
  if not ctx.seqRegionDone and ctx.seqRegionEnd < stop:
    # Only as far as this attempt and the budget can pay for.  Stopping
    # early leaves the memo short, never wrong.
    var lim = stop
    let budget = ctx.stepLimit - ctx.steps
    if budget < stop - ctx.seqRegionEnd:
      lim = ctx.seqRegionEnd + budget
    var p = ctx.seqRegionEnd
    while p < lim and ctx.subject[p].uint8 in ctx.seqRegionUnion:
      inc p
    ctx.seqRegionEnd = p
    if p < lim:
      ctx.seqRegionDone = true
      ctx.seqRegionHigh = ctx.subject[p].uint8 >= 0x80'u8
    elif p < stop:
      # Budget ended the walk; the general path charges its own steps.
      return -1
  if ctx.seqRegionEnd >= stop:
    # Window ended first; stopping there is right whatever the byte.
    return stop
  if ctx.seqRegionHigh:
    return -1
  ctx.seqRegionEnd

template seqRunScan(
    ctx: MatchContext, accept: set[uint8], pos, region, emax: untyped
): int =
  ## Repetitions of one element from ``pos``, capped by ``emax`` and the
  ## region.  Charges one step each; may stop one byte past the budget, as
  ## [leafRunSpan] does.  Step counts are not the general path's: a budget
  ## bounds work, not the match, so this only ever relaxes it.
  block:
    var lim = region
    if emax >= 0 and pos + emax < lim:
      lim = pos + emax
    let budget = ctx.stepLimit - ctx.steps
    if budget < lim - pos:
      lim = pos + budget + 1
    var p = pos
    while p < lim and ctx.subject[p].uint8 in accept:
      inc p
    let n = p - pos
    if n > 0:
      ctx.steps += n
      if ctx.steps > ctx.stepLimit:
        raise newException(RegexLimitError, "match step limit exceeded")
    n

proc seqRunAdvance(
    ctx: MatchContext, node: Node, region, posOff: int, iters: var int, resume: bool
): bool {.noinline.} =
  ## Next state of a ``quantSeqOk`` repeat, or false when none remain.
  ## ``ctx.pos`` is the repeat's start on entry (caller restored the snapshot)
  ## and the state's end on exit; ``iters`` is the iteration count both ways.
  ## ``resume`` asks for the state after the one ``iters`` holds.
  ##
  ## States match the general path's order: a depth-first walk, not an
  ## odometer.  For ``(?:A+B+){n,}`` the general stack is, bottom to top,
  ## ``Q(0) D(0,A) D(0,B) Q(1) ...``; popping from ``n`` iterations gives
  ## back inside iteration ``n-1`` (rightmost first), then ``Q(n-1)``.  A
  ## give-back re-runs everything to its right, so the next state can be
  ## longer.  Each repetition is one ASCII byte, so a give-back decrements
  ## the element end in ``repPositions`` from ``posOff``.
  let k = ctx.seqRunLoad(node)
  var emin: array[MaxSeqRunElems, int]
  var emax: array[MaxSeqRunElems, int]
  var eposs: array[MaxSeqRunElems, bool]
  for j in 0 ..< k:
    emin[j] = int(ctx.seqCacheElems[j].emin)
    emax[j] = int(ctx.seqCacheElems[j].emax)
    eposs[j] = ctx.seqCacheElems[j].eposs
  let qmin = node.quantMin
  let qmax = node.quantMax
  let start = ctx.pos
  let lead = ctx.leadRun
  var i = 0
  var j = 0
  var pos = start
  var back = resume
  if resume:
    if iters == 0:
      # Nothing under a zero-iteration state to give back.
      return false
    i = iters - 1
    j = k - 1
  else:
    iters = 0
    if qmax == 0:
      # ``{0}`` admits no iteration; filling 0 would consume one sequence.
      ctx.repLen = posOff
      return qmin <= 0
    ensureRepCap(ctx, posOff + k)
  while true:
    if back:
      if j < 0:
        # Iteration ``i`` has nothing left: stop the repeat there (``Q(i)``).
        if i >= qmin:
          iters = i
          ctx.pos =
            if i == 0:
              start
            else:
              ctx.repPositions[posOff + i * k - 1]
          ctx.repLen = posOff + i * k
          return true
        # Below the minimum, ``Q(i)`` fails and the pop continues.  On
        # ``(?:\w+\s*){2,}`` vs "aa", the second iteration exists only once
        # the first gives a byte back.
        if i == 0:
          return false
        dec i
        j = k - 1
      let idx = posOff + i * k + j
      let lo =
        if i == 0 and j == 0:
          start
        else:
          ctx.repPositions[idx - 1]
      if not eposs[j] and ctx.repPositions[idx] - lo > emin[j]:
        dec ctx.repPositions[idx]
        pos = ctx.repPositions[idx]
        inc j
        back = false
      else:
        dec j
    elif j == k:
      # Iteration complete; one element consumes, so it moved.
      inc i
      iters = i
      if qmax >= 0 and i >= qmax:
        ctx.pos = pos
        ctx.repLen = posOff + i * k
        return i >= qmin
      j = 0
      ensureRepCap(ctx, posOff + (i + 1) * k)
    else:
      let n = ctx.seqRunScan(ctx.seqCacheAccept[j], pos, region, emax[j])
      if n < emin[j]:
        # Nothing here: give back to the left, or drop the iteration.
        back = true
        dec j
      else:
        pos += n
        ctx.repPositions[posOff + i * k + j] = pos
        if i == 0 and j == 0 and ctx.leadRunEnd < 0 and ctx.seqCacheElems[0].elem == lead:
          # First visit to the leading repeat; the skip reads this end.
          ctx.leadRunEnd = pos
        inc j

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
  let capBase = capMark(ctx)
  let capUndoBase = ctx.capUndosLen
  let repBase = ctx.repLen
  let choiceBase = ctx.choicesLen
  let stackLensBase = ctx.stackLensSaves.len

  var mode = startMode
  var node {.cursor.} = startNode
  var cont = startCont
  var seqNode {.cursor.}: Node = nil
  var seqIdx = 0

  template releaseToBase(): untyped =
    ## Trim stacks to entry lengths.  ``min``: a slot below ``capBase`` is
    ## not this machine's to bring back.
    ctx.framesLen = framesBase
    ctx.capSavesLen = min(ctx.capSavesLen, int(capBase))
    ctx.capUndosLen = capUndoBase
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

  template quantSnapshot(pure: bool): SavedState =
    ## Rollback point for a repetition.  A body that writes no captures needs
    ## scalars only: continuation captures carry their own ``chUndoCapture``
    ## entries, popped before this choice is reached -- the argument
    ## ``chSimpleRepeat``'s ``srScalars`` already runs on.  ``NoCapOff`` also
    ## skips the empty check, which such a body never needs: ``markGroupReads``
    ## asserts it owns no watched group.
    if pure:
      SavedState(scalars: saveScalars(ctx), capOff: NoCapOff)
    else:
      save(ctx)

  template startGreedy(
      body: Node, minRep, maxRep, count: int32, c: ContId, pure: bool
  ): untyped =
    ## Greedy: try one more rep, leaving "stop and run cont" behind.
    let snapshot = quantSnapshot(pure)
    ctx.pushChoice Choice(
      kind: chQuantGreedy,
      qcBody: body.id,
      qcMinRep: minRep,
      qcMaxRep: maxRep,
      qcCount: count,
      qcCont: c,
      qcFramesLen: ctx.framesLen.int32,
      qcPhase: 0,
      qcPure: pure,
      qcSaved: snapshot,
    )
    if maxRep < 0 or count < maxRep:
      cont = pushFrame(
        ctx,
        Frame(
          kind: ckQuantGreedyMore,
          parent: c,
          qBody: body.id,
          qMinRep: minRep,
          qMaxRep: maxRep,
          qCount: count,
          qPure: pure,
          qSnap: snapshot.capOff,
          qSavedPos: ctx.pos,
        ),
      )
      node = body
      mode = mMatch
    else:
      mode = mFail

  template startLazy(
      body: Node, minRep, maxRep, count: int32, c: ContId, pure: bool
  ): untyped =
    ## Lazy: run cont first, leaving "repeat once more" behind.
    ctx.pushChoice Choice(
      kind: chQuantLazy,
      qcBody: body.id,
      qcMinRep: minRep,
      qcMaxRep: maxRep,
      qcCount: count,
      qcCont: c,
      qcFramesLen: ctx.framesLen.int32,
      qcPhase: 0,
      qcPure: pure,
      qcSaved: quantSnapshot(pure),
    )
    if count >= minRep:
      cont = c
      mode = mCont
    else:
      mode = mFail

  template rollBackQuant(top: int): untyped =
    ## Undo a repetition's choice entry, snapshot-kind aware.
    if ctx.choices[top].qcPure:
      restoreScalars(ctx, ctx.choices[top].qcSaved.scalars)
    else:
      restore(ctx, ctx.choices[top].qcSaved)

  template tryLeafVariants(firstVariant, lastVariant: int, advance: untyped): untyped =
    ## Match the leaf ``node`` by its first way that fits, leaving the next
    ## way behind as a choice.  ``advance`` is the end of way ``v``, or -1.
    var v {.inject.} = firstVariant
    var e = -1
    while v < lastVariant:
      e = advance
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
          lNode: node.id,
          lVariant: int32(v + 1),
          lCont: cont,
          lFramesLen: ctx.framesLen.int32,
          lPos: ctx.pos,
        )
      ctx.pos = e
      mode = mCont

  template chargeTrieBranch(): untyped =
    ## What running the picked branch would have cost: the old path re-entered
    ## ``mMatch`` on it and paid a step.  The walk stays inside the
    ## alternation's own step, so without this a pattern would quietly buy
    ## more real backtracking under the same ``stepLimit``.
    inc ctx.steps
    if ctx.steps > ctx.stepLimit:
      raise newException(RegexLimitError, "match step limit exceeded")

  while true:
    case mode
    of mMatch:
      inc ctx.steps
      if ctx.steps > ctx.stepLimit:
        raise newException(RegexLimitError, "match step limit exceeded")
      case node.kind
      of nkLiteral, nkEscapedLiteral:
        let r = if node.kind == nkLiteral: node.rune else: node.escapedRune
        if rfIgnoreCase notin ctx.flags:
          # A case-sensitive literal matches one way, its own bytes, so it
          # needs neither the variant walk nor ``literalAdvance``: this is
          # that proc's variant 0.
          let e = matchBytes(ctx, r, ctx.pos)
          if e < 0:
            mode = mFail
          else:
            ctx.pos = e
            mode = mCont
        else:
          tryLeafVariants(0, LiteralVariants, literalAdvance(ctx, r, v))
      of nkCharClass:
        # Through ``leafVariantAdvance`` although the kind is known: calling
        # ``classAdvance`` directly read +0.1% ``Ir`` on the class items.
        tryLeafVariants(
          classFirstVariant(ctx, node), ClassVariants, leafVariantAdvance(ctx, node, v)
        )
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
        elif node.altTrie != nil and rfIgnoreCase notin ctx.flags:
          # Every branch is a literal, so one walk both picks the branch and
          # consumes it: no branch node is left to run, and a pick of the last
          # branch leaves no choice point.
          let trie {.cursor.} = node.altTrie
          let pick = nextTrieBranch(ctx, trie, 0'i32)
          if pick.idx < 0:
            mode = mFail
          else:
            chargeTrieBranch()
            if pick.idx + 1 < node.alternatives.len:
              # The next *untried* branch, as under the hints: the walk runs
              # again on backtrack, so a branch that spells nothing here is
              # not passed over for good.
              ctx.pushChoice Choice(
                kind: chAltTrie,
                aNode: node.id,
                aIdx: pick.idx + 1,
                aCont: cont,
                aFramesLen: ctx.framesLen.int32,
                aPos: ctx.pos,
                aKeepStart: ctx.keepStart,
              )
              ctx.altCheckPush()
            ctx.pos = pick.endPos
            mode = mCont
        elif node.altFirst.len != node.alternatives.len:
          # No usable hints here: the untouched path, which reads no subject
          # byte and tests nothing.  ``annotateTree`` leaves ``altFirst``
          # empty both for an alternation it never reached and for one whose
          # branches share a single hint, where a test could never pass over
          # anything.
          if node.alternatives.len > 1:
            # Save pos and keepStart — but NOT flags: isolated flag groups
            # (?i) extend across alternation branches.  Nor captures: every
            # capture written after this push carries its own undo (a
            # ``chUndoCapture``, or the ``chUndoState`` / kept-capture entry of
            # a construct that cut its body's), popped before this choice, so
            # the vector is back where it was by the time the choice is.
            ctx.pushChoice Choice(
              kind: chAlt,
              aNode: node.id,
              aIdx: 1,
              aCont: cont,
              aFramesLen: ctx.framesLen.int32,
              aPos: ctx.pos,
              aKeepStart: ctx.keepStart,
            )
            ctx.altCheckPush()
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
                aNode: node.id,
                aIdx: int32(first + 1),
                aCont: cont,
                aFramesLen: ctx.framesLen.int32,
                aPos: ctx.pos,
                aKeepStart: ctx.keepStart,
              )
              ctx.altCheckPush()
            node = node.alternatives[first]
            mode = mMatch
      of nkGroup:
        # Groups save/restore flags — isolated flag groups inside don't leak
        # out.  A body with no writer of them makes all three a no-op, so the
        # group is a pass-through (``groupBodyKeepsFlags``).
        if not node.groupBodyKeepsFlags:
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
        let body {.cursor.} =
          if node.kind == nkCapture: node.captureBody else: node.namedCaptureBody
        let keepsFlags =
          if node.kind == nkCapture:
            node.captureBodyKeepsFlags
          else:
            node.namedCaptureBodyKeepsFlags
        # As ``nkGroup`` above, but the frame carries the span and stays.
        if not keepsFlags:
          ctx.pushChoice Choice(kind: chUndoFlags, ufFlags: ctx.flags)
        let opened = ctx.clearOnOpen(index + 1)
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
            cOpened: opened,
            cStartPos: ctx.pos,
            cSavedFlags: ctx.flags,
          ),
        )
        node = body
        mode = mMatch
      of nkQuantifier:
        # ``normaliseInvertedRanges`` rewrote every inverted ``{n,m}``, so the
        # bounds and the kind are read as written.  The assert is erased under
        # ``-d:danger``.
        assert not isInvertedRange(node.quantMin, node.quantMax),
          "matcher entered an inverted range the compiler did not normalise"
        let qmin = node.quantMin
        let qmax = node.quantMax
        case node.quantKind
        of qkGreedy:
          let body {.cursor.} = node.quantBody
          # Read beside the body: the two reads of one variant share the
          # kind check, which a call in between would cost the push again.
          let followByte = node.quantFollowByte
          if ctx.isSingleWayLeaf(body):
            # Single-way body: forward scan, one int per rep for backtracking.
            let scalars = saveScalars(ctx)
            let posOff = ctx.repLen.int32
            # A body that is one leaf over a byte set takes its ASCII run in
            # a loop first and stores no position for it: the run is
            # contiguous, so ``srRunCount`` alone hands back a repetition
            # inside it. The loop below picks up where the run stopped.
            let runCount = int32(ctx.leafRunSpan(body, qmax))
            ctx.pos += runCount
            var count = runCount
            while qmax < 0 or count < int32(qmax):
              let before = ctx.pos
              if not matchWithCont(ctx, body, TrueCont):
                ctx.pos = before
                break
              if ctx.pos == before:
                break # zero-width: a single-way leaf cannot vary, so stop
              ctx.pushRepPos ctx.pos
              inc count
            if ctx.leadRunEnd < 0 and node.id == ctx.leadRun:
              # First visit to the leading repeat: record its run end.
              ctx.leadRunEnd = ctx.pos
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
                srRunCount: runCount,
                srFollow: followByte,
                srScalars: scalars,
              )
              mode = mCont
          else:
            # Sequence of leaf runs: one choice of byte scans.  Off when
            # flags have moved under the derivation.
            var seqTaken = false
            if node.quantSeqOk and ctx.gates != nil and ctx.flags == ctx.boundFlags:
              let region = ctx.seqRunRegion(node)
              if region >= 0:
                seqTaken = true
                let scalars = saveScalars(ctx)
                let posOff = ctx.repLen
                var iters = 0
                if ctx.seqRunAdvance(node, region, posOff, iters, false):
                  ctx.pushChoice Choice(
                    kind: chSeqRun,
                    qrNode: node.id,
                    qrCont: cont,
                    qrFramesLen: ctx.framesLen.int32,
                    qrIters: int32(iters),
                    qrPosOff: int32(posOff),
                    qrRegion: region,
                    qrScalars: scalars,
                  )
                  mode = mCont
                else:
                  restoreScalars(ctx, scalars)
                  ctx.repLen = posOff
                  mode = mFail
            if not seqTaken:
              startGreedy(body, int32(qmin), int32(qmax), 0, cont, node.quantBodyPure)
        of qkLazy:
          let body {.cursor.} = node.quantBody
          let nextLeaf {.cursor.} = node.quantNextLeaf
          # Leaf test needs folding off, then and now; both leaves single-way.
          if nextLeaf != nil and
              (ctx.flags * {rfIgnoreCase, rfIgnoreCaseAscii}).card == 0 and
              ctx.isSingleWayLeaf(body) and ctx.isSingleWayLeaf(nextLeaf):
            # Mandatory reps, then scan to the first admissible position.
            let scalars = saveScalars(ctx)
            var count = 0'i32
            var atMin = true
            while count < int32(qmin):
              let before = ctx.pos
              if not matchWithCont(ctx, body, TrueCont) or ctx.pos == before:
                ctx.pos = before
                atMin = false
                break
              inc count
            if atMin and lazyScanAdvance(ctx, body, nextLeaf, count, int32(qmax)):
              ctx.pushChoice Choice(
                kind: chLazyScan,
                lsBody: body.id,
                lsNext: nextLeaf.id,
                lsCont: cont,
                lsFramesLen: ctx.framesLen.int32,
                lsCount: count,
                lsMaxRep: int32(qmax),
                lsPos: ctx.pos,
                lsScalars: scalars,
              )
              mode = mCont
            else:
              restoreScalars(ctx, scalars)
              mode = mFail
          else:
            startLazy(body, int32(qmin), int32(qmax), 0, cont, node.quantBodyPure)
        of qkPossessive:
          # Possessive: greedy with no count backtracking; only a rollback for
          # continuation failure. Pure bodies need scalars only.
          let body {.cursor.} = node.quantBody
          let savedScalars = saveScalars(ctx)
          var count = 0
          # The loop never gives characters back, so it can miss a ``qmin`` only
          # a shorter split would reach.  Nothing arrives here able to:
          # ``{n,m}+`` parses as chaining, [normaliseInvertedRanges] sends
          # ``qmin >= 2`` through ``(?>X{m,n})``, and [annotateContinuations]
          # rewrites only single-leaf bodies, which split one way.
          if not node.quantBodyPure:
            # Full rollback plus one scratch slot reused in place.
            let savedCapOff = pushCaptures(ctx)
            let attemptOff = pushCaptures(ctx)
            let n = ctx.captures.len
            while qmax < 0 or count < qmax:
              # Body may still move scalars/captures on partial failure.
              let attemptScalars = saveScalars(ctx)
              copyCaptures(ctx.capSaves[int(attemptOff)], ctx.captures[0], n)
              if not matchDiscardedBody(ctx, body, TrueCont):
                restoreScalars(ctx, attemptScalars)
                capturesBackTo(ctx, attemptOff)
                break
              count += 1
              if ctx.pos == attemptScalars.pos and
                  not ctx.emptyPassProgressed(
                    attemptOff, ctx.regex[].emptyStatus(body.id)
                  ):
                break # zero-width: count as one rep, then stop
            releaseTo(ctx, attemptOff) # release the scratch slot
            if ctx.leadRunEnd < 0 and node.id == ctx.leadRun:
              # First visit to the leading repeat: record its run end.
              ctx.leadRunEnd = ctx.pos
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
            # Same run as above, with ``ctx.pos`` and ``count`` as the only
            # outputs. No single-way gate is needed: ``nkCharType`` always is
            # one, and [leafRunAccepts]'s class arm rules out ``(?i)``.
            let runLen = ctx.leafRunSpan(body, qmax)
            count += runLen
            ctx.pos += runLen
            while qmax < 0 or count < qmax:
              let attemptPos = ctx.pos
              if not matchDiscardedBody(ctx, body, TrueCont):
                ctx.pos = attemptPos
                break
              count += 1
              if ctx.pos == attemptPos:
                break # zero-width: count as one rep, then stop
            if ctx.leadRunEnd < 0 and node.id == ctx.leadRun:
              # First visit to the leading repeat: record its run end.
              ctx.leadRunEnd = ctx.pos
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
        if matchDiscardedBody(ctx, node.atomicBody, TrueCont):
          ctx.pushChoice Choice(
            kind: chUndoState, usFramesLen: ctx.framesLen.int32, usSaved: saved
          )
          mode = mCont
        else:
          restore(ctx, saved)
          mode = mFail
      of nkLookaround:
        # Lookarounds commit to the first answer; no choice point, no extra
        # rollback. A divided look-behind retries via ``chLookbehindAlt``.
        case node.lookKind
        of lkAhead:
          if isLeafLookaheadBody(node.lookBody):
            # Leaf body: tested in place, without a frame or a re-entry.
            mode = if leafBodyMatchesHere(ctx, node.lookBody): mCont else: mFail
          else:
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            # A look-ahead reads forward, outside the enclosing body's span, so
            # a running look-behind window does not bound it. ``saved`` carries
            # the window back on both exits.
            ctx.enterLookaroundBody(NoLookLimit)
            if matchDiscardedBody(ctx, node.lookBody, TrueCont):
              # Keep the captures the lookahead body made.
              keepLookCaptures(ctx, node, saved)
              restoreStackLens(ctx, stackSnap)
              mode = mCont
            else:
              restore(ctx, saved)
              restoreStackLens(ctx, stackSnap)
              mode = mFail
        of lkNegAhead:
          if isLeafLookaheadBody(node.lookBody):
            mode = if leafBodyMatchesHere(ctx, node.lookBody): mFail else: mCont
          else:
            let stackSnap = saveStackLens(ctx)
            let saved = save(ctx)
            ctx.enterLookaroundBody(NoLookLimit) # as ``lkAhead``
            let bodyMatch = matchDiscardedBody(ctx, node.lookBody, TrueCont)
            restore(ctx, saved)
            restoreStackLens(ctx, stackSnap)
            mode = if bodyMatch: mFail else: mCont
        of lkBehind:
          # A divided look-behind ([lookDivided]) retries its later branches
          # via heap entry; any other commits to the first match, an
          # alternation included.
          if node.lookDivided:
            let entrySaved = save(ctx)
            let entryLensOff = ctx.stackLensSaves.len
            ctx.stackLensSaves.add(saveStackLens(ctx))
            ctx.pushChoice Choice(
              kind: chLookbehindAlt,
              lbaNode: node.id,
              lbaNext: 0,
              lbaCont: cont,
              lbaFramesLen: ctx.framesLen.int32,
              lbaTarget: ctx.pos,
              lbaSaved: entrySaved,
              lbaLensOff: int32(entryLensOff),
            )
            mode = if lookbehindAltNext(ctx, ctx.choicesLen - 1): mCont else: mFail
          else:
            let bodyLen = ctx.bodyBounds(node)
            let fbl = bodyLen.fixedLen
            if fbl < 0:
              mode = if lookbehindVarHolds(ctx, node, bodyLen): mCont else: mFail
            elif isLeafLookbehindBody(node.lookBody):
              # Leaf body: tested in place, without a frame or a re-entry.
              mode =
                if leafBodyEndsAt(ctx, node.lookBody, ctx.pos, fbl): mCont else: mFail
            elif ctx.pos - fbl < 0:
              mode = mFail
            else:
              # Fixed-length lookbehind: only one starting position to try.
              let targetEnd = ctx.pos
              let stackSnap = saveStackLens(ctx)
              let saved = save(ctx)
              let bodyMatch = lookbehindBodyEndsAt(
                ctx, node.lookBody, targetEnd - fbl, targetEnd, ctx.bodyWindow(node)
              )
              if bodyMatch:
                keepLookCaptures(ctx, node, saved)
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
            ucoNode: node.id,
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
          ucoNode: node.id,
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
        if ctx.absentSuppressed:
          mode = mFail
          continue
        case node.absentKind
        of abClear:
          # (?~|): always empty; no undo.
          ctx.absentEnd = ctx.subject.len
          mode = mCont
        of abRange:
          # (?~|absent): narrow range, widen on failure.
          let rangeStart = ctx.pos
          let absentPos = findAbsentPos(ctx, node.absentBody, rangeStart)
          let savedEnd = ctx.absentEnd
          ctx.absentEnd = absentPos
          ctx.pushChoice Choice(kind: chWidenAbsentEnd, wsSavedEnd: savedEnd)
          mode = mCont
        of abExpression:
          # (?~|absent|expr): match expr narrowed, widen after.
          let startPos = ctx.pos
          let absentPos = findAbsentPos(ctx, node.absentBody, startPos)
          let savedEnd = ctx.absentEnd
          ctx.absentEnd = absentPos
          ctx.pushChoice Choice(kind: chWidenAbsentEnd, wsSavedEnd: savedEnd)
          cont = pushFrame(
            ctx,
            Frame(
              kind: ckRestoreAbsentEnd,
              parent: cont,
              reSavedEnd: savedEnd,
              reAbsentPos: absentPos,
            ),
          )
          node = node.absentExpr
          mode = mMatch
        of abFunction:
          if node.isEmptyAbsentFunc:
            # (?~), (?~a*): match empty and nothing else
            # ([isEmptyAbsentFunc]), so there is no scan to run and no
            # shorter end to retry.
            mode = mCont
            continue
          # (?~pattern): longest non-containing text, then shorter. An empty
          # body match counts (see ``absentBodyMatches``).
          let startPos = ctx.pos
          var firstAbsentPos = ctx.subjectEnd
          var checkPos = startPos
          while checkPos < ctx.subjectEnd:
            let saved = save(ctx)
            ctx.pos = checkPos
            let bodyMatch = ctx.absentBodyMatches(node.absentBody)
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
        let e =
          backrefEnd(ctx, node.backrefIndex, node.backrefLevel, node.backrefLeveled)
        if e < 0:
          mode = mFail
        else:
          ctx.pushChoice Choice(kind: chUndoPos, upPos: ctx.pos)
          ctx.pos = e
          mode = mCont
      of nkNamedBackref:
        # One group of the name, no choice left for the others.
        let e = namedBackrefEnd(ctx, node)
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
        var body {.cursor.}: Node = nil
        var captureIdx = -1
        if node.callIndex == 0:
          body = ctx.regex[].ast
        elif node.callIndex > 0:
          let idx = node.callIndex - 1
          if idx < ctx.regex[].groupBodies.len:
            body = ctx.regex[].groupBodies[idx]
          captureIdx = idx
        elif node.callName.len > 0:
          let i = int(ctx.regex[].nameRefFirst(node.callRefs))
          if i >= 0:
            if i < ctx.regex[].groupBodies.len:
              body = ctx.regex[].groupBodies[i]
            captureIdx = i
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
            ctx.groupDepthDirty = true
          ctx.pushChoice Choice(
            kind: chSubexpScope, ssCapIdx: int32(captureIdx), ssFlags: savedFlags
          )
          if captureIdx >= 0 and captureIdx + 1 < ctx.groupSlots:
            let index = captureIdx
            let opened = ctx.clearOnOpen(index + 1)
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
                cOpened: opened,
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
          let mk {.cursor.} = seqNode.children[seqIdx]
          # Under an enclosing scan a marker refuses rather than folds, so
          # leave it to the general path; see ``absentScan``.
          if ctx.absentSuppressed and mk.kind == nkAbsent and
              mk.absentKind in {abRange, abClear}:
            break
          if mk.kind == nkAbsent and mk.absentKind == abRange:
            let absentPos = findAbsentPos(ctx, mk.absentBody, ctx.pos)
            let savedEnd = ctx.absentEnd
            ctx.absentEnd = absentPos
            ctx.pushChoice Choice(kind: chWidenAbsentEnd, wsSavedEnd: savedEnd)
            cont = pushFrame(
              ctx,
              Frame(
                kind: ckRestoreAbsentEnd,
                parent: cont,
                reSavedEnd: savedEnd,
                reAbsentPos: absentPos,
              ),
            )
            inc seqIdx
          elif mk.kind == nkAbsent and mk.absentKind == abClear:
            ctx.absentEnd = ctx.subject.len
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
                sNode: seqNode.id,
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
        seqNode = ctx.nodeAt(ctx.frames[cont].sNode)
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
        ctx.capturesDirty = true
        var savedStackEntry = UnsetSpan
        # ``-1`` is the established "no history entry" marker, so recording it
        # in the choice point is what makes ``chUndoCapture`` skip the restore
        # in step with the write skipped here; ``-2`` puts back an
        # [openedSlot] instead.
        var stackDepth = -1
        if ctx.trackCloses:
          if ctx.trackCaptureStacks and myDepth >= 0:
            stackDepth = myDepth
            if index >= ctx.captureStacks.len:
              ctx.captureStacks.setLen(index + 1)
            if myDepth >= ctx.captureStacks[index].len:
              ctx.captureStacks[index].setLen(myDepth + 1)
            savedStackEntry = ctx.captureStacks[index][myDepth]
            ctx.captureStacks[index][myDepth] = span(startPos, ctx.pos)
            ctx.captureStacksDirty = true
          if ctx.trackOpenOrder and ctx.frames[cont].cOpened != 0:
            let heldOpened = ctx.recordOpened(capIdx, ctx.frames[cont].cOpened)
            if stackDepth == -1:
              # The undo below carries it, in the history entry's place.
              stackDepth = -2
              savedStackEntry = heldOpened
            else:
              # A history entry too, which only a reference with a nonzero
              # level asks for: its own undo, popped after the one below.
              ctx.pushChoice Choice(
                kind: chUndoCapture,
                ucCapIdx: int32(ctx.openedSlot(capIdx)),
                ucIndex: int32(index),
                ucMyDepth: -1,
                ucSavedCap: heldOpened,
                ucSavedStackEntry: UnsetSpan,
                ucFlags: ctx.flags,
              )
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
        if ctx.pos == ctx.frames[cont].qSavedPos and not ctx.emptyPassProgressed(cont):
          # Zero-width, and nothing the repeat watches moved: stop repeating,
          # as Oniguruma's empty check skips the jump back.  The body's other
          # ways are still on the stack below.
          cont = ctx.frames[cont].parent
          mode = mCont
        else:
          let body {.cursor.} = ctx.nodeAt(ctx.frames[cont].qBody)
          let minRep = ctx.frames[cont].qMinRep
          let maxRep = ctx.frames[cont].qMaxRep
          let count = ctx.frames[cont].qCount + 1
          let parent = ctx.frames[cont].parent
          let pure = ctx.frames[cont].qPure
          if isGreedy:
            startGreedy(body, minRep, maxRep, count, parent, pure)
          else:
            startLazy(body, minRep, maxRep, count, parent, pure)
      of ckRestoreAbsentEnd:
        # Walking out of a marker: widen end, leaving an undo to re-narrow
        # when backtracking retries inside the narrowed region.
        if ctx.choicesLen > choiceBase:
          ctx.pushChoice Choice(
            kind: chUndoAbsentEnd, useAbsentPos: ctx.frames[cont].reAbsentPos
          )
        ctx.absentEnd = ctx.frames[cont].reSavedEnd
        cont = ctx.frames[cont].parent
        mode = mCont
      of ckEndCheckPos:
        # Terminal predicate; answering here is the whole answer.
        if ctx.pos == ctx.frames[cont].ecpTargetPos:
          cont = ctx.frames[cont].parent
          mode = mCont
        else:
          mode = mFail
      of ckFindLongestRec:
        let sp = ctx.frames[cont].flStartPos
        let mLen = ctx.pos - sp
        if mLen > ctx.flBestLen:
          ctx.flBestLen = mLen
          writeFoundCopy(ctx.flBestMatch, ctx.captures, ctx.groupSlots, sp)
          ctx.flBestMatch.boundaries[0] = span(sp, ctx.pos)
          if ctx.keepStart != sp:
            ctx.flBestMatch.boundaries[0].a = min(ctx.keepStart, ctx.pos)
        mode = mFail # force backtracking for more alternatives
    of mFail:
      if ctx.choicesLen <= choiceBase:
        releaseToBase()
        dec ctx.callDepth
        return false
      let top = ctx.choicesLen - 1
      case ctx.choices[top].kind
      of chAlt:
        # No capture vector to put back; see the push.
        ctx.altCheckPop(top)
        ctx.pos = ctx.choices[top].aPos
        ctx.keepStart = ctx.choices[top].aKeepStart
        ctx.framesLen = ctx.choices[top].aFramesLen
        # Index in place to avoid copying the alternatives seq per backtrack.
        let idx = int(ctx.choices[top].aIdx)
        cont = ctx.choices[top].aCont
        let altNode {.cursor.} = ctx.nodeAt(ctx.choices[top].aNode)
        node = altNode.alternatives[idx]
        if idx + 1 >= altNode.alternatives.len:
          ctx.altCheckDrop(top)
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
        ctx.altCheckPop(top)
        ctx.pos = ctx.choices[top].aPos
        ctx.keepStart = ctx.choices[top].aKeepStart
        ctx.framesLen = ctx.choices[top].aFramesLen
        cont = ctx.choices[top].aCont
        let altNode {.cursor.} = ctx.nodeAt(ctx.choices[top].aNode)
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
          ctx.altCheckDrop(top)
          ctx.choicesLen = top
          mode = mFail
        else:
          if nxt + 1 >= altNode.alternatives.len:
            ctx.altCheckDrop(top)
            ctx.choicesLen = top
          else:
            ctx.choices[top].aIdx = int32(nxt + 1)
          node = altNode.alternatives[nxt]
          mode = mMatch
      of chAltTrie:
        # As ``chAltHinted``, with the trie in place of the hints: the walk
        # runs again from ``aIdx``, so a branch is judged against the state at
        # hand.  ``rfIgnoreCase`` needs no second test -- ``altTrie`` is nil
        # for any pattern that could have switched it on since the entry (see
        # ``altTriesUsable``).
        ctx.altCheckPop(top)
        ctx.pos = ctx.choices[top].aPos
        ctx.keepStart = ctx.choices[top].aKeepStart
        ctx.framesLen = ctx.choices[top].aFramesLen
        cont = ctx.choices[top].aCont
        let altNode {.cursor.} = ctx.nodeAt(ctx.choices[top].aNode)
        let trie {.cursor.} = altNode.altTrie
        let pick = nextTrieBranch(ctx, trie, ctx.choices[top].aIdx)
        if pick.idx < 0:
          ctx.altCheckDrop(top)
          ctx.choicesLen = top
          mode = mFail
        else:
          chargeTrieBranch()
          if pick.idx + 1 < altNode.alternatives.len:
            ctx.choices[top].aIdx = pick.idx + 1
          else:
            ctx.altCheckDrop(top)
            ctx.choicesLen = top
          ctx.pos = pick.endPos
          mode = mCont
      of chLeafVariant:
        ctx.pos = ctx.choices[top].lPos
        ctx.framesLen = ctx.choices[top].lFramesLen
        let leaf {.cursor.} = ctx.nodeAt(ctx.choices[top].lNode)
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
        let minRep = ctx.choices[top].srMinRep
        var back = count - 1
        if back >= minRep and ctx.choices[top].srFollow >= 0:
          # Skip the give-backs the continuation's first byte rules out.
          back = retreatToFollowByte(ctx, top, back, minRep)
        if back < minRep:
          ctx.repLen = int(ctx.choices[top].srPosOff)
          ctx.choicesLen = top
          mode = mFail
        else:
          let posOff = int(ctx.choices[top].srPosOff)
          let runCount = ctx.choices[top].srRunCount
          ctx.choices[top].srCount = back
          if back <= runCount:
            # Inside the run, where a repetition is one byte wide: its end is
            # ``back`` bytes past the repeat's start, which ``restoreScalars``
            # has just put back in ``ctx.pos``. The run stored no position.
            ctx.pos += int(back)
            ctx.repLen = posOff
          else:
            let tail = int(back - runCount)
            ctx.pos = ctx.repPositions[posOff + tail - 1]
            ctx.repLen = posOff + tail
          ctx.framesLen = ctx.choices[top].srFramesLen
          cont = ctx.choices[top].srCont
          mode = mCont
      of chLazyScan:
        if lazyScanResume(ctx, top):
          cont = ctx.choices[top].lsCont
          mode = mCont
        else:
          ctx.choicesLen = top
          mode = mFail
      of chSeqRun:
        # Scalars first: the machine reads the repeat start from ``ctx.pos``.
        restoreScalars(ctx, ctx.choices[top].qrScalars)
        let seqNode {.cursor.} = ctx.nodeAt(ctx.choices[top].qrNode)
        let posOff = int(ctx.choices[top].qrPosOff)
        var iters = int(ctx.choices[top].qrIters)
        if ctx.seqRunAdvance(seqNode, ctx.choices[top].qrRegion, posOff, iters, true):
          ctx.choices[top].qrIters = int32(iters)
          ctx.framesLen = ctx.choices[top].qrFramesLen
          cont = ctx.choices[top].qrCont
          mode = mCont
        else:
          ctx.repLen = posOff
          ctx.choicesLen = top
          mode = mFail
      of chQuantGreedy:
        rollBackQuant(top)
        ctx.framesLen = ctx.choices[top].qcFramesLen
        let count = ctx.choices[top].qcCount
        let minRep = ctx.choices[top].qcMinRep
        cont = ctx.choices[top].qcCont
        ctx.choicesLen = top
        # Stop repeating, try continuation.
        mode = if count >= minRep: mCont else: mFail
      of chQuantLazy:
        rollBackQuant(top)
        ctx.framesLen = ctx.choices[top].qcFramesLen
        let body {.cursor.} = ctx.nodeAt(ctx.choices[top].qcBody)
        let minRep = ctx.choices[top].qcMinRep
        let maxRep = ctx.choices[top].qcMaxRep
        let count = ctx.choices[top].qcCount
        let parent = ctx.choices[top].qcCont
        let phase = ctx.choices[top].qcPhase
        let pure = ctx.choices[top].qcPure
        ctx.choicesLen = top
        if phase == 0 and (maxRep < 0 or count < maxRep):
          var snap = NoCapOff
          if pure:
            ctx.pushChoice Choice(
              kind: chUndoScalars,
              uzFramesLen: ctx.framesLen.int32,
              uzScalars: saveScalars(ctx),
            )
          else:
            let saved = save(ctx)
            snap = saved.capOff
            ctx.pushChoice Choice(
              kind: chUndoState, usFramesLen: ctx.framesLen.int32, usSaved: saved
            )
          cont = pushFrame(
            ctx,
            Frame(
              kind: ckQuantLazyMore,
              parent: parent,
              qBody: body.id,
              qMinRep: minRep,
              qMaxRep: maxRep,
              qCount: count,
              qPure: pure,
              qSnap: snap,
              qSavedPos: ctx.pos,
            ),
          )
          node = body
          mode = mMatch
        else:
          mode = mFail
      of chUndoState:
        restore(ctx, ctx.choices[top].usSaved)
        ctx.framesLen = ctx.choices[top].usFramesLen
        ctx.choicesLen = top
        mode = mFail
      of chUndoSparse:
        restoreScalars(ctx, ctx.choices[top].upScalars)
        let undoOff = int(ctx.choices[top].upUndoOff)
        var i = ctx.capUndosLen
        while i > undoOff:
          dec i
          ctx.captures[int(ctx.capUndos[i].cuIdx)] = ctx.capUndos[i].cuSpan
        ctx.capUndosLen = undoOff
        ctx.framesLen = ctx.choices[top].upFramesLen
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
        let myDepth = int(ctx.choices[top].ucMyDepth)
        ctx.captures[int(ctx.choices[top].ucCapIdx)] = ctx.choices[top].ucSavedCap
        ctx.flags = ctx.choices[top].ucFlags
        # One test for both rare restores, as ``trackCloses`` is for the writes.
        if myDepth != -1:
          ctx.undoCloseRecords(top)
        ctx.choicesLen = top
        mode = mFail
      of chUndoAbsentEnd:
        ctx.absentEnd = ctx.choices[top].useAbsentPos
        ctx.choicesLen = top
        mode = mFail
      of chWidenAbsentEnd:
        ctx.absentEnd = ctx.choices[top].wsSavedEnd
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
        if lookbehindAltNext(ctx, top):
          cont = kCont
          ctx.framesLen = kFramesLen
          mode = mCont
        else:
          mode = mFail
      of chUndoCallout:
        let n {.cursor.} = ctx.nodeAt(ctx.choices[top].ucoNode)
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
  # ``resetForRegex`` overwrites these; default to unlimited so a context used
  # before a reset cannot trip the step limit.
  result.stepLimit = int.high
  result.attemptStepLimit = int.high
  if maxCapCount > 0:
    result.captures = newSeq[Span](maxCapCount + 1)
    # ``newSeq`` zero-fills, and ``Span(0, 0)`` is not ``UnsetSpan``.
    result.capturesDirty = true
    result.groupRecursionDepth = newSeq[int](maxCapCount)
    result.captureStacks = newSeq[seq[Span]](maxCapCount)

proc scratchCaps*(ctx: MatchContext): tuple[frames, choices, repPositions: int] =
  ## Buffer sizes (not live lengths); observe the release policy.
  (ctx.frames.len, ctx.choices.len, ctx.repPositions.len)

proc stepsUsed*(ctx: MatchContext): int =
  ## Steps charged by the last search, including the one that raised. For
  ## tests reading how much work a limit let through; a reset clears it.  An
  ## attempt run again ([stepLimitLagged]) is charged once.
  ctx.steps

proc stepReruns*(ctx: MatchContext): int =
  ## Attempts run again under a caught-up step limit, over ``ctx``'s life.
  ## For tests that need a rerun to have happened, not only its answer.
  ctx.rerunCount

proc noteScratchUsage(ctx: MatchContext) =
  ## Release oversized scratch buffers after several small searches in a row.
  ## ``choicesPeak`` stands in for frames (they grow together); ``repPeak``,
  ## ``capSavesPeak`` and ``capUndosPeak`` have their own marks, since a
  ## simple repeat pushes no choice and a wide snapshot pushes only one.
  ## Also resets live lengths left behind by ``RegexLimitError``.
  if ctx.capSavesPeak > CapSavesKeep or ctx.choicesPeak > ChoicesKeep or
      ctx.repPeak > RepPositionsKeep or ctx.capUndosPeak > CapUndosKeep:
    ctx.scratchQuiet = 0
    ctx.capUndosHigh = max(ctx.capUndosHigh, ctx.capUndosPeak)
  else:
    inc ctx.scratchQuiet
    if ctx.scratchQuiet >= ScratchQuietRuns:
      if ctx.capSaves.len > CapSavesKeep:
        ctx.capSaves = newSeqOfCap[Span](CapSavesKeep)
        ctx.capSavesLen = 0
      if ctx.frames.len > FramesKeep:
        ctx.frames = newSeq[Frame](FramesKeep)
        ctx.framesLen = 0
      if ctx.choices.len > ChoicesKeep:
        ctx.choices = newSeq[Choice](ChoicesKeep)
        ctx.choicesLen = 0
      if ctx.capUndosHigh > CapUndosKeep:
        ctx.capUndos = newSeq[CapUndo](CapUndosKeep)
        ctx.capUndosLen = 0
        ctx.capUndosHigh = 0
      if ctx.repPositions.len > RepPositionsKeep:
        ctx.repPositions = newSeq[int](RepPositionsKeep)
        ctx.repLen = 0
      ctx.scratchQuiet = 0
  ctx.capSavesPeak = 0
  ctx.capUndosPeak = 0
  ctx.choicesPeak = 0
  ctx.repPeak = 0

proc bindLeafGates(ctx: MatchContext, regex: ptr Regex) {.inline.} =
  ## Borrow the pattern's [LeafGate] table for the match about to run.
  ## ``regex`` is a pointer, not a value: ``ctx.gates`` points into the
  ## table's own buffer, which a copied parameter would not outlive.
  assert regex[].leafGates.len == 0 or regex[].leafGates.len == regex[].nodes.len,
    "leafGates must name every node of the tree or none of them"
  ctx.gates =
    if regex[].leafGates.len > 0:
      cast[ptr UncheckedArray[LeafGate]](unsafeAddr regex[].leafGates[0])
    else:
      nil
  ctx.gatesLen = regex[].leafGates.len

proc resetForRegex(
    ctx: MatchContext,
    subject: string,
    regex: ptr Regex,
    stepLimit: int,
    maxRecursionDepth: int,
    sameSubject: bool = false,
) =
  ## Reset per-regex buffers, reusing ``ctx``'s existing seq capacity.
  ## A search loop that reruns attempts sets ``budgetOrigin`` itself.
  ## ``sameSubject`` keeps subject-keyed memos when ``subject`` is the string
  ## the last search ran over; the buffer pointer is checked too.
  ## ``regex`` is borrowed, so every caller passes the address of its own
  ## parameter, never of a local that dies before the match runs.
  ##
  ## Called once per match; what the pattern alone decides is derived once per
  ## pattern, when the tree changes.
  ctx.subject = toSubject(subject)
  ctx.flags = regex[].flags
  bindLeafGates(ctx, regex) # Before the asserts below, which read it.
  # Not in the tree-keyed block below: this is the validity check for
  # ``ctx.gates``, which every bind retakes.
  ctx.boundFlags = regex[].flags
  ctx.graphemeMode = gmNone
  ctx.regex = regex
  # Keyed on the owned tree, not on ``regex`` (one stack slot shared by all
  # patterns); ``boundAst`` holds it against recycling.
  let leadLeafFor = cast[pointer](regex[].ast)
  if ctx.leadLeafFor != leadLeafFor:
    ctx.boundAst = regex[].ast
    ctx.leadLeafFor = leadLeafFor
    ctx.leadLeafTried = 0
    ctx.leadLeafSkips = 0
    ctx.leadLeafOff = false
    ctx.leadLeafCool = 0
    ctx.trackCaptureStacks = regex[].levelBackrefs
    ctx.trackOpenOrder = regex[].openOrder
    ctx.trackCloses = ctx.trackCaptureStacks or ctx.trackOpenOrder
    ctx.groupSlots = regex[].captureCount + 1
    ctx.capturesLen = ctx.groupSlots
    if ctx.trackOpenOrder:
      let opened = regex[].openedGroups
      ctx.capturesLen += opened.len
      ctx.openedBase = int32(ctx.groupSlots - opened.a)
    # Node ids name slots in this tree only; so does the cache keyed on one.
    ctx.seqCacheNode = NoNodeId
    ctx.leadRun = if regex[].leadRun == nil: NoNodeId else: regex[].leadRun.id
    # Only single-way leaves qualify; pin the compile-time guarantee.
    assert regex[].leadLeaf == nil or isSingleWayLeaf(ctx, regex[].leadLeaf)
    ctx.leadLeaf = if regex[].leadLeaf == nil: NoNodeId else: regex[].leadLeaf.id
    assert regex[].leadRepeat == nil or isSingleWayLeaf(ctx, regex[].leadRepeat)
    ctx.leadRepeat = if regex[].leadRepeat == nil: NoNodeId else: regex[].leadRepeat.id
    # Plain data keyed on the tree above, as the lead indices are.
    ctx.leadAnchorsLen = 0
    for a in regex[].leadAnchors:
      ctx.leadAnchors[ctx.leadAnchorsLen] = a
      inc ctx.leadAnchorsLen
    let capCount = regex[].captureCount
    # The internal buffers only grow, so their capacity survives a switch to
    # a regex with fewer captures; ``resetForPosition`` clears stale state.
    if capCount > ctx.groupRecursionDepth.len:
      ctx.groupRecursionDepth.setLen(capCount)
    if capCount > ctx.captureStacks.len:
      ctx.captureStacks.setLen(capCount)
  ctx.lookLimit = NoLookLimit
  ctx.absentEnd = subject.len
  # Subject-keyed: honour ``sameSubject`` only while the buffer pointer matches.
  if not sameSubject or ctx.seqRegionData != cast[pointer](ctx.subject.data):
    ctx.seqRegionEnd = -1
  ctx.seqRegionData = cast[pointer](ctx.subject.data)
  ctx.attemptStepLimit = if stepLimit > 0: stepLimit else: int.high
  # The first attempt's budget: no steps charged and no distance moved.
  ctx.stepLimit = ctx.attemptStepLimit
  ctx.maxRecursionDepth = maxRecursionDepth
  # Reset the per-search counters that used to be zero-initialized by
  # allocating a fresh ``MatchContext``.  ``steps`` is the entry points' to
  # clear, before an early return can leave the last search's count.
  ctx.absentScan = 0
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  ctx.chainDepth = 0
  ctx.choicesLen = 0
  ctx.capUndosLen = 0
  ctx.stackBase = currentStackAddr()
  noteScratchUsage(ctx)
  # ``captures`` is sized exactly on every bind (its groups copied into
  # ``Match.boundaries``): the unguarded ``captures[capIdx]`` writes must
  # survive ``-d:danger``, so no ``assert``. Re-sizing to the same length is free.
  if ctx.captures.len != ctx.capturesLen:
    ctx.captures.setLen(ctx.capturesLen)
    # ``setLen`` zero-fills new entries, and ``Span(0, 0)`` is not ``UnsetSpan``.
    ctx.capturesDirty = true

proc stepBudget(ctx: MatchContext, attemptSteps, attemptStart: int): int =
  ## The most ``steps`` may reach in the attempt that began at
  ## ``attemptStart`` with ``attemptSteps`` charged: the attempt's own limit,
  ## or the search's (``SearchStepsPerByte``) when that is less.  A limit
  ## summed over the start positions raises on a long subject of cheap
  ## attempts; one per attempt alone lets a pattern whose cost is polynomial
  ## in the subject run unchecked.
  let limit = ctx.attemptStepLimit
  if limit == int.high:
    return int.high
  # Only a search that has charged more than ``limit`` steps asks, so neither
  # sum comes near ``int.high``.
  let earned = SearchStepsPerByte * abs(attemptStart - ctx.budgetOrigin)
  min(attemptSteps + limit, limit + earned)

proc stepLimitLagged(
    ctx: MatchContext, attemptSteps, attemptStart: int
): bool {.noinline.} =
  ## Whether the ``RegexLimitError`` an attempt just raised is ``stepLimit``
  ## lagging the attempt's budget rather than the attempt overrunning it.  If
  ## so, the steps go back to where the attempt began and ``stepLimit`` up to
  ## its budget, for the caller to run the attempt again from the start.
  ##
  ## Comparing ``steps`` with the budget itself would put a call that returns
  ## on the matcher's hottest paths, measured at up to 2.5% of the matcher's
  ## instructions.  A lagging ``stepLimit`` costs nothing until a search
  ## charges that many steps.  It is never above the budget: neither term of
  ## [stepBudget] shrinks as the search moves on.  Only the step check leaves
  ## ``steps`` past ``stepLimit``, so the other limits are told apart by that
  ## alone.
  ##
  ## An attempt runs at most twice, so a search does at most about twice the
  ## work its budget counts.  The second runs pile up only where attempts
  ## each cost more than half the limit.  Catching ``stepLimit`` up before
  ## every attempt that might pass it would avoid them, but measured at up
  ## to 10% where attempts are cheap, and 0.9% with the catch-up spaced out.
  if ctx.steps <= ctx.stepLimit:
    return false
  let budget = stepBudget(ctx, attemptSteps, attemptStart)
  if ctx.stepLimit >= budget:
    return false
  ctx.steps = attemptSteps
  ctx.stepLimit = budget
  inc ctx.rerunCount
  true

proc resetForPosition(ctx: MatchContext, startPos: int, searchStart: int) =
  ## Reset per-position state without reallocating.
  ctx.pos = startPos
  ctx.flags = ctx.regex[].flags
  ctx.searchStart = searchStart
  ctx.keepStart = startPos
  ctx.leadRunEnd = -1
  ctx.openClock = 0
  ctx.lookLimit = NoLookLimit
  ctx.absentEnd = ctx.subject.len
  ctx.absentScan = 0
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  ctx.chainDepth = 0
  ctx.choicesLen = 0
  ctx.capUndosLen = 0
  ctx.stackBase = currentStackAddr()
  ctx.framesLen = 0
  ctx.repLen = 0
  ctx.capSavesLen = 0
  # Almost every attempt fails having touched none of these, so each clear is
  # guarded: ``setLen`` is an out-of-line call that walks destructors for
  # ``stackLensSaves``, and the loops are waste when nothing was written.
  if ctx.stackLensSaves.len > 0:
    ctx.stackLensSaves.setLen(0)
  if ctx.capturesDirty:
    for i in 0 ..< ctx.captures.len:
      ctx.captures[i] = UnsetSpan
    ctx.capturesDirty = false
  if ctx.groupDepthDirty:
    for i in 0 ..< ctx.groupRecursionDepth.len:
      ctx.groupRecursionDepth[i] = 0
    ctx.groupDepthDirty = false
  if ctx.captureStacksDirty:
    for i in 0 ..< ctx.captureStacks.len:
      ctx.captureStacks[i].setLen(0)
    ctx.captureStacksDirty = false
  if ctx.calloutCounters.len > 0:
    ctx.calloutCounters.clear()
  ctx.graphemeMode = gmNone

proc writeFoundCopy(m: var Match, captures: seq[Span], n, startChar: int) {.inline.} =
  ## Fill ``m`` from the first ``n`` slots of a capture vector, its groups,
  ## reusing ``m.boundaries``' capacity.
  ## Used while ``captures`` is still live (e.g. in the findLongest frame,
  ## which may re-enter and mutate ``ctx.captures``).
  ##
  ## ``startChar`` is the position the attempt started at, and the caller has
  ## to pass it alongside ``captures``: ``\K`` may have moved
  ## ``captures[0].a`` off it in either direction -- see ``Match.startChar``.
  m.found = true
  m.startChar = startChar
  m.boundaries.setLen(n)
  for i in 0 ..< n:
    m.boundaries[i] = captures[i]

proc writeNotFound(m: var Match) {.inline.} =
  m.found = false
  m.startChar = -1
  m.boundaries.setLen(0)

proc releaseBorrowed(ctx: MatchContext) {.inline.} =
  ## Clear borrowed refs so stale reads fail loudly; frame buffers hold plain
  ## data only. Cached lead indices stay (resolved through ``ctx.regex``, nil
  ## here), and so does ``leadAnchors``: plain data keyed on the bound tree,
  ## which ``boundAst`` holds against recycling. ``gates`` is a borrow, so it
  ## is cleared here and restored on every bind.
  ctx.regex = nil
  ctx.gates = nil
  ctx.gatesLen = 0
  ctx.subject = Subject(data: nil, size: 0)

template runAttempt(ctx: MatchContext, startPos, searchStart: int, attempt: untyped) =
  ## Run ``attempt``, the match tried at ``startPos``, and once more from the
  ## start if [stepLimitLagged] says the limit it raised on lagged its budget.
  block:
    let attemptSteps = ctx.steps
    while true:
      resetForPosition(ctx, startPos, searchStart)
      try:
        attempt
        break
      except RegexLimitError:
        if not stepLimitLagged(ctx, attemptSteps, startPos):
          raise

proc searchImplInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    sameSubject: bool = false,
    options: MatchOptions = {},
) =
  ## In-place variant of ``searchImpl``: writes into ``m``, reusing
  ## ``ctx``'s buffers and ``m.boundaries``' capacity across calls.
  ## ``ctx`` must be caller-owned and single-threaded.  ``sameSubject`` is
  ## for a scan whose next attempt runs over the same string; it is passed
  ## on to ``resetForRegex``.
  defer:
    releaseBorrowed(ctx)
  let findLongest = rfFindLongest in regex.flags
  if findLongest:
    ctx.flBestLen = -1
    ctx.flBestMatch.found = false
    ctx.flBestMatch.boundaries.setLen(0)
  writeNotFound(m)
  ctx.steps = 0
  # Quick reject: if the pattern requires a specific byte, check its presence.
  # ``extractRequiredByte`` only ever yields an ASCII byte of a case-sensitive
  # literal, and such a literal is compared byte for byte, so the byte has to
  # occur literally for any match to exist.
  # Split scalars; the set is wide.
  let rbValid = regex.requiredByte.valid
  let rbByte = regex.requiredByte.byte
  if rbValid and indexOfByte(subject, start, rbByte) < 0:
    noteScratchUsage(ctx)
    return
  # The same for a string or a byte set from anywhere in the pattern, the
  # case-folded included.  Every match holds it at or after ``start``.
  if regex.requiredLit.kind != rlNone and requiredLitAbsent(ctx, subject, regex, start):
    noteScratchUsage(ctx)
    return
  ctx.matchOptions = options
  resetForRegex(
    ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth, sameSubject
  )
  ctx.budgetOrigin = start
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
  # Bound the loop by the next required byte; off when anchors or literal scan bound it.
  let useRegion =
    rbValid and regex.requiredByte.regionOk and fc.kind != fcAnchorStart and
    not regex.semiEndAnchored and not byteScan
  # Copy the set only when used.
  var regionPrefix: set[uint8]
  if useRegion:
    regionPrefix = regex.requiredByte.prefix
  var regionEnd = if useRegion: -1 else: int.high ## Region end; ``int.high`` means none.
  var regionTried = 0
  var regionSkipped = 0
  # Leading ``(?<=lit)`` fixes every start at ``offset`` past the literal's
  # first byte, so one memchr positions the scan. Out under
  # ``semiEndAnchored``, which moves ``startPos`` itself, and under
  # ``fcAnchorStart``, whose only candidate is position 0.
  var lbActive =
    regex.leadBehind.valid and fc.kind != fcAnchorStart and not regex.semiEndAnchored
  let lbByte = regex.leadBehind.byte
  let lbOffset = regex.leadBehind.offset
  var lbTried = 0
  var lbSkipped = 0
  ## Landing the scan may not jump onto; the skip resumes once the walk is past it.
  var lbHeld = -1
  # One memchr cursor per byte of a two-member lead set, each holding its next
  # hit.  ``NoLeadHit`` never compares below ``startPos``, so it is sticky; -1
  # always does, so the first candidate refreshes the cursor.  Both are valid
  # only because ``startPos`` never decreases below its value at the last
  # refresh: a hit cached as "first at/after ``startPos``" answers any later
  # ``startPos`` too, but a rewind would read it stale and ``NoLeadHit`` would
  # wrongly call the subject exhausted.
  const NoLeadHit = high(int)
  var hitA = -1
  var hitB = -1
  # ``exhausted`` means no candidate is left. ``leadLeafNode`` is resolved once:
  # ``ctx.leadLeaf`` is fixed for the search.
  var exhausted = false
  let leadLeafNode {.cursor.} = nodeAt(ctx, ctx.leadLeaf)
  let leadRepeatNode {.cursor.} = nodeAt(ctx, ctx.leadRepeat)
  # Hoisted: one load instead of a field read per candidate.
  let hasLeadAnchors = ctx.leadAnchorsLen > 0
  let hasPrefilter = leadLeafNode != nil or leadRepeatNode != nil or hasLeadAnchors
  # [nextRepeatPairPos] answers the same refusal [leadRepeatHolds] does, eight
  # positions at a time, so it is on whenever that prefilter is.  Out under
  # ``fcAnchorStart``, whose only candidate is position 0 and which the skip
  # would walk away from.
  var pairScan = leadRepeatNode != nil and fc.kind != fcAnchorStart
  # Counters for the same stand-down the region skip uses.
  var pairTried = 0
  var pairSkipped = 0
  # ``\G``/``\y``/``\Y`` read this state, which ``resetForPosition`` otherwise
  # writes only after the prefilter runs.
  ctx.searchStart = start
  ctx.graphemeMode = gmNone
  # Set once an attempt may have moved the prefilter's inputs.
  var prefilterDirty = false
  while true:
    if startPos > subject.len:
      exhausted = true
    if not exhausted and startPos > regionEnd:
      # Walk back over the union, floored at the scan position.
      let q = indexOfByte(subject, startPos, rbByte)
      if q < 0:
        exhausted = true
      else:
        var l = q
        while l > startPos and subject[l - 1].uint8 in regionPrefix:
          dec l
        if l > startPos and not regionStopHolds(subject, l, regionPrefix):
          # Invalid stop skips nothing.
          l = startPos
        inc regionTried
        regionSkipped += l - startPos
        regionEnd = q
        startPos = l
        # Stand down when occurrences skip too little.
        if regionTried >= RegionTrial and regionSkipped < regionTried * RegionPayoff:
          regionEnd = int.high
    if lbActive and startPos > lbHeld and not exhausted and
        not lbHolds(subject, startPos, lbOffset, lbByte):
      let q = indexOfByte(subject, max(0, startPos - lbOffset), lbByte)
      if q < 0 or q + lbOffset > subject.len:
        exhausted = true
      elif not byteScan and not charHeadAt(subject, q + lbOffset):
        # [charHeadAt] refuses positions the forward chain still reaches, so
        # the scan cannot jump onto this landing. Hold the skip until the walk
        # has passed it rather than standing down for the rest of the search:
        # with ``offset >= 2`` a multi-byte character after the literal makes
        # a mid-character landing routine on well-formed input too.
        lbHeld = q + lbOffset
      else:
        inc lbTried
        lbSkipped += q + lbOffset - startPos
        startPos = q + lbOffset
        if lbTried >= RegionTrial and lbSkipped < lbTried * RegionPayoff:
          lbActive = false
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
        var found = false
        if fc.pairOk:
          let a = fc.pair[0]
          let b = fc.pair[1]
          while startPos < subject.len:
            if hitA < startPos:
              let q = indexOfByte(subject, startPos, a)
              hitA = if q < 0: NoLeadHit else: q
            if hitB < startPos:
              let q = indexOfByte(subject, startPos, b)
              hitB = if q < 0: NoLeadHit else: q
            let hit = min(hitA, hitB)
            if hit == NoLeadHit:
              startPos = subject.len
              break
            # A byte inside a character is no start position. [charHeadAt]
            # decides that in a bounded look-back; the walk, linear in the
            # jump, answers what it cannot (malformed input).
            startPos =
              if byteScan or charHeadAt(subject, hit):
                hit
              else:
                # ``byteScan`` is false here: the condition above ruled it out.
                advanceChainTo(subject, startPos, hit, false)
            if startPos >= subject.len:
              break
            if subject[startPos].uint8 in fc.bytes:
              found = true
              break
        else:
          # One load per byte: the lead byte decides both whether the position
          # is a candidate and how far the next one is.
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
      # ``(leaf)\1``: scan for the byte pair the backreference needs rather
      # than testing one position at a time.  After the first-byte skip, so
      # that skip walks only up to the position this one lands on, and out once
      # ``exhausted`` is set, where it would walk the rest of the subject for
      # an answer the break below throws away.
      if pairScan and not exhausted:
        let q = nextRepeatPairPos(subject, startPos)
        if q < 0:
          exhausted = true
        else:
          inc pairTried
          pairSkipped += q - startPos
          startPos = q
          # Stand down when candidates skip too little.
          if pairTried >= RegionTrial and pairSkipped < pairTried * RegionPayoff:
            pairScan = false
    if exhausted:
      break
    if startPos > regionEnd:
      # First-byte skip left the region; rebind.
      continue

    # Leading-prefix prefilter: a refused position cannot match. Restores the
    # inputs an attempt may have moved, as ``resetForPosition`` does.
    var prefiltered = false
    if hasPrefilter:
      if ctx.leadLeafOff:
        dec ctx.leadLeafCool
        if ctx.leadLeafCool <= 0:
          ctx.leadLeafOff = false
          ctx.leadLeafTried = 0
          ctx.leadLeafSkips = 0
      else:
        if prefilterDirty:
          ctx.flags = regex.flags
          ctx.lookLimit = NoLookLimit
          ctx.absentEnd = subject.len
          ctx.searchStart = start
          ctx.graphemeMode = gmNone
          prefilterDirty = false
        ctx.pos = startPos
        ctx.leadRunEnd = -1
        # Assertions first for locality: they touch the bytes the leaf reads.
        prefiltered =
          (hasLeadAnchors and not leadAnchorsHold(ctx)) or
          (leadLeafNode != nil and not leadLeafMatches(ctx, leadLeafNode)) or
          (leadRepeatNode != nil and not leadRepeatHolds(ctx, leadRepeatNode))
        # Adaptive off switch: an accepted position costs a second character
        # test the matcher repeats anyway, so stay on well past break-even.
        # Halve (not reset) at capacity: keeps the recent ratio, bounds both
        # counters, and covers the refuses-everything case, which never
        # reaches the off check below.
        if ctx.leadLeafTried >= LeadLeafCapacity:
          ctx.leadLeafTried = ctx.leadLeafTried shr 1
          ctx.leadLeafSkips = ctx.leadLeafSkips shr 1
        inc ctx.leadLeafTried
        if prefiltered:
          inc ctx.leadLeafSkips
        elif ctx.leadLeafTried >= LeadLeafTrial and
            ctx.leadLeafSkips * LeadLeafPayoff < ctx.leadLeafTried:
          ctx.leadLeafOff = true
          ctx.leadLeafCool = LeadLeafRetry

    if not prefiltered:
      prefilterDirty = true
      var matched = false
      runAttempt(ctx, startPos, start):
        if findLongest:
          # Find longest: try all match alternatives at this position.  The
          # ckFindLongestRec frame mutates ``ctx.flBestMatch`` whenever a
          # longer match is found and returns false to force backtracking.
          # A rerun finds the same ones again, which leaves it as it was.
          let fid = pushFrame(
            ctx, Frame(kind: ckFindLongestRec, parent: TrueCont, flStartPos: startPos)
          )
          discard matchWithCont(ctx, regex.ast, fid)
          ctx.framesLen = fid
        else:
          matched = matchNode(ctx, regex.ast)
      if matched:
        ctx.capturesDirty = true
        ctx.captures[0] = span(startPos, ctx.pos)
        if ctx.keepStart != startPos:
          ctx.captures[0].a = min(ctx.keepStart, ctx.pos)
        # Copy into m so that ctx.captures stays usable across calls.
        writeFoundCopy(m, ctx.captures, ctx.groupSlots, startPos)
        return

    # Advance to the next candidate start position.  Neither a plain
    # continuation-byte test nor the declared length is right alone — the
    # prefilters above land on a stray 0x80..0xBF byte and inside a truncated
    # sequence — so ``nextScanPos`` skips only what the decoder really covers.
    if startPos >= subject.len:
      break
    if not byteScan and ctx.leadRunEnd > startPos + 1:
      # A failed attempt refuted the continuation at every skipped start, so
      # jump to the run end. Byte scan excluded: it may land mid-character.
      # Prefiltered positions never reach this (their branch clears the end).
      startPos = ctx.leadRunEnd
    else:
      startPos =
        if byteScan:
          startPos + 1
        else:
          nextScanPos(subject, startPos)

  if findLongest and ctx.flBestMatch.found:
    # ctx.flBestMatch lives on the reusable context.  Copy its
    # boundaries into ``m`` so the next call may overwrite the slot.
    writeFoundCopy(
      m, ctx.flBestMatch.boundaries, ctx.flBestMatch.boundaries.len,
      ctx.flBestMatch.startChar,
    )

proc searchImpl*(
    subject: string,
    regex: Regex,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    options: MatchOptions = {},
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
    options = options,
  )

proc searchBackwardImplInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    options: MatchOptions = {},
) =
  ## In-place variant of ``searchBackwardImpl``.  Reuses ``ctx``.
  defer:
    releaseBorrowed(ctx)
  writeNotFound(m)
  ctx.steps = 0
  # Quick reject: if the pattern requires a specific byte, check its presence.
  # ``extractRequiredByte`` only ever yields an ASCII byte of a case-sensitive
  # literal, and such a literal is compared byte for byte, so the byte has to
  # occur literally for any match to exist.
  if regex.requiredByte.valid and indexOfByte(subject, 0, regex.requiredByte.byte) < 0:
    noteScratchUsage(ctx)
    return
  # A match may run past ``start`` to the end, so the whole subject counts.
  if regex.requiredLit.kind != rlNone and requiredLitAbsent(ctx, subject, regex, 0):
    noteScratchUsage(ctx)
    return
  ctx.matchOptions = options
  var startPos =
    if start >= 0:
      min(start, subject.len)
    else:
      subject.len
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
  ctx.budgetOrigin = startPos
  let fc = regex.firstCharInfo
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
    var matched = false
    runAttempt(ctx, startPos, subject.len):
      matched = matchNode(ctx, regex.ast)

    if matched:
      ctx.capturesDirty = true
      ctx.captures[0] = span(startPos, ctx.pos)
      if ctx.keepStart != startPos:
        ctx.captures[0].a = min(ctx.keepStart, ctx.pos)
      writeFoundCopy(m, ctx.captures, ctx.groupSlots, startPos)
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
    options: MatchOptions = {},
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
    options = options,
  )

proc matchAtImplInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    options: MatchOptions = {},
) =
  ## In-place variant of ``matchAtImpl``.  Reuses ``ctx``.
  defer:
    releaseBorrowed(ctx)
  writeNotFound(m)
  ctx.steps = 0
  ctx.matchOptions = options
  # One attempt, whose budget ``resetForRegex`` sets: nothing to rerun.
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
  resetForPosition(ctx, pos, pos)
  if matchNode(ctx, regex.ast):
    ctx.capturesDirty = true
    ctx.captures[0] = span(pos, ctx.pos)
    if ctx.keepStart != pos:
      ctx.captures[0].a = min(ctx.keepStart, ctx.pos)
    writeFoundCopy(m, ctx.captures, ctx.groupSlots, pos)

proc matchAtImpl*(
    subject: string,
    regex: Regex,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    options: MatchOptions = {},
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
    options = options,
  )
