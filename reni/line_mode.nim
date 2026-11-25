## ``rfLineMode``: each line of the subject, without its ``\n``, searched as a
## subject of its own (notes/LINE_MODE.md).  The scan is ``engine``'s, run
## over one line's view at a time.
##
## Its own module, out of ``engine``'s translation unit, with the scan's
## byte helpers over a view: what is added to ``engine`` moves gcc's inlining
## in ``runMachine`` even where ``runMachine`` never calls it.  ``engine``
## shares its scan loops as dirty templates, and a helper name in them
## resolves where they are expanded, here to the copies below.

import std/[bitops, importutils, unicode]
import types, byte_scan, unicode_utils
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

proc indexOfAnyByte(
    s: Subject, start: int, bs: set[uint8], sc: ByteSetScan
): int {.inline.} =
  ## [indexOfAnyByte] over a view.
  findAnyByte(s.data, start, s.size, bs, sc)

proc indexOfPrefix(s: Subject, start: int, ps: PrefixScan): int {.inline.} =
  ## [indexOfPrefix] over a view.
  findPrefix(s.data, start, s.size, ps)

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

proc lastNewlineIn(s: string, lo, hi: int, high: var bool): int =
  ## Index of the last ``\n`` in ``[lo, hi)``, or -1, and in ``high``
  ## whether the bytes after it, up to ``hi``, hold one past ASCII.  A word at
  ## a time from the top: line mode reads back to a line's start once per
  ## line, and a minified file's lines run to megabytes.  The candidate
  ## line's malformed-byte check ([searchLinesIn]) rides along: the loop runs
  ## anyway.
  const Highs = 0x8080808080808080'u64
  var i = hi
  var seen = 0'u64 # Bytes read, ORed; bit 7 of each byte is what counts.
  when cpuEndian == littleEndian:
    # Exact per byte, unlike the borrow trick [nextRepeatPairPos] uses:
    # ``(x and 0x7F) + 0x7F`` cannot carry out of its byte, so bit 7 of a
    # byte ends up set exactly when the byte of ``x`` is not zero, and the
    # highest zero byte is the last newline.
    const Newlines = 0x0A0A0A0A0A0A0A0A'u64
    const Lows = 0x7F7F7F7F7F7F7F7F'u64
    while i - 8 >= lo:
      var w: uint64
      copyMem(addr w, unsafeAddr s[i - 8], 8)
      let x = w xor Newlines
      let zero = not (((x and Lows) + Lows) or x) and Highs
      if zero != 0:
        # Only the bytes above the newline are the line's.  ``top shl 1``
        # wraps to 0 for the word's last byte, which leaves none.
        let top = 1'u64 shl (63 - countLeadingZeroBits(zero))
        high = ((seen or (w and not ((top shl 1) - 1))) and Highs) != 0
        return i - 8 + ((63 - countLeadingZeroBits(zero)) shr 3)
      seen = seen or w
      i -= 8
  while i > lo:
    dec i
    if s[i] == '\n':
      high = (seen and Highs) != 0
      return i
    seen = seen or uint64(s[i].uint8)
  high = (seen and Highs) != 0
  -1

proc lastNewlineIn(s: string, lo, hi: int): int {.inline.} =
  ## Index of the last ``\n`` in ``[lo, hi)``, or -1.
  var high: bool
  lastNewlineIn(s, lo, hi, high)

proc wellFormedLen(s: string, i, last: int): int {.inline.} =
  ## Line mode: the length of the well-formed UTF-8 sequence at ``i`` that
  ## ends by ``last``, or 0 when none starts there.  Well-formed is RFC
  ## 3629's: no overlong form, no surrogate, nothing past U+10FFFF.
  let b = s[i].uint8
  template cont(k: int, lo = 0x80'u8, hi = 0xBF'u8): bool =
    i + k < last and s[i + k].uint8 >= lo and s[i + k].uint8 <= hi

  case b
  of 0x00'u8 .. 0x7F'u8:
    1
  of 0xC2'u8 .. 0xDF'u8:
    if cont(1): 2 else: 0
  of 0xE0'u8 .. 0xEF'u8:
    let lo = if b == 0xE0'u8: 0xA0'u8 else: 0x80'u8
    let hi = if b == 0xED'u8: 0x9F'u8 else: 0xBF'u8
    if cont(1, lo, hi) and cont(2): 3 else: 0
  of 0xF0'u8 .. 0xF4'u8:
    let lo = if b == 0xF0'u8: 0x90'u8 else: 0x80'u8
    let hi = if b == 0xF4'u8: 0x8F'u8 else: 0xBF'u8
    if cont(1, lo, hi) and cont(2) and cont(3): 4 else: 0
  else:
    0

