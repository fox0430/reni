## ``rfLineMode``: each line of the subject, without its ``\n``, searched as a
## subject of its own (notes/LINE_MODE.md).  The scan is ``engine``'s, run
## over one line's view at a time.
##
## Its own module, out of ``engine``'s translation unit, with the scan's
## byte helpers over a view: what is added to ``engine`` moves gcc's inlining
## in ``runMachine`` even where ``runMachine`` never calls it.  ``engine``
## shares its scan loops as dirty templates, and a helper name in them
## resolves where they are expanded, here to the copies below.

import std/[bitops, importutils]
import types
import engine {.all.}

privateAccess(MatchContext)
privateAccess(Subject)

proc c_memchr(
  s: pointer, c: cint, n: csize_t
): pointer {.importc: "memchr", header: "<string.h>".}

proc indexOfByte(s: Subject, start: int, b: uint8): int {.inline.} =
  ## [indexOfByte] over a view, through libc's ``memchr``.
  if start >= s.size:
    return -1
  let q = c_memchr(addr s.data[start], cint(b), csize_t(s.size - start))
  if q == nil:
    -1
  else:
    cast[int](q) -% cast[int](s.data)

# The scan's byte helpers over a view.  ``engine`` keeps its own over a
# ``string``, text for text as they were: made generic there, the change of
# instance moved gcc's inlining in ``runMachine`` (+0.46% of the grammars'
# instructions).  Each is a copy of its ``string`` namesake in ``engine``;
# keep the two in step.

proc nextRepeatPairPos(s: Subject, start: int): int =
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

proc nextScanPos(s: Subject, p: int): int {.inline.} =
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

proc prevCharHead(s: Subject, p: int): int {.inline.} =
  ## Head of the char before ``p`` (backward scan step).
  if p <= 0:
    0
  else:
    leftAdjustCharHead(s, p - 1)

proc rightAdjustCharHead(s: Subject, p: int): int {.inline.} =
  ## Left-adjust, then step one char forward again (clamped to ``s.len``).
  let q = leftAdjustCharHead(s, p)
  if q < p:
    min(q + encLen(s[q].uint8), s.len)
  else:
    p

proc firstLeadByte(s: Subject, first, last: int): int {.noinline.} =
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

proc advanceChainTo(s: Subject, start, target: int, byteScan: bool): int {.inline.} =
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

proc regionStopHolds(s: Subject, l: int, prefix: set[uint8]): bool {.inline.} =
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

proc lbHolds(s: Subject, p, offset: int, byte: uint8): bool {.inline.} =
  ## Whether ``p`` is a start the leading look-behind allows.
  p >= offset and s[p - offset].uint8 == byte

proc charHeadAt(s: Subject, p: int): bool {.inline.} =
  ## Whether the character walk can land on ``p``. On malformed input it may
  ## refuse a position the forward chain reaches, so a refusal stands the
  ## skip down rather than moving it.
  let lo = max(0, p - MaxCharByteLen)
  for i in countdown(p - 1, lo):
    let n = encLen(s[i].uint8)
    if n > 1 and i + n > p:
      return false
  true

proc semiEndScanStart(s: Subject, regex: Regex, start: int): int =
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

proc lastNewlineIn(s: string, lo, hi: int): int =
  ## Index of the last ``\n`` in ``[lo, hi)``, or -1.  A word at a time from
  ## the top: line mode reads back to a line's start once per line, and a
  ## minified file's lines run to megabytes.
  var i = hi
  when cpuEndian == littleEndian:
    # Exact per byte, unlike the borrow trick [nextRepeatPairPos] uses:
    # ``(x and 0x7F) + 0x7F`` cannot carry out of its byte, so bit 7 of a
    # byte ends up set exactly when the byte of ``x`` is not zero, and the
    # highest zero byte is the last newline.
    const Newlines = 0x0A0A0A0A0A0A0A0A'u64
    const Lows = 0x7F7F7F7F7F7F7F7F'u64
    const Highs = 0x8080808080808080'u64
    while i - 8 >= lo:
      var w: uint64
      copyMem(addr w, unsafeAddr s[i - 8], 8)
      let x = w xor Newlines
      let zero = not (((x and Lows) + Lows) or x) and Highs
      if zero != 0:
        return i - 8 + ((63 - countLeadingZeroBits(zero)) shr 3)
      i -= 8
  while i > lo:
    dec i
    if s[i] == '\n':
      return i
  -1

