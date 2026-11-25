## Looking for the first (or last) byte of a set: the scan's lead set
## (``fcByteSet`` past two members), a required byte set (``rlSet``) and line
## mode's set literal.  A byte at a time, a set costs a load and a bit test per
## byte; here, where the set is a few runs of consecutive bytes, sixteen bytes
## are tested at once with SSE2, which every x86-64 has.
##
## [findPrefix] tests the first bytes of a match together, for a pattern such
## as ``foo|bar`` whose first byte alone is everywhere.
##
## The block loops are their own module's, out of ``engine``'s translation
## unit: what is added there moves gcc's inlining in ``runMachine`` even where
## ``runMachine`` never calls it (notes/GREP_WORKLOAD.md §3.8).  The probe and
## the byte loop of [findAnyByte] and [rfindAnyByte] are inlined where they
## are called, ``engine`` too: called instead, they cost the bench's matcher
## 0.13% more instructions (``\p{Han}+`` 1.9%) and the grammars 0.04%.

import std/bitops

const MaxScanRuns* = 8
  ## Runs of consecutive bytes a set may have and still be tested a block at
  ## a time.  Each run costs one compare per block (three under a wider run),
  ## so a set of more runs reads faster a byte at a time.

const ScalarProbe {.intdefine: "reniScalarProbe".} = 4
  ## Bytes [findAnyByte] and [rfindAnyByte] test one at a time before the
  ## block loop.

const PrefixProbe {.intdefine: "reniPrefixProbe".} = 2
  ## Starts [findPrefix] tests one at a time before the block loop: where
  ## matches sit close together, the next begins a byte or so on.

const PrefixMemchrAfter {.intdefine: "reniPrefixMemchrAfter".} = 256
  ## Starts [findPrefix] passes over, none with its first byte in its set,
  ## before it looks for a pair by ``memchr``, which reads text that lacks
  ## both bytes several times as fast.

type ByteSetScan* = object
  ## A byte set laid out for the block test: ``runs`` runs, of which the first
  ## ``singles`` are one byte wide.  ``runs`` is 0 when the set is read a byte
  ## at a time, the set itself being the caller's.  Each byte is stored
  ## sixteen times over, the block's width, so a scan loads it rather than
  ## spreading it on every call: a set with a common byte is looked for over
  ## a few bytes at a time, and the spreading cost more than the reading.
  singles*: uint8
  runs*: uint8
  lo*: array[MaxScanRuns, array[16, uint8]] ## Each run's first byte.
  width*: array[MaxScanRuns, array[16, uint8]] ## Each run's last byte less its first.

const MaxPrefixLen* = 3 ## Positions a [PrefixScan] tests at once.

type PrefixScan* = ref object
  ## The byte sets of ``len`` bytes one after another, each laid out for the
  ## block test; ``sets`` spells them for the ends of the data.  They are the
  ## first every match consumes (``Regex.prefixScan``), or lie anywhere in its
  ## line and tell of no start (``Regex.lineRun``).  A position is a candidate
  ## where every byte is in its set.
  ##
  ## ``early``: and where the bytes up to one past ASCII are, whatever
  ## follows.  Of a character that may be wider than a byte, what comes
  ## after its first byte is not known, nor where the next one begins.
  len*: int
  early*: bool
  sets*: array[MaxPrefixLen, set[uint8]]
  scans*: array[MaxPrefixLen, ByteSetScan]