const
  HighBytes = {0x80'u8 .. 0xFF'u8}
  HighScan = initByteSetScan(HighBytes)
    ## The bytes past ASCII, laid out for [findAnyByte].

proc hasHighByte(s: string, first, last: int): bool {.inline.} =
  ## Line mode: whether ``[first, last)`` holds a byte past ASCII, for the
  ## parts of a line that the scans to its ends ([lineEndAt], [lastNewlineIn])
  ## do not read.  A word at a time, the last word overlapping the one before:
  ## lines are short, and [findAnyByte] cost them more than the bytes do.
  const Highs = 0x8080808080808080'u64
  var i = first
  if last - first >= 8:
    while i + 8 <= last:
      var w: uint64
      copyMem(addr w, unsafeAddr s[i], 8)
      if (w and Highs) != 0'u64:
        return true
      i += 8
    if i < last:
      var w: uint64
      copyMem(addr w, unsafeAddr s[last - 8], 8)
      return (w and Highs) != 0'u64
    return false
  while i < last:
    if s[i].uint8 >= 0x80'u8:
      return true
    inc i
  false

# [wellFormedLen]'s sequences as a DFA, one row per byte: state ``q``'s next
# state is the six bits at ``6 * q`` of the byte's row, kept as its own
# shift, so a step is a load and a shift (Per Vognsen's shift-based DFA).  0
# accepts; the rest wait for continuation bytes; 8 is the sticky error.
const Utf8Dfa = block:
  const
    Acc = 0
    Need1 = 1 # Any one continuation byte.
    Need2 = 2
    Need3 = 3
    AfterE0 = 4 # A0..BF, then one more: no overlong form.
    AfterED = 5 # 80..9F, then one more: no surrogate.
    AfterF0 = 6 # 90..BF, then two more: no overlong form.
    AfterF4 = 7 # 80..8F, then two more: nothing past U+10FFFF.
    Err = 8
  var t: array[256, uint64]
  for b in 0 .. 255:
    let cont = b in 0x80 .. 0xBF
    for q in Acc .. Err:
      let next =
        case q
        of Acc:
          case b
          of 0x00 .. 0x7F: Acc
          of 0xC2 .. 0xDF: Need1
          of 0xE0: AfterE0
          of 0xED: AfterED
          of 0xE1 .. 0xEC, 0xEE .. 0xEF: Need2
          of 0xF0: AfterF0
          of 0xF1 .. 0xF3: Need3
          of 0xF4: AfterF4
          else: Err
        of Need1:
          if cont: Acc else: Err
        of Need2:
          if cont: Need1 else: Err
        of Need3:
          if cont: Need2 else: Err
        of AfterE0:
          if b in 0xA0 .. 0xBF: Need1 else: Err
        of AfterED:
          if b in 0x80 .. 0x9F: Need1 else: Err
        of AfterF0:
          if b in 0x90 .. 0xBF: Need2 else: Err
        of AfterF4:
          if b in 0x80 .. 0x8F: Need2 else: Err
        else:
          Err
      t[b] = t[b] or (uint64(6 * next) shl (6 * q))
  t

