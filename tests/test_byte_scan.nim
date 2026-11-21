## The block scan for a byte set (``reni/byte_scan``), and the searches that
## read it: the scan's lead set, a required byte set and line mode's search
## for lines.  Each is checked against a byte at a time: the scan helpers
## against a loop, and a search against the same ``Regex`` with its layouts
## cleared, which the search then reads a byte at a time.

import std/[importutils, random, unittest]

import reni
import reni/byte_scan
import reni/types {.all.}

privateAccess(Regex)

proc naiveFind(s: string, start, size: int, bs: set[uint8]): int =
  for i in start ..< size:
    if uint8(s[i]) in bs:
      return i
  -1

proc naiveRfind(s: string, start, size: int, bs: set[uint8]): int =
  for i in countdown(size - 1, start):
    if uint8(s[i]) in bs:
      return i
  -1

proc bytesOf(s: string): ptr UncheckedArray[char] =
  cast[ptr UncheckedArray[char]](unsafeAddr s[0])

proc randomSet(r: var Rand, runs: int): set[uint8] =
  for _ in 0 ..< runs:
    let lo = r.rand(255)
    let hi = min(255, lo + (if r.rand(1) == 0: 0 else: r.rand(20)))
    for b in lo .. hi:
      result.incl uint8(b)

suite "initByteSetScan":
  test "one-byte runs come first":
    let sc = initByteSetScan({uint8('b') .. uint8('d'), uint8('q'), uint8('z')})
    check sc.runs == 3
    check sc.singles == 2
    check sc.lo[0][0] == uint8('q')
    check sc.lo[1][15] == uint8('z')
    check sc.lo[2][7] == uint8('b')
    check sc.width[2][0] == 2

  test "laid out at compile time as at run time":
    const ct =
      initByteSetScan({0'u8 .. 3'u8, uint8('q'), 64'u8 .. 70'u8, 250'u8 .. 255'u8})
    let rt =
      initByteSetScan({0'u8 .. 3'u8, uint8('q'), 64'u8 .. 70'u8, 250'u8 .. 255'u8})
    check ct == rt
    check ct.runs == 4

  test "a set the block scan does not take":
    check initByteSetScan({}).runs == 0
    check initByteSetScan({0'u8 .. 255'u8}).runs == 0
    var nine: set[uint8]
    for i in 0 ..< MaxScanRuns + 1:
      nine.incl uint8(2 * i)
    check initByteSetScan(nine).runs == 0
    nine.excl uint8(2 * MaxScanRuns)
    check initByteSetScan(nine).runs == MaxScanRuns

  test "a run that reaches 0 or 255":
    let sc = initByteSetScan({0'u8 .. 3'u8, 250'u8 .. 255'u8})
    check sc.runs == 2
    let s = "\x04abc\xF9xyz\x05abcdefghijklmnopq\xFAr"
    check findAnyByte(bytesOf(s), 0, s.len, {0'u8 .. 3'u8, 250'u8 .. 255'u8}, sc) ==
      s.len - 2