func initByteSetScan*(bs: set[uint8]): ByteSetScan =
  ## ``bs`` laid out for [findAnyByte] and [rfindAnyByte].  An empty set, a
  ## full one and one of more than [MaxScanRuns] runs are read a byte at a
  ## time: a full one answers at its first byte, but an empty one reads the
  ## whole range, so a caller that may hold one tests it first.  Runs are
  ## found a word at a time, since every compile with a set literal lays one
  ## out.
  var words: array[4, uint64]
  template spell() =
    for b in bs:
      words[b shr 6] = words[b shr 6] or (1'u64 shl (b and 63))

  when nimvm:
    spell()
  else:
    # A set's storage is its bit order only on a little-endian target.
    when cpuEndian == littleEndian:
      words = cast[array[4, uint64]](bs)
    else:
      spell()
  var los, widths: array[MaxScanRuns, uint8]
  var n, ns = 0
  var i = 0
  while i < 256:
    # The next member, at or after ``i``.
    let y = words[i shr 6] shr (i and 63)
    if y == 0:
      i = (i or 63) + 1
      continue
    i += countTrailingZeroBits(y)
    let first = i
    # The first non-member after it; zeros shifted in read as members.
    while i < 256:
      let x = (not words[i shr 6]) shr (i and 63)
      if x == 0:
        i = (i or 63) + 1
      else:
        i += countTrailingZeroBits(x)
        break
    if n == MaxScanRuns or (first == 0 and i == 256):
      return
    los[n] = uint8(first)
    widths[n] = uint8(i - 1 - first)
    if first == i - 1:
      inc ns
    inc n
  result.singles = uint8(ns)
  result.runs = uint8(n)
  # One-byte runs first, each byte spread over a block.
  var k = 0
  for pass in 0 .. 1:
    for r in 0 ..< n:
      if (widths[r] == 0) == (pass == 0):
        for j in 0 ..< 16:
          result.lo[k][j] = los[r]
          result.width[k][j] = widths[r]
        inc k

const BlockScan* =
  defined(amd64) and (defined(c) or defined(cpp)) and not defined(tcc) and
  not defined(reniNoBlockScan)
  ## ``-d:reniNoBlockScan`` reads a byte at a time, as other targets do.  CI
  ## runs ``tests/test_byte_scan.nim`` under it, so that path is built on
  ## x86-64 too.

when BlockScan:
  type M128i {.importc: "__m128i", header: "<emmintrin.h>", bycopy.} = object

  {.push header: "<emmintrin.h>", nodecl.}
  func mmLoadu(p: ptr M128i): M128i {.importc: "_mm_loadu_si128".}
  func mmCmpEq(a, b: M128i): M128i {.importc: "_mm_cmpeq_epi8".}
  func mmSub(a, b: M128i): M128i {.importc: "_mm_sub_epi8".}
  func mmMinU(a, b: M128i): M128i {.importc: "_mm_min_epu8".}
  func mmAnd(a, b: M128i): M128i {.importc: "_mm_and_si128".}
  func mmOr(a, b: M128i): M128i {.importc: "_mm_or_si128".}
  func mmMoveMask(a: M128i): int32 {.importc: "_mm_movemask_epi8".}
  func mmSet1(b: int8): M128i {.importc: "_mm_set1_epi8".}
  {.pop.}

  func cMemchr(
    p: pointer, c: cint, n: csize_t
  ): pointer {.importc: "memchr", header: "<string.h>".}

  type Bytes = ptr UncheckedArray[char]

  # Off for the block loops: a run index stays below ``runs``, which
  # [initByteSetScan] keeps within [MaxScanRuns], and the positions within
  # ``[start, size)``.  On, the loops test the index and every sum per run.
  {.push checks: off.}

  template lanes(a: array[16, uint8]): M128i =
    mmLoadu(cast[ptr M128i](unsafeAddr a))

  template inSet(v: M128i, sc: ByteSetScan, ns, n: int): M128i =
    ## Each byte of ``v`` that is in ``sc``, ``n`` runs of which ``ns`` one
    ## byte wide.  A byte ``v`` lies in run ``[lo, lo + w]`` exactly when
    ## ``v - lo``, wrapping, is at most ``w``: unsigned, so the minimum
    ## against ``w`` gives ``v - lo`` back.  Run 0 starts the union, so the
    ## block needs no zero to start from.
    var acc =
      if ns > 0:
        mmCmpEq(v, lanes(sc.lo[0]))
      else:
        let t = mmSub(v, lanes(sc.lo[0]))
        mmCmpEq(mmMinU(t, lanes(sc.width[0])), t)
    for k in 1 ..< ns:
      acc = mmOr(acc, mmCmpEq(v, lanes(sc.lo[k])))
    for k in max(ns, 1) ..< n:
      let t = mmSub(v, lanes(sc.lo[k]))
      acc = mmOr(acc, mmCmpEq(mmMinU(t, lanes(sc.width[k])), t))
    acc

  template blockMasks(data: Bytes, sc: ByteSetScan) {.dirty.} =
    ## Defines ``maskAt(q)``: bit ``i`` set where ``data[q + i]`` is in the
    ## set, for ``i`` in 0..15.
    let ns = int(sc.singles)
    let n = int(sc.runs)
    template maskAt(q: int): uint32 =
      let v = mmLoadu(cast[ptr M128i](addr data[q]))
      cast[uint32](mmMoveMask(inSet(v, sc, ns, n)))

  proc findBlocks(data: Bytes, start, size: int, sc: ByteSetScan): int {.noinline.} =
    ## [findAnyByte] over ``[start, size)``, at least sixteen bytes long.
    blockMasks(data, sc)
    var i = start
    while i + 32 <= size:
      let m = maskAt(i) or (maskAt(i + 16) shl 16)
      if m != 0:
        return i + countTrailingZeroBits(m)
      i += 32
    if i + 16 <= size:
      let m = maskAt(i)
      if m != 0:
        return i + countTrailingZeroBits(m)
      i += 16
    if i < size:
      # The last sixteen bytes, of which those below ``i`` are read already.
      let q = size - 16
      let m = maskAt(q) and not ((1'u32 shl (i - q)) - 1)
      if m != 0:
        return q + countTrailingZeroBits(m)
    -1

  proc rfindBlocks(data: Bytes, start, size: int, sc: ByteSetScan): int {.noinline.} =
    ## [rfindAnyByte] over ``[start, size)``, at least sixteen bytes long.
    blockMasks(data, sc)
    var e = size # Bytes at and past ``e`` are read.
    while e - 32 >= start:
      let m = maskAt(e - 32) or (maskAt(e - 16) shl 16)
      if m != 0:
        return e - 32 + 31 - countLeadingZeroBits(m)
      e -= 32
    if e - 16 >= start:
      let m = maskAt(e - 16)
      if m != 0:
        return e - 16 + 31 - countLeadingZeroBits(m)
      e -= 16
    if e > start:
      # The first sixteen bytes, of which those at and past ``e`` are read.
      let m = maskAt(start) and ((1'u32 shl (e - start)) - 1)
      if m != 0:
        return start + 31 - countLeadingZeroBits(m)
    -1

  proc findPrefixBlocks(
      data: Bytes,
      start, starts: int,
      ps: PrefixScan,
      plen: static int,
      early: static bool,
  ): int {.noinline.} =
    ## [findPrefix] over the starts ``[start, starts)``, at least sixteen of
    ## them, each with ``plen`` bytes to read.
    template runsOf(k: int): untyped =
      (int(ps.scans[k].singles), int(ps.scans[k].runs))

    let (ns0, n0) = runsOf(0)
    let (ns1, n1) = runsOf(1)
    let (ns2, n2) = runsOf(MaxPrefixLen - 1)
    template firstAt(q: int): uint32 =
      ## The starts whose first byte is in its set.
      let v0 = mmLoadu(cast[ptr M128i](addr data[q]))
      cast[uint32](mmMoveMask(inSet(v0, ps.scans[0], ns0, n0)))

    template restAt(q: int): uint32 =
      ## The starts whose bytes after the first are in theirs.
      let v1 = mmLoadu(cast[ptr M128i](addr data[q + 1]))
      # Only the sign bits are read: a compare's are its answer, and a byte's
      # own say whether it is past ASCII.
      var m = inSet(v1, ps.scans[1], ns1, n1)
      when plen > 2:
        let v2 = mmLoadu(cast[ptr M128i](addr data[q + 2]))
        var m2 = inSet(v2, ps.scans[2], ns2, n2)
        when early:
          m2 = mmOr(m2, v1)
        m = mmAnd(m, m2)
      when early:
        m = mmOr(m, mmLoadu(cast[ptr M128i](addr data[q])))
      cast[uint32](mmMoveMask(m))

    # A pair's bytes, or a lone one, each in a run of its own.
    let byMemchr = ns0 == n0 and n0 <= 2
    var i = start
    # The first sixteen by themselves, where dense candidates are met.
    block:
      let m = firstAt(i) and restAt(i)
      if m != 0:
        return i + countTrailingZeroBits(m)
      i += 16
    var skipped = 0 # Starts read since the last with a first byte in its set.
    while i + 32 <= starts:
      let h = firstAt(i) or (firstAt(i + 16) shl 16)
      if h == 0:
        i += 32
        skipped += 32
        if byMemchr and skipped >= PrefixMemchrAfter:
          # As far again as was skipped, which bounds what is read twice: the
          # second byte is looked for up to the first's hit, and nothing is
          # kept for the next call.
          var last = i + min(skipped, starts - i)
          for k in 0 ..< n0:
            let q = cMemchr(addr data[i], cint(ps.scans[0].lo[k][0]), csize_t(last - i))
            if q != nil:
              last = cast[int](q) - cast[int](data)
          skipped += last - i
          i = last
      else:
        skipped = 0
        # Half by half: a match in the first needs no more.  Which half ``h``
        # names is not tested, being hard to predict.
        var m = h and restAt(i)
        if m != 0:
          return i + countTrailingZeroBits(m)
        m = (h shr 16) and restAt(i + 16)
        if m != 0:
          return i + 16 + countTrailingZeroBits(m)
        i += 32
    if i + 16 <= starts:
      let m = firstAt(i) and restAt(i)
      if m != 0:
        return i + countTrailingZeroBits(m)
      i += 16
    if i < starts:
      # The last sixteen starts, of which those below ``i`` are read already.
      let q = starts - 16
      let m = firstAt(q) and restAt(q) and not ((1'u32 shl (i - q)) - 1)
      if m != 0:
        return q + countTrailingZeroBits(m)
    -1

  proc newlineOrHighBlocks(data: Bytes, start, size: int): int {.noinline.} =
    ## [findNewlineOrHigh] over ``[start, size)``, at least sixteen bytes long.
    ## A byte past ASCII has its sign bit set, and so does a ``\n`` once
    ## ORed with its compare, so one move mask reads both.
    let nl = mmSet1(int8('\n'))
    template maskAt(q: int): uint32 =
      let v = mmLoadu(cast[ptr M128i](addr data[q]))
      cast[uint32](mmMoveMask(mmOr(v, mmCmpEq(v, nl))))

    var i = start
    while i + 32 <= size:
      let m = maskAt(i) or (maskAt(i + 16) shl 16)
      if m != 0:
        return i + countTrailingZeroBits(m)
      i += 32
    if i + 16 <= size:
      let m = maskAt(i)
      if m != 0:
        return i + countTrailingZeroBits(m)
      i += 16
    if i < size:
      let q = size - 16
      let m = maskAt(q) and not ((1'u32 shl (i - q)) - 1)
      if m != 0:
        return q + countTrailingZeroBits(m)
    -1

  {.pop.}

proc findAnyByte*(
    data: ptr UncheckedArray[char], start, size: int, bs: set[uint8], sc: ByteSetScan
): int {.inline.} =
  ## Index of the first byte of ``bs`` in ``data[start ..< size]``, or -1.
  ## ``sc`` is ``bs`` laid out by [initByteSetScan].
  var i = start
  # The first bytes one at a time: a set that holds a common byte answers
  # there most of the time, before the block loop's setup.
  let probe = min(size, start + ScalarProbe)
  while i < probe:
    if uint8(data[i]) in bs:
      return i
    inc i
  when BlockScan:
    if sc.runs > 0 and size - i >= 16:
      return findBlocks(data, i, size, sc)
  while i < size:
    if uint8(data[i]) in bs:
      return i
    inc i
  -1

proc rfindAnyByte*(
    data: ptr UncheckedArray[char], start, size: int, bs: set[uint8], sc: ByteSetScan
): int {.inline.} =
  ## Index of the last byte of ``bs`` in ``data[start ..< size]``, or -1.
  var e = size
  let probe = max(start, size - ScalarProbe)
  while e > probe:
    dec e
    if uint8(data[e]) in bs:
      return e
  when BlockScan:
    if sc.runs > 0 and e - start >= 16:
      return rfindBlocks(data, start, e, sc)
  while e > start:
    dec e
    if uint8(data[e]) in bs:
      return e
  -1

proc findPrefix*(
    data: ptr UncheckedArray[char], start, size: int, ps: PrefixScan
): int =
  ## First index in ``[start, size)`` where ``ps`` holds, reading no byte at
  ## or past ``size``, or -1.
  var i = start
  let starts = size - ps.len + 1
  # Past ``starts`` a whole prefix does not fit: only ``early`` holds there.
  let last = if ps.early: size else: starts
  template testAt(i: int) =
    ## Returns ``i`` where ``ps`` holds there.
    block:
      var k = 0
      while i + k < size and uint8(data[i + k]) in ps.sets[k]:
        inc k
        if k == ps.len or ps.early and uint8(data[i + k - 1]) >= 0x80'u8:
          return i

  let probe = min(last, start + PrefixProbe)
  while i < probe:
    testAt(i)
    inc i
  when BlockScan:
    if starts - i >= 16:
      let hit =
        if ps.len == 2:
          if ps.early:
            findPrefixBlocks(data, i, starts, ps, 2, true)
          else:
            findPrefixBlocks(data, i, starts, ps, 2, false)
        elif ps.early:
          findPrefixBlocks(data, i, starts, ps, 3, true)
        else:
          findPrefixBlocks(data, i, starts, ps, 3, false)
      if hit >= 0:
        return hit
      i = starts
  while i < last:
    testAt(i)
    inc i
  -1

proc findNewlineOrHigh*(
    data: ptr UncheckedArray[char], start, size: int
): int {.inline.} =
  ## Index of the first ``\n`` or byte past ASCII in ``data[start ..< size]``,
  ## or -1.  Line mode finds a candidate line's end with it, and learns on
  ## the way whether the line holds a byte to check for malformed UTF-8.
  ## Without the block scan, a byte at a time.
  when BlockScan:
    if size - start >= 16:
      return newlineOrHighBlocks(data, start, size)
  var i = start
  while i < size:
    let b = uint8(data[i])
    if b == uint8('\n') or b >= 0x80'u8:
      return i
    inc i
  -1