proc wellFormed(s: string, first, last: int): bool =
  ## Line mode: whether ``[first, last)`` is well-formed UTF-8 throughout,
  ## what ``nextMalformed(s, first, last) >= last`` says, for the check of a
  ## candidate line that holds a byte past ASCII.  Such lines run long
  ## (minified files), and [nextMalformed] takes a branch per character on
  ## them: here a word of ASCII is skipped and any other word steps [Utf8Dfa]
  ## through its bytes, which branch on nothing.
  const Highs = 0x8080808080808080'u64
  const ErrShift = 6 * 8
  var st = 0'u64 # The state's shift, in the low six bits.
  var i = first
  when cpuEndian == littleEndian:
    while i + 8 <= last:
      var w: uint64
      copyMem(addr w, unsafeAddr s[i], 8)
      i += 8
      if (st and 63) == 0 and (w and Highs) == 0:
        continue
      for k in 0 .. 7:
        st = Utf8Dfa[(w shr (8 * k)) and 0xFF] shr (st and 63)
      if (st and 63) == ErrShift:
        return false
  while i < last:
    st = Utf8Dfa[s[i].uint8] shr (st and 63)
    inc i
  (st and 63) == 0

proc nextMalformed(s: string, first, last: int): int =
  ## Line mode: the first byte in ``[first, last)`` that is no part of a
  ## well-formed UTF-8 sequence ([wellFormedLen]), or ``last`` when there is
  ## none; a sequence ``last`` cuts short is malformed.  A malformed
  ## sequence reports its first byte only; the walk resumes after it, so
  ## each of its bytes is malformed in turn unless a well-formed sequence
  ## starts there.  ``first`` must not be inside a well-formed sequence.
  ## ASCII is skipped by [findAnyByte].  This finds where a line's stretches
  ## end; whether it holds a malformed byte at all is [wellFormed]'s answer.
  var i = first
  while i < last:
    if s[i].uint8 < 0x80'u8:
      let h = findAnyByte(
        cast[ptr UncheckedArray[char]](unsafeAddr s[0]), i, last, HighBytes, HighScan
      )
      if h < 0:
        return last
      i = h
    let n = wellFormedLen(s, i, last)
    if n == 0:
      return i
    i += n
  last