proc nextLineRunePos*(s: string, p: int, crlf: bool): int =
  ## [nextRunePos] for a line-mode scan: the declared length, cut short at
  ## the end of the line.  A lead byte whose sequence the line's end cuts is
  ## the last character of its line, so the next start is that end: the
  ## ``\n``, or under ``rfCrlf`` (``crlf``) the ``\r`` that ends the line.
  ## The byte after a ``\n`` always starts a line.
  if p >= s.len:
    return p + 1
  let stop = min(p + encLen(s[p].uint8), s.len)
  for i in p + 1 ..< stop:
    if s[i] == '\n' or crlf and s[i] == '\r' and (i + 1 == s.len or s[i + 1] == '\n'):
      return i
  stop

proc lineMemoFor(ctx: MatchContext, s: string, sameSubject: bool): bool {.inline.} =
  ## Line mode: whether the line memo describes ``s``, the buffer a scan's
  ## last search matched in.  Only a scan (``sameSubject``) may say so.
  sameSubject and s.len > 0 and ctx.lineMemoLen == s.len and
    ctx.lineMemoData == cast[pointer](unsafeAddr s[0])

proc lineStartAt(ctx: MatchContext, s: string, p: int, memo: bool): int =
  ## Line mode: the start of the line holding ``p``.  A ``p`` on a ``\n``
  ## belongs to the line that ``\n`` ends.  ``s.len`` when ``p`` holds no
  ## line: past a final ``\n``, or in the empty subject.  ``memo`` says
  ## [lineMemoFor] holds.
  if p == 0:
    return 0
  if s[p - 1] == '\n':
    return p
  if memo and ctx.lineMemoStart <= p and p <= ctx.lineMemoEnd:
    return ctx.lineMemoStart
  lastNewlineIn(s, 0, p) + 1

proc lineEndAt(s: string, p: int): int {.inline.} =
  ## Line mode: the ``\n`` that ends the line holding ``p``, or ``s.len``.
  let q = indexOfByte(s, p, uint8('\n'))
  if q < 0: s.len else: q

proc contentEnd(s: string, nl: int, crlf: static bool): int {.inline.} =
  ## Line mode: where the line ended by ``nl`` (its ``\n``, or ``s.len``)
  ## ends.  That is ``nl`` itself, except under ``rfCrlf`` (``crlf``), where
  ## a ``\r`` before ``nl`` lies outside the line.  A line's start follows a
  ## ``\n``, so a ``\r`` at ``nl - 1`` always belongs to the line.  A
  ## position past the result and up to ``nl`` holds no line.
  when crlf:
    if nl > 0 and s[nl - 1] == '\r':
      nl - 1
    else:
      nl
  else:
    nl

proc bindLine(ctx: MatchContext, s: string, ls, le, regionEnd: int): Subject =
  ## Line mode: point the matcher at the line ``[ls, le)`` of ``s``, with the
  ## state ``resetForRegex`` keys on the subject.  The view is the whole
  ## subject the matcher sees, so a look-around, an anchor or a character
  ## never reaches past the line.  ``regionEnd`` is the region memo's end
  ## to keep, -1 for none: a scan keeps it when the view is the one it was
  ## walked on.
  result =
    Subject(data: cast[ptr UncheckedArray[char]](unsafeAddr s[ls]), size: le - ls)
  ctx.subject = result
  ctx.lookLimit = NoLookLimit
  ctx.absentEnd = result.size
  ctx.seqRegionEnd = regionEnd
  ctx.seqRegionData = cast[pointer](result.data)