suite "findAnyByte and rfindAnyByte":
  test "agree with a byte at a time":
    var r = initRand(20261120)
    for round in 0 ..< 400:
      let bs = randomSet(r, 1 + r.rand(MaxScanRuns + 2))
      let sc = initByteSetScan(bs)
      # Mostly bytes outside the set, so a hit lies anywhere in a block.
      let n = r.rand(90)
      var s = newString(n)
      for i in 0 ..< n:
        s[i] =
          if r.rand(15) == 0:
            char(r.rand(255))
          else:
            char(uint8(r.rand(255)) xor 0x55'u8)
      if n == 0:
        continue
      for start in 0 .. n:
        for size in [n, max(start, n - 1), min(n, start + 16), min(n, start + 17)]:
          check findAnyByte(bytesOf(s), start, size, bs, sc) ==
            naiveFind(s, start, size, bs)
          check rfindAnyByte(bytesOf(s), start, size, bs, sc) ==
            naiveRfind(s, start, size, bs)

  test "a hit at each place in and around a block":
    let bs = {uint8('q'), uint8('x') .. uint8('z')}
    let sc = initByteSetScan(bs)
    for n in [16, 17, 31, 32, 33, 47, 48, 64, 70]:
      for at in 0 ..< n:
        var s = newString(n)
        for i in 0 ..< n:
          s[i] = 'a'
        s[at] = (if at mod 2 == 0: 'q' else: 'y')
        for start in 0 .. n:
          check findAnyByte(bytesOf(s), start, n, bs, sc) ==
            (if start <= at: at else: -1)
          check rfindAnyByte(bytesOf(s), start, n, bs, sc) ==
            (if start <= at: at else: -1)

proc spans(s: string, r: Regex): seq[Span] =
  for m in s.findAll(r):
    result.add m.matchSpan

proc byteAtATime(r: Regex): Regex =
  result = r
  result.leadScan = ByteSetScan()
  result.requiredScan = ByteSetScan()
  result.lineScan = ByteSetScan()

suite "searches over the block scan":
  const patterns = [
    "foo|bar|baz|qux|quux|corge|grault|garply", "(?i)picker", "[A-Z]{2,}_[A-Z]",
    "[qz]x|é", "é|ü|q", "[b-d]+e", "(?i)x", "(?i)kx", "[éa]b", "(?:q|z)\\b",
    "[^a-y\\s]", "(?i)ab", "\\w+[a-z]", "[a-zA-Z]{8}",
  ]
  const pieces = [
    "a", "b", "q", "z", "x", "K", "_", "AB", " ", "\n", "é", "ü", "\xE9", "\xF0",
    "\x80", "foo", "bar", "picker", "PiCkEr", "quux", "\xE2\x84\xAA", "e", "de",
  ]

  test "a lead set is laid out where it is rare":
    check re("foo|bar|baz|qux|quux|corge|grault|garply").leadScan.runs > 0
    check re("[A-Z]{3,}_[A-Z]+").leadScan.runs > 0
    check re(r"\w+_\w+\(").leadScan.runs == 0
    check re("[a-z]+_").leadScan.runs == 0
    check re(r"\d{6,}").leadScan.runs > 0

  test "a required or line set is laid out however common":
    # (?i)ab requires {B, b}.  [a-z] and [a-zA-Z] are heavier than any lead
    # set the scan lays out, and still laid out here.
    check re("(?i)ab").requiredScan.runs > 0
    check re("(?i)ab", {rfLineMode}).lineScan.runs > 0
    check re(r"\w+[a-z]").requiredLit.kind == rlSet
    check re(r"\w+[a-z]").requiredScan.runs > 0
    check re("[a-zA-Z]{8}", {rfLineMode}).lineLit.kind == rlSet
    check re("[a-zA-Z]{8}", {rfLineMode}).lineScan.runs > 0

  test "agree with a byte at a time":
    var r = initRand(7)
    for pattern in patterns:
      for flags in [RegexFlags({}), {rfLineMode}]:
        let fast = re(pattern, flags)
        let slow = byteAtATime(fast)
        for _ in 0 ..< 300:
          var s = ""
          for _ in 0 ..< r.rand(40):
            s.add pieces[r.rand(pieces.high)]
          check spans(s, fast) == spans(s, slow)

  test "a hit inside a character is no start":
    # 0xE9 declares three bytes, so the character walk steps from it over the
    # two ``q`` after it, to the third, as a byte at a time does.
    let r = re("q|z|j")
    check r.leadScan.runs > 0
    let s = "aaaaaaaaaaaaaaaaaaaaaaaaa\xE9qqq"
    check spans(s, r) == @[Span(a: 28, b: 29)]
    check spans(s, byteAtATime(r)) == @[Span(a: 28, b: 29)]