proc prevMalformed(s: string, first, p, last: int): int =
  ## Line mode: the last byte before ``p`` that [nextMalformed] reports, or
  ## ``first - 1`` when there is none.  No walk from the start is needed: a
  ## well-formed sequence begins with a byte no other sequence holds, so a
  ## byte past ASCII belongs to one exactly when the nearest byte at or
  ## before it that is no continuation byte, at most three back, begins a
  ## sequence that reaches it.  ``p`` may be inside a sequence.  ASCII is
  ## skipped a word at a time.
  const Highs = 0x8080808080808080'u64
  var i = p - 1
  while i >= first:
    if s[i].uint8 < 0x80'u8:
      dec i
      while i - 7 >= first:
        var w: uint64
        copyMem(addr w, unsafeAddr s[i - 7], 8)
        if (w and Highs) != 0'u64:
          break
        i -= 8
      continue
    var k = i
    let limit = max(first, i - 3)
    while k > limit and (s[k].uint8 and 0xC0'u8) == 0x80'u8:
      dec k
    if k + wellFormedLen(s, k, last) <= i:
      return i
    i = k - 1
  first - 1

proc nextLineRunePos*(s: string, p: int): int =
  ## [nextRunePos] for a line-mode scan: past the well-formed character at
  ## ``p``, or past the one byte at ``p`` when none starts there.  A
  ## malformed byte is matched by nothing and every place beside it is a
  ## start ([scanStretches]), so the step goes one byte past it rather than
  ## its declared length, which would skip the starts inside.  A well-formed
  ## character holds no ``\n`` or ``\r``, so the step never passes a line's
  ## end: that ``\n``, or under ``rfCrlf`` the ``\r``, is reached as a start.
  if p >= s.len:
    return p + 1
  p + max(wellFormedLen(s, p, s.len), 1)

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

proc lineStartAt(s: string, p: int, high: var bool): int =
  ## Line mode: [lineStartAt] without a memo, and in ``high`` whether
  ## ``[result, p)`` holds a byte past ASCII.
  high = false
  if p == 0 or s[p - 1] == '\n':
    return p
  lastNewlineIn(s, 0, p, high) + 1

proc lineEndAt(s: string, p: int): int {.inline.} =
  ## Line mode: the ``\n`` that ends the line holding ``p``, or ``s.len``.
  let q = indexOfByte(s, p, uint8('\n'))
  if q < 0: s.len else: q

proc lineEndAt(s: string, p: int, high: var bool): int {.inline.} =
  ## Line mode: [lineEndAt], and in ``high`` whether ``[p, result)`` holds a
  ## byte past ASCII.  With the block scan, one pass finds either; without
  ## it, ``memchr`` then [hasHighByte].
  when BlockScan:
    if p >= s.len:
      high = false
      return s.len
    let q = findNewlineOrHigh(cast[ptr UncheckedArray[char]](unsafeAddr s[0]), p, s.len)
    if q < 0:
      high = false
      s.len
    elif s[q] == '\n':
      high = false
      q
    else:
      high = true
      lineEndAt(s, q)
  else:
    result = lineEndAt(s, p)
    high = hasHighByte(s, p, result)

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
  ## walked on.  The view's data is reached by offset, since an empty
  ## stretch ([bindStretch]) may sit at the end of ``s``.
  result = Subject(
    data: cast[ptr UncheckedArray[char]](cast[uint](unsafeAddr s[0]) + uint(ls)),
    size: le - ls,
  )
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

proc noteLine(
    ctx: MatchContext, s: string, ls, le: int, clean: bool, stretch, stretchEnd: int
) {.inline.} =
  ## Line mode: remember the line a match was found in, for [lineStartAt],
  ## whether it holds no malformed byte (``clean``), and else the stretch
  ## the match is in.
  ctx.lineMemoData = cast[pointer](unsafeAddr s[0])
  ctx.lineMemoLen = s.len
  ctx.lineMemoStart = ls
  ctx.lineMemoEnd = le
  ctx.lineMemoClean = clean
  ctx.lineMemoStretch = stretch
  ctx.lineMemoStretchEnd = stretchEnd

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

proc prefixCandidate(s: string, regex: Regex, p: int): int =
  ## [lineCandidate] under ``prefixLines``: the first offset at or after ``p``
  ## where ``prefixScan`` holds and a byte of ``lineLit``'s set follows in the
  ## line.  A match begins no earlier than the line's first hit, and holds such
  ## a byte from there on.  The prefix alone would pick nearly every line for
  ## ``(?:the|and) [qz]``: how rare words are is not told by their letters.
  ## From a hit without one, the next such byte's line is the first that can
  ## match, so either of the two, where rare, skips the lines between.
  result = indexOfPrefix(s, p, regex.prefixScan)
  while result >= 0:
    let lit = findRequired(s, regex.lineLit, regex.lineScan, result)
    if lit < 0:
      return -1
    let nl = lastNewlineIn(s, result, lit)
    if nl < 0:
      return
    result = indexOfPrefix(s, nl + 1, regex.prefixScan)

proc lineCandidate(s: string, regex: Regex, p: int): int =
  ## Line mode: the first offset at or after ``p`` where what every match
  ## holds occurs, or -1 when it does not: ``Regex.prefixScan`` and
  ## ``Regex.lineLit`` in one line where ``Regex.prefixLines`` is set, which
  ## the compiler decides ([prefixPicksLines]); without it ``Regex.lineLit``,
  ## else the required byte, else the first byte.  The line around it is the
  ## first that can match: everything the matcher reads lies in its line, so a
  ## line without it has no match.  ``p`` itself when the pattern names nothing.
  if regex.prefixLines:
    return prefixCandidate(s, regex, p)
  if regex.lineLit.kind != rlNone:
    return findRequired(s, regex.lineLit, regex.lineScan, p)
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
      indexOfAnyByte(s, p, fc.bytes, regex.leadScan)
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

proc clearCuts(ctx: MatchContext) {.inline.} =
  ctx.cut = false
  ctx.cutStart = false
  ctx.cutEnd = false
  ctx.cutPrevValid = false
  ctx.cutPrevWord = false

proc readCutPrev(ctx: MatchContext, s: string, ls, a: int) =
  ## Line mode: how rg reads the character before the stretch at ``a``,
  ## which a malformed byte begins (``MatchContext.cutPrevValid``): back
  ## from ``a - 1`` over up to three continuation bytes, not past the line's
  ## start ``ls``, and the character that starts there and ends by ``a``, if
  ## one does -- regex-automata's ``decode_last``.  Only a malformed
  ## continuation byte before ``a`` leads anywhere; before any other
  ## malformed byte rg reads nothing.  rg reads past the line there when no
  ## literal prefilters the pattern; here, as in its prefiltered search, the
  ## walk stops at the line's start.
  ctx.cutPrevValid = false
  ctx.cutPrevWord = false
  if (s[a - 1].uint8 and 0xC0'u8) != 0x80'u8:
    return
  var k = a - 1
  let limit = max(ls, a - 4)
  while k > limit and (s[k].uint8 and 0xC0'u8) == 0x80'u8:
    dec k
  if nextMalformed(s, k, a) > k:
    var code: int32
    var next: int
    discard decodeAt(s, k, code, next)
    ctx.cutPrevValid = true
    ctx.cutPrevWord = isWordChar(Rune(code), false)

proc bindStretch(
    ctx: MatchContext, s: string, ls, ce, a, b, regionEnd: int, opts: MatchOptions
): Subject =
  ## Line mode: point the matcher at the stretch ``[a, b)`` of the line
  ## ``[ls, ce)``, between malformed bytes or the line's ends, and set the
  ## cut flags and what precedes a cut start ([readCutPrev]).  A cut is no
  ## line edge (``engine.anchorHolds``, ``engine.atCut``).  ``regionEnd`` is
  ## as [bindLine]'s.
  result = bindLine(ctx, s, a, b, regionEnd)
  ctx.cutStart = a > ls
  ctx.cutEnd = b < ce
  ctx.cut = ctx.cutStart or ctx.cutEnd
  if ctx.cutStart:
    readCutPrev(ctx, s, ls, a)
  else:
    ctx.cutPrevValid = false
    ctx.cutPrevWord = false
  ctx.matchOptions = opts

proc lineStartOnly(regex: Regex): bool =
  ## Line mode: whether every match begins where ``^`` or ``\A`` holds, which
  ## in a line is its start alone: a line holds no ``\n``, and a cut is no
  ## edge.  ``^a`` has its byte for a hint and its anchor among the leading
  ## assertions; ``(?:^a|^b)`` may have the hint alone.
  regex.firstCharInfo.kind in {fcAnchorStart, fcLineStart} or
    regex.leadAnchors * {akLineBegin, akStringBegin} != {}

proc lastStretchOnly(regex: Regex): bool =
  ## Line mode: whether every match lies in its line's last stretch: it begins
  ## where ``$``, ``\z`` or ``\Z`` holds, which in a line is its end alone, for
  ## the reason [lineStartOnly] gives, or ends there (``Regex.lineTail``).
  regex.lineTail != {} or
    regex.leadAnchors * {akLineEnd, akStringEnd, akStringEndOrNewline} != {}

const NoHit = high(int)

proc stretchCandidate(s: string, regex: Regex, p, last: int, hitA, hitB: var int): int =
  ## Line mode: [lineCandidate] inside one line, whose content ends at
  ## ``last``, for the walk over its stretches: no match lies in a stretch of
  ## ``[p, last)`` that ends before the result, nor in any when it is -1.
  ## Nothing past ``last`` is read, or a line would cost the way to the next
  ## occurrence again.  Of a string only its least likely byte is looked for.
  ## ``hitA`` and ``hitB`` hold the next hit of each byte of a pair (-1 at
  ## first, ``NoHit`` for none) and ``p`` never goes back, so a byte the line
  ## lacks is looked for once.  ``prefixLines`` is not read here: the prefix
  ## may be rarer, but a line of stretches holds malformed bytes and is seldom
  ## met.
  let view = Subject(data: cast[ptr UncheckedArray[char]](unsafeAddr s[0]), size: last)
  case regex.lineLit.kind
  of rlString:
    return indexOfByte(view, p, uint8(regex.lineLit.str[regex.lineLit.at]))
  of rlSet:
    return
      if p >= last:
        -1
      else:
        indexOfAnyByte(view, p, regex.lineLit.set, regex.lineScan)
  of rlNone:
    discard
  if regex.requiredByte.valid:
    return indexOfByte(view, p, regex.requiredByte.byte)
  let fc = regex.firstCharInfo
  case fc.kind
  of fcByte:
    indexOfByte(view, p, fc.byte)
  of fcByteSet:
    if fc.pairOk:
      if hitA < p:
        let q = indexOfByte(view, p, fc.pair[0])
        hitA = if q < 0: NoHit else: q
      if hitB < p:
        let q = indexOfByte(view, p, fc.pair[1])
        hitB = if q < 0: NoHit else: q
      let hit = min(hitA, hitB)
      if hit == NoHit: -1 else: hit
    elif p >= last:
      -1
    else:
      # No prefix here, which would leave a ``lineLit`` (``prefixPicksLines``),
      # so ``leadScan`` is ``fc.bytes`` laid out.
      indexOfAnyByte(view, p, fc.bytes, regex.leadScan)
  of fcNone, fcAnchorStart, fcLineStart:
    p

proc scanStretches(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    ls, walkFrom, walkEnd, ce, fromPos, start, candidate: int,
    regionData: pointer,
    regionEnd: int,
    opts: MatchOptions,
    findLongest: bool,
    found: var Span,
): bool {.noinline.} =
  ## Line mode: the forward scan of a line ``[ls, ce)`` that holds a
  ## malformed byte.  Since no match spans one, each stretch between them,
  ## empty ones included, is searched as a view of its own ([bindStretch]),
  ## from the one that holds ``fromPos`` on.  Returns whether a match was
  ## found; it comes back in the subject's offsets, and ``found`` is its
  ## stretch.  ``\G`` holds only in the stretch that holds ``fromPos``.
  ##
  ## The walk begins at ``walkFrom``: ``ls``, or a memoized stretch start at
  ## or before ``fromPos``; ``walkEnd`` is then that stretch's end, and
  ## otherwise -1.  The region memo, ``regionEnd`` walked on the view at
  ## ``regionData``, is kept in that stretch alone: only its view is known to
  ## end where it did.  Out of line, as the rare path.
  ##
  ## Under ``findLongest`` every stretch of the line is searched, and the
  ## longest match of them all is the answer, the first of those as long
  ## (``ctx.flBestLen`` carries the best from stretch to stretch).
  ##
  ## Under [lineStartOnly] only the line's first stretch can match, under a
  ## leading ``\G`` only the one that holds ``fromPos``; the walk goes no
  ## further.  A stretch that ends before the next place of what every match
  ## holds -- ``candidate`` at first, [lineCandidate] from ``fromPos``, then
  ## [stretchCandidate] -- has no match, for the reason a line without it has
  ## none: a stretch is all its matcher sees.  The walk goes straight to the
  ## stretch of that place, and under [lastStretchOnly] to the line's last.
  defer:
    clearCuts(ctx)
  let startOnly = lineStartOnly(regex)
  let searchBeginOnly = akSearchBegin in regex.leadAnchors
  var a = walkFrom
  var known = walkEnd
  var best = -1
  var cand =
    if lastStretchOnly(regex):
      ce
    else:
      min(candidate, ce)
  var hitA, hitB = -1
  # Inside the kept stretch there is nothing to look back for: a scan would
  # read back to its start once per match.
  if cand > a and (known < 0 or cand > known):
    let to = prevMalformed(subject, a, cand, ce) + 1
    if to > a:
      a = to
      known = -1
  while not (startOnly and (a > ls or fromPos > ls)):
    let b =
      if known >= 0:
        known
      else:
        nextMalformed(subject, a, ce)
    if b >= fromPos:
      var o = opts
      if a > fromPos:
        o.incl moNotBeginPosition
      let data = cast[pointer](cast[uint](unsafeAddr subject[0]) + uint(a))
      let keep = if known >= 0 and regionData == data: regionEnd else: -1
      let bestLen = ctx.flBestLen
      let view = bindStretch(ctx, subject, ls, ce, a, b, keep, o)
      ctx.budgetOrigin = start - a
      scanLine(
        ctx,
        view,
        regex,
        m,
        max(fromPos, a) - a,
        findLongest,
        regex.requiredByte.valid,
        regex.requiredByte.byte,
      )
      if m.found:
        shiftMatch(m, a)
        found = Span(a: a, b: b)
        return true
      if findLongest and ctx.flBestLen > bestLen:
        best = a
        found = Span(a: a, b: b)
      if searchBeginOnly:
        break
    if b >= ce:
      break
    a = b + 1
    known = -1
    if cand < a:
      cand = stretchCandidate(subject, regex, a, ce, hitA, hitB)
      if cand < 0:
        break
    if cand > a:
      a = prevMalformed(subject, a, cand, ce) + 1
  if best < 0:
    return false
  writeFoundCopy(
    m, ctx.flBestMatch.boundaries, ctx.flBestMatch.boundaries.len,
    ctx.flBestMatch.startChar,
  )
  shiftMatch(m, best)
  true

proc scanStretchesBackward(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    ls, ce, fromPos, origin: int,
    opts: MatchOptions,
): bool {.noinline.} =
  ## Line mode: [scanStretches] for the backward scan.  The stretches are
  ## searched back from the one that holds ``fromPos``, each later one back
  ## from its end.  The backward scan's ``\G`` is the line's end, so it
  ## holds in the line's last stretch alone; under [lastStretchOnly] only that
  ## one is searched, and under [lineStartOnly] only the line's first.
  ##
  ## Each stretch's start is found back from its end ([prevMalformed]), so
  ## the walk reads no further back than the match and keeps no list.
  defer:
    clearCuts(ctx)
  # The stretch that holds ``fromPos`` ends at the first cut at or past it,
  # or at the line's end.
  var a =
    if lineStartOnly(regex):
      ls
    else:
      prevMalformed(subject, ls, fromPos, ce) + 1
  var b = nextMalformed(subject, a, ce)
  let lastOnly = akSearchBegin in regex.leadAnchors or lastStretchOnly(regex)
  if lastOnly and b < ce:
    return false
  while true:
    var o = opts
    if b < ce:
      o.incl moNotBeginPosition
    let view = bindStretch(ctx, subject, ls, ce, a, b, -1, o)
    ctx.budgetOrigin = origin - a
    scanLineBackward(ctx, view, regex, m, min(fromPos, b) - a)
    if m.found:
      shiftMatch(m, a)
      return true
    if a == ls or lastOnly:
      return false
    b = a - 1
    a = prevMalformed(subject, ls, b, ce) + 1

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
  let tail = regex.lineTail != {}
  while ls < subject.len:
    let c = lineCandidate(subject, regex, fromPos)
    if c < 0:
      break
    # Whether the line holds a byte past ASCII, which only such a line need
    # be checked for malformed bytes, is read on the way by the scans that
    # find its start and end: ``[headFrom, c)`` by the one back from ``c``,
    # and ``[c, le)`` by the one forward.  Read apart, every candidate line
    # ran a loop of its own length.
    var headHigh, tailHigh = false
    var headFrom = c
    if c > fromPos:
      let nl = lastNewlineIn(subject, fromPos, c, headHigh)
      if nl >= 0:
        ls = nl + 1
        fromPos = ls
        first = false
      headFrom = fromPos
    # The memo's line ends where it did, and its check stands, so a scan
    # through one long line need not read to its end again.
    let memoLine = memo and ctx.lineMemoStart <= c and c <= ctx.lineMemoEnd
    let le =
      if memoLine:
        ctx.lineMemoEnd
      else:
        lineEndAt(subject, c, tailHigh)
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
    if tail and (ce <= ls or subject[ce - 1].uint8 notin regex.lineTail):
      # No match ends as this line does.
      if le >= subject.len:
        break
      ls = le + 1
      fromPos = ls
      first = false
      continue
    let clean =
      if memoLine:
        ctx.lineMemoClean
      else:
        # Neither scan read ``[ls, headFrom)``, the part before ``start`` of
        # the line it lies in.
        let high =
          headHigh or tailHigh or (headFrom > ls and hasHighByte(subject, ls, headFrom))
        not high or wellFormed(subject, ls, ce)
    if not clean:
      var walkFrom = ls
      var walkEnd = -1
      if memoLine and ctx.lineMemoStretch <= fromPos:
        walkFrom = ctx.lineMemoStretch
        # A caller may put a ``\r`` before the line's ``\n`` or take it away
        # between two calls, which moves ``ce``: the end stands only where it
        # is still the line's or at a byte past ASCII, as a malformed one is.
        let e = ctx.lineMemoStretchEnd
        if e == ce or e < ce and subject[e].uint8 >= 0x80'u8:
          walkEnd = e
      var stretch: Span
      if scanStretches(
        ctx,
        subject,
        regex,
        m,
        ls,
        walkFrom,
        walkEnd,
        ce,
        fromPos,
        start,
        c,
        regionData,
        if sameSubject: regionEnd else: -1,
        lineOptions(options, ls, first),
        findLongest,
        stretch,
      ):
        noteLine(ctx, subject, ls, le, false, stretch.a, stretch.b)
        return
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
      noteLine(ctx, subject, ls, le, true, ls, ce)
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
  let tail = regex.lineTail != {}
  while true:
    let ce = contentEnd(subject, lineEndAt(subject, fromPos), crlf)
    if tail and (ce <= ls or subject[ce - 1].uint8 notin regex.lineTail):
      discard # No match ends as this line does.
    elif hasHighByte(subject, ls, ce) and not wellFormed(subject, ls, ce):
      if scanStretchesBackward(
        ctx,
        subject,
        regex,
        m,
        ls,
        ce,
        min(fromPos, ce),
        origin,
        lineOptions(options, ls, first),
      ):
        return
    else:
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
    clearCuts(ctx)
  writeNotFound(m)
  ctx.steps = 0
  if callLimitRefuses(regex, maxRecursionDepth):
    noteScratchUsage(ctx)
    return
  # The scans to the line's ends also read whether it holds a byte past
  # ASCII, as [searchLinesIn]'s do; only such a line is checked further.
  var headHigh, tailHigh = false
  let ls = lineStartAt(subject, pos, headHigh)
  if ls >= subject.len:
    noteScratchUsage(ctx)
    return
  let le = lineEndAt(subject, pos, tailHigh)
  let ce =
    if rfCrlf in regex.flags:
      contentEnd(subject, le, true)
    else:
      le
  if pos > ce:
    noteScratchUsage(ctx)
    return
  resetForRegex(ctx, subject, unsafeAddr regex, stepLimit, maxRecursionDepth)
  # The stretch holding ``pos`` when the line holds a malformed byte
  # ([scanStretches]): a ``pos`` on a malformed byte ends the stretch before
  # it, one just past it begins the next.
  var a = ls
  if (headHigh or tailHigh) and not wellFormed(subject, ls, ce):
    a = prevMalformed(subject, ls, pos, ce) + 1
    let b = nextMalformed(subject, a, ce)
    discard bindStretch(ctx, subject, ls, ce, a, b, -1, lineOptions(options, ls, true))
  else:
    discard bindLine(ctx, subject, ls, ce, -1)
    ctx.matchOptions = lineOptions(options, ls, true)
  let rel = pos - a
  resetForPosition(ctx, rel, rel)
  if matchNode(ctx, regex.ast):
    ctx.capturesDirty = true
    ctx.captures[0] = span(rel, ctx.pos)
    if ctx.keepStart != rel:
      ctx.captures[0].a = min(ctx.keepStart, ctx.pos)
    writeFoundCopy(m, ctx.captures, ctx.groupSlots, rel)
    shiftMatch(m, a)