proc shiftMatch(m: var Match, base: int) =
  ## Line mode: move a match found in a line's view to the subject's offsets.
  ## An unset group (``a < 0``) stays unset.
  m.startChar += base
  for i in 0 ..< m.boundaries.len:
    if m.boundaries[i].a >= 0:
      m.boundaries[i].a += base
      m.boundaries[i].b += base

proc noteLine(ctx: MatchContext, s: string, ls, le: int) {.inline.} =
  ## Line mode: remember the line a match was found in, for [lineStartAt].
  ctx.lineMemoData = cast[pointer](unsafeAddr s[0])
  ctx.lineMemoLen = s.len
  ctx.lineMemoStart = ls
  ctx.lineMemoEnd = le

proc lineOptions(options: MatchOptions, ls: int, holdsStart: bool): MatchOptions =
  ## Line mode: the options that hold in the line beginning at ``ls``, which
  ## holds ``start`` when ``holdsStart``.  Each says one place is not what
  ## it seems, and holds in the line that has that place.
  ## ``moNotBeginString``: the buffer does not begin a string, so the line
  ## at its offset 0 does not begin one; every later line does.
  ## ``moNotBeginPosition``: the search did not begin at ``start``, where
  ## ``\G`` holds.
  if ls == 0 and moNotBeginString in options:
    result.incl moNotBeginString
  if holdsStart and moNotBeginPosition in options:
    result.incl moNotBeginPosition

proc lineCandidate(s: string, regex: Regex, p: int): int =
  ## Line mode: the first offset at or after ``p`` where what every match
  ## holds occurs (``Regex.lineLit``, else the required byte, else the first
  ## byte), or -1 when it does not.  The line around it is the first that can
  ## match: everything the matcher reads lies in its line, so a line without
  ## it has no match.  ``p`` itself when the pattern names nothing.
  if regex.lineLit.kind != rlNone:
    return findRequired(s, regex.lineLit, p)
  if regex.requiredByte.valid:
    return indexOfByte(s, p, regex.requiredByte.byte)
  let fc = regex.firstCharInfo
  case fc.kind
  of fcByte:
    indexOfByte(s, p, fc.byte)
  of fcByteSet:
    if fc.pairOk:
      let a = indexOfByte(s, p, fc.pair[0])
      let b = indexOfByte(s, p, fc.pair[1])
      if a < 0:
        b
      elif b < 0:
        a
      else:
        min(a, b)
    else:
      indexOfAnyByte(s, p, fc.bytes)
  of fcNone, fcAnchorStart, fcLineStart:
    p

proc scanLine(
    ctx: MatchContext,
    subject: Subject,
    regex: Regex,
    m: var Match,
    start: int,
    findLongest: bool,
    rbValid: bool,
    rbByte: uint8,
) =
  ## ``engine``'s scan over one line's view, from ``start``.  A match comes
  ## back in the view's offsets.
  searchScan()

proc scanLineBackward(
    ctx: MatchContext, subject: Subject, regex: Regex, m: var Match, start: int
) =
  ## ``engine``'s backward scan over one line's view, back from ``start``.  A
  ## match comes back in the view's offsets.
  var startPos = start
  searchBackwardScan()

proc searchLinesIn(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int,
    stepLimit: int,
    maxRecursionDepth: int,
    sameSubject: bool,
    options: MatchOptions,
    crlf: static bool,
) =
  ## ``searchImplInto`` under ``rfLineMode``: each line, without its ``\n``,
  ## is a subject of its own.  The line holding ``start`` is searched from
  ## there, each later one from its start, and the first match found is
  ## reported in the subject's offsets.
  ##
  ## One pass over the whole subject ([lineCandidate]) skips the lines that
  ## lack a byte every match holds; the scan runs over each other line's
  ## view.  The steps are counted over the whole call, as one search's are:
  ## a budget per line would let a call run ``lines * limit`` steps.
  ##
  ## Under ``rfCrlf`` a ``start`` that holds no line, the ``\n`` of a
  ## ``\r\n`` or the end after a final ``\r``, begins with the next line.
  defer:
    releaseBorrowed(ctx)
  let findLongest = rfFindLongest in regex.flags
  if findLongest:
    ctx.flBestLen = -1
    ctx.flBestMatch.found = false
    ctx.flBestMatch.boundaries.setLen(0)
  writeNotFound(m)
  ctx.steps = 0
  if callLimitRefuses(regex, maxRecursionDepth):
    noteScratchUsage(ctx)
    return
  # A line is part of the subject, so what the whole of it lacks after
  # ``start``, every line does.
  if regex.requiredByte.valid and
      indexOfByte(subject, start, regex.requiredByte.byte) < 0:
    noteScratchUsage(ctx)
    return
  if regex.requiredLit.kind != rlNone and requiredLitAbsent(ctx, subject, regex, start):
    noteScratchUsage(ctx)
    return
  # The region memo, as the last search left it.  ``resetForRegex`` keys it
  # on the whole subject's address, which is not the address of a view, so
  # it would drop the memo of every line but the first.
  let regionData = ctx.seqRegionData
  let regionEnd = ctx.seqRegionEnd
  resetForRegex(
    ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth, sameSubject
  )
  let memo = lineMemoFor(ctx, subject, sameSubject)
  var ls = lineStartAt(ctx, subject, start, memo)
  var fromPos = start
  var first = true
  while ls < subject.len:
    let c = lineCandidate(subject, regex, fromPos)
    if c < 0:
      break
    if c > fromPos:
      let nl = lastNewlineIn(subject, fromPos, c)
      if nl >= 0:
        ls = nl + 1
        fromPos = ls
        first = false
    # The memo's line ends where it did: a scan through one long line would
    # read to its end once per match.
    let le =
      if memo and ctx.lineMemoStart <= c and c <= ctx.lineMemoEnd:
        ctx.lineMemoEnd
      else:
        lineEndAt(subject, c)
    let ce = contentEnd(subject, le, crlf)
    when crlf:
      if fromPos > ce:
        # ``start`` lies past the line's end and holds no line.
        if le >= subject.len:
          break
        ls = le + 1
        fromPos = ls
        first = false
        continue
    let view = bindLine(
      ctx,
      subject,
      ls,
      ce,
      if first and sameSubject and regionData == cast[pointer](unsafeAddr subject[ls]):
        regionEnd
      else:
        -1,
    )
    ctx.matchOptions = lineOptions(options, ls, first)
    ctx.budgetOrigin = start - ls
    scanLine(
      ctx,
      view,
      regex,
      m,
      fromPos - ls,
      findLongest,
      regex.requiredByte.valid,
      regex.requiredByte.byte,
    )
    if not m.found and findLongest and ctx.flBestMatch.found:
      writeFoundCopy(
        m, ctx.flBestMatch.boundaries, ctx.flBestMatch.boundaries.len,
        ctx.flBestMatch.startChar,
      )
    if m.found:
      shiftMatch(m, ls)
      noteLine(ctx, subject, ls, le)
      return
    if le >= subject.len:
      break
    ls = le + 1
    fromPos = ls
    first = false

proc searchLinesInto*(
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
  ## [searchLinesIn], with ``rfCrlf`` fixed.  Tested in the loop, the flag
  ## cost a pattern without it about 13 instructions a line (``\w+$``,
  ## +0.24% of the GREP corpus's); this call costs about 9 a search.  Both
  ## forms in line here cost 16 a search: gcc spills more in the merged
  ## loop.
  if rfCrlf in regex.flags:
    searchLinesIn(
      ctx, subject, regex, m, start, stepLimit, maxRecursionDepth, sameSubject, options,
      true,
    )
  else:
    searchLinesIn(
      ctx, subject, regex, m, start, stepLimit, maxRecursionDepth, sameSubject, options,
      false,
    )

proc searchBackwardLinesIn(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int,
    stepLimit: int,
    maxRecursionDepth: int,
    options: MatchOptions,
    crlf: static bool,
) =
  ## ``searchBackwardImplInto`` under ``rfLineMode``: the line holding
  ## ``start``, back from there, then each earlier line back from its end.
  ## A ``start`` that holds no line, past a final ``\n``, begins with the
  ## last line.  Under ``rfCrlf`` one on the ``\n`` of a ``\r\n``, or
  ## after a final ``\r``, begins at the end of the line before it.
  defer:
    releaseBorrowed(ctx)
  writeNotFound(m)
  ctx.steps = 0
  if callLimitRefuses(regex, maxRecursionDepth):
    noteScratchUsage(ctx)
    return
  if regex.requiredByte.valid and indexOfByte(subject, 0, regex.requiredByte.byte) < 0:
    noteScratchUsage(ctx)
    return
  if regex.requiredLit.kind != rlNone and requiredLitAbsent(ctx, subject, regex, 0):
    noteScratchUsage(ctx)
    return
  let origin =
    if start >= 0:
      min(start, subject.len)
    else:
      subject.len
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
  var fromPos = origin
  var ls = lineStartAt(ctx, subject, fromPos, false)
  if ls >= subject.len:
    if subject.len == 0:
      return
    # Past the final ``\n``: the last line, from its end.
    fromPos = subject.len - 1
    ls = lineStartAt(ctx, subject, fromPos, false)
  var first = true
  while true:
    let ce = contentEnd(subject, lineEndAt(subject, fromPos), crlf)
    let view = bindLine(ctx, subject, ls, ce, -1)
    ctx.matchOptions = lineOptions(options, ls, first)
    ctx.budgetOrigin = origin - ls
    scanLineBackward(
      ctx,
      view,
      regex,
      m,
      when crlf:
        min(fromPos, ce) - ls
      else:
        fromPos - ls,
    )
    if m.found:
      shiftMatch(m, ls)
      return
    if ls == 0:
      break
    first = false
    fromPos = ls - 1
    ls = lineStartAt(ctx, subject, fromPos, false)

proc searchBackwardLinesInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    options: MatchOptions = {},
) =
  ## [searchBackwardLinesIn], with ``rfCrlf`` fixed, as [searchLinesInto]
  ## fixes it.
  if rfCrlf in regex.flags:
    searchBackwardLinesIn(
      ctx, subject, regex, m, start, stepLimit, maxRecursionDepth, options, true
    )
  else:
    searchBackwardLinesIn(
      ctx, subject, regex, m, start, stepLimit, maxRecursionDepth, options, false
    )

proc matchAtLinesInto*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
    options: MatchOptions = {},
) =
  ## ``matchAtImplInto`` under ``rfLineMode``: one attempt at ``pos`` in the
  ## line holding it.  A ``pos`` on a ``\n`` is the end of the line it ends;
  ## one past a final ``\n`` holds no line and never matches, nor, under
  ## ``rfCrlf``, one on the ``\n`` of a ``\r\n`` or after a final ``\r``.
  defer:
    releaseBorrowed(ctx)
  writeNotFound(m)
  ctx.steps = 0
  if callLimitRefuses(regex, maxRecursionDepth):
    noteScratchUsage(ctx)
    return
  let ls = lineStartAt(ctx, subject, pos, false)
  if ls >= subject.len:
    noteScratchUsage(ctx)
    return
  let le = lineEndAt(subject, pos)
  let ce =
    if rfCrlf in regex.flags:
      contentEnd(subject, le, true)
    else:
      le
  if pos > ce:
    noteScratchUsage(ctx)
    return
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
  discard bindLine(ctx, subject, ls, ce, -1)
  ctx.matchOptions = lineOptions(options, ls, true)
  let rel = pos - ls
  resetForPosition(ctx, rel, rel)
  if matchNode(ctx, regex.ast):
    ctx.capturesDirty = true
    ctx.captures[0] = span(rel, ctx.pos)
    if ctx.keepStart != rel:
      ctx.captures[0].a = min(ctx.keepStart, ctx.pos)
    writeFoundCopy(m, ctx.captures, ctx.groupSlots, rel)
    shiftMatch(m, ls)
