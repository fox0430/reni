## The block scan for a byte set (``reni/byte_scan``), and the searches that
## read it: the scan's lead set, a required byte set and line mode's search
## for lines.  Each is checked against a byte at a time: the scan helpers
## against a loop, and a search against the same ``Regex`` with its layouts
## cleared, which the search then reads a byte at a time.

import std/[importutils, random, strutils, unittest]

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

suite "findNewlineOrHigh":
  test "a newline or a byte past ASCII at each place in and around a block":
    for n in [1, 15, 16, 17, 31, 32, 33, 47, 48, 64, 70]:
      for at in 0 ..< n:
        for hit in ['\n', '\x80', '\xFF', '\xC3']:
          var s = newString(n)
          for i in 0 ..< n:
            s[i] = char(0x0B + i mod 0x70) # ASCII, never a newline
          s[at] = hit
          for start in 0 .. n:
            check findNewlineOrHigh(bytesOf(s), start, n) ==
              (if start <= at: at else: -1)

  test "the first of several":
    let s = "abcdefghijklmnopqrstuvwxyz\xE9abc\ndef\x80"
    check findNewlineOrHigh(bytesOf(s), 0, s.len) == 26
    check findNewlineOrHigh(bytesOf(s), 27, s.len) == 30
    check findNewlineOrHigh(bytesOf(s), 31, s.len) == 34
    check findNewlineOrHigh(bytesOf(s), 31, 34) == -1

proc naivePrefix(s: string, start, size: int, ps: PrefixScan): int =
  for i in start ..< size:
    for k in 0 ..< ps.len:
      if i + k >= size or uint8(s[i + k]) notin ps.sets[k]:
        break
      if k == ps.len - 1 or ps.early and s[i + k] >= '\x80':
        return i
  -1

suite "findPrefix":
  test "agrees with a byte at a time":
    var r = initRand(20261124)
    var hits = 0
    for round in 0 ..< 400:
      let ps = PrefixScan(len: 2 + r.rand(1), early: r.rand(1) == 0)
      for k in 0 ..< ps.len:
        while ps.scans[k].runs == 0:
          ps.sets[k] = randomSet(r, 1 + r.rand(MaxScanRuns - 1))
          ps.scans[k] = initByteSetScan(ps.sets[k])
      let n = 1 + r.rand(89)
      var s = newString(n)
      for i in 0 ..< n:
        s[i] = char(r.rand(255))
      for _ in 0 .. r.rand(1):
        let at = r.rand(n - 1)
        for k in 0 ..< min(ps.len, n - at):
          for b in ps.sets[k]:
            s[at + k] = char(b)
            if r.rand(3) == 0:
              break
      for start in 0 .. n:
        for size in [n, max(start, n - 1), min(n, start + 17), min(n, start + 18)]:
          let hit = naivePrefix(s, start, size, ps)
          check findPrefix(bytesOf(s), start, size, ps) == hit
          if hit >= 0:
            inc hits
    check hits > 1000

  test "agrees over long stretches without a first byte":
    # Long enough that the scan leaves its blocks for `memchr`, for a first
    # set of one or two lone bytes, and for others stays.
    var r = initRand(20261125)
    var hits = 0
    for round in 0 ..< 600:
      let ps = PrefixScan(len: 2 + r.rand(1), early: r.rand(1) == 0)
      for k in 0 ..< ps.len:
        ps.sets[k] = {uint8('b'), uint8('y')}
        if k == 0 and round mod 3 == 0:
          ps.sets[k] = {uint8('b')}
        elif r.rand(2) == 0:
          ps.sets[k] = ps.sets[k] + {uint8('d') .. uint8('f'), 0xE9'u8}
        ps.scans[k] = initByteSetScan(ps.sets[k])
      let n = 1 + r.rand(4000)
      var s = repeat('.', n)
      for _ in 0 .. r.rand(6):
        # A whole prefix, or bytes of one.
        let at = r.rand(n - 1)
        for k in 0 ..< min(1 + r.rand(2), n - at):
          s[at + k] = "bydf\xE9"[r.rand(4)]
      for _ in 0 ..< 8:
        let start = r.rand(n)
        let size = start + r.rand(n - start)
        let hit = naivePrefix(s, start, size, ps)
        check findPrefix(bytesOf(s), start, size, ps) == hit
        if hit >= 0:
          inc hits
    check hits > 500

proc spans(s: string, r: Regex): seq[Span] =
  for m in s.findAll(r):
    result.add m.matchSpan

proc byteAtATime(r: Regex): Regex =
  result = r
  result.leadScan = ByteSetScan()
  result.requiredScan = ByteSetScan()
  result.lineScan = ByteSetScan()
  result.prefixScan = nil
  result.prefixLines = false
  result.lineRun = nil

suite "searches over the block scan":
  const patterns = [
    "foo|bar|baz|qux|quux|corge|grault|garply", "(?i)picker", "[A-Z]{2,}_[A-Z]",
    "[qz]x|é", "é|ü|q", "[b-d]+e", "(?i)x", "(?i)kx", "[éa]b", "(?:q|z)\\b",
    "[^a-y\\s]", "(?i)ab", "\\w+[a-z]", "[a-zA-Z]{8}", "(?i)foo|bar", "(?i)stq|zk",
    "(?i)sq|[ß]q", "b(?:q|z)x|é", "(?=[zq])[b-z]x", "(?i)ssq|zzz", "(?i)ffiq",
    "(?i)hax", "(?i)stop|halt", "(?i)while", "[A-Z][A-Z_]+b", "\\Rqz|zqb",
    "[bq](?=o)o|(?<=f)oq", "(?:qu){2}x|zzb", "(?i)\\s*picker", "(?i)\\w+stop",
    "\\w+(?:foo|bar)", "(?i)\\w*(?:while|hax)", "(?i)a\\w*sst?op", "[qz].*(?:foo|bar)",
    "(?i)\\s*stop", "(?i)\\w+hax",
  ]
  const pieces = [
    "a", "b", "q", "z", "x", "K", "_", "AB", " ", "\n", "é", "ü", "\xE9", "\xF0",
    "\x80", "foo", "bar", "picker", "PiCkEr", "quux", "\xE2\x84\xAA", "e", "de", "ẞ",
    "ﬃ", "ẖ", "ﬆ", "ﬀ", "ſ", "h", "H", "s", "t", "stop", "While", "ha", "op",
    "\xC1\xB3", "\xE0\x81\xB3",
  ]

  test "a lead set is laid out where it is rare":
    check re("foo|bar|baz|qux|quux|corge|grault|garply").leadScan.runs > 0
    check re("[A-Z]{3,}_[A-Z]+").leadScan.runs > 0
    check re(r"\w+_\w+\(").leadScan.runs == 0
    check re("[a-z]+_").leadScan.runs == 0
    check re(r"\d{6,}").leadScan.runs > 0

  test "a prefix is laid out where it is rarer than the first byte":
    when BlockScan:
      check re("foo|bar|baz|qux|quux|corge|grault|garply").prefixScan.len == 3
      check re("(?i)foo|bar").prefixScan.early
      check re("[A-Z]{3,}_[A-Z]+").prefixScan == nil
      check re(r"\w+_\w+\(").prefixScan == nil
      check re("foo").prefixScan == nil
      # A branch of one character leaves nothing to test after the first.
      check re("foo|b|qux").prefixScan == nil
      check re("foo|bar|qux", {rfLineMode}).prefixLines
      # A rare pair keeps its cursors, and a rare line set picks its lines.
      let todo = re("TODO|FIXME", {rfLineMode})
      check todo.leadScan.runs == 0 and not todo.prefixLines
      check re("日本|中国").prefixScan == nil
      # What is weighed is what the first byte alone looks for, less what a
      # look-ahead takes from it.
      check re("(?=[~@#])[!-/:-@~][0-9]").prefixScan == nil
      # A set that holds an earlier one is not the runs of that one.
      check re("[0-9][0-9a-f]{3}").prefixScan != nil
    else:
      check re("foo|bar|qux").prefixScan == nil

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

  test "a line is picked by the prefix and the line set together":
    let r = re("(?:the|and) .*[qz]", {rfLineMode})
    when BlockScan:
      check r.prefixLines
    let slow = byteAtATime(r)
    var rnd = initRand(11)
    const words = ["the ", "and ", "\n", "q", "z", "cat ", "then ", "\xE9", "\r\n"]
    for _ in 0 ..< 3000:
      var s = ""
      for _ in 0 ..< rnd.rand(40):
        s.add words[rnd.rand(words.high)]
      check spans(s, r) == spans(s, slow)
    check spans("z the cat\nand\nthe z\nthe q", r) ==
      @[Span(a: 14, b: 19), Span(a: 20, b: 25)]

  test "a run anywhere in the match picks lines":
    proc runOf(pattern: string, flags: RegexFlags = {}): seq[set[uint8]] =
      let run = re(pattern, flags + {rfLineMode}).lineRun
      if run != nil:
        for k in 0 ..< run.len:
          result.add run.sets[k]

    proc sets(spelled: varargs[string]): seq[set[uint8]] =
      for s in spelled:
        var bs: set[uint8]
        for c in s:
          bs.incl uint8(c)
        result.add bs

    when BlockScan:
      check runOf("(?i)^\\s*todo") == sets("Oo", "Dd", "Oo")
      # ``t`` has folds past ASCII, so the run would end with it.
      check runOf("(?i)\\s+(?:todo|fixme)") == sets("OoXx", "DdMm", "OoEe")
      check runOf("\\w+(foo|bar)") == sets("fb", "ao", "or")
      check runOf("\\s*(?:(?:foo)|(?<n>b[a]r))") == sets("fb", "ao", "or")
      check runOf("a?[qx]\\b(?=.)[jz][kv]\\w*") == sets("qx", "jz", "kv")
      # One where every run ends at its first byte without ``early``.
      check runOf("(?i)\\s+state").len == 3
      # A repeat of a fixed number is gone through, another begun and ended.
      check runOf("\\w+(?:[jq]){2}[kz]") == sets("jq", "jq", "kz")
      check runOf("\\w+[qz](?:[jx][kv])+[qz]") == sets("qz", "jx", "kv")
      check runOf("\\w+[qz](?:[jx][kv])*[qz]") == sets()
      check runOf("\\w+[qz]\\w[jx]+[kv]") == sets()
      check runOf("\\w+[qz](?:[jx][kv]){0}[jx]") == sets("qz", "jx")
      check runOf("\\w+[qz](?:[jx][kv]){2}") == sets("qz", "jx", "kv")
      # A look-ahead is read from where the match stands, and not consumed.
      check runOf("(?=[qz][jx][kv])\\w+") == sets("qz", "jx", "kv")
      check runOf("\\w+(?=[qz][jx])[kv]") == sets("qz", "jx")
      check runOf("(?![qz][jx][kv])\\w+") == sets()
      check runOf("\\w+(?<=[qz][jx])\\w") == sets()
      # No line holds a newline.
      check runOf("[a-y]*[\\nqz][\\njx]") == sets("qz", "jx")
      # A rare line set, a string and a prefix as rare need none.
      check runOf("\\w+(?:TODO|FIXME)") == sets()
      check runOf("\\w+foo") == sets()
      check runOf("(?i)todo") == sets()
      check runOf("(?i)picker") == sets()
      check runOf("foo|bar|qux") == sets()
      check runOf("\\w+\\d") == sets()
      check runOf("\\w+(foo|\\1)") == sets()
      check runOf("\\w+(foo|)") == sets()
      check runOf("\\w+[qz](?~ab)[jx]") == sets()
      # ``nse`` may lie in fewer lines than the prefix.
      check runOf("(?i)license").len == 3
    check re("(?i)^\\s*todo").lineRun == nil

  test "a run goes through a character wider than its byte in the set":
    # U+212A is a fold of ``k``, U+017F of ``s``, U+FB06 of ``st``.
    for (pattern, subject) in {
      "(?i)\\w*(?:ms|ks)": "a\u212As",
      "(?i)\\w*(?:ms|ks)": "aM\u017F",
      "(?i)\\w*(?:ms|sts)": "1\uFB06s",
      "(?i)\\w*(?:ms|sts)": "1\u017Fts",
    }:
      let r = re(pattern, {rfLineMode})
      when BlockScan:
        check r.lineRun.early
      let s = "ms\xE2\n" & subject & "\n" & subject
      check spans(s, r).len == 3
      check spans(s, r) == spans(s, byteAtATime(r))

  test "a line is picked by the run and the line set in either order":
    for pattern in ["(?i)[jq]+.*err", "(?i)err.*[jq]", "[jq].*(?:foo|bar)"]:
      let r = re(pattern, {rfLineMode})
      let slow = byteAtATime(r)
      var rnd = initRand(13)
      const words = [
        "err", "ERR", "foo", "bar", "q", "J", "j", "e", "r", "\n", "\n", " ", "\xE9",
        "\r\n", "é", "xxxxxxxxxxxxxxxxxxxxxxxx",
      ]
      for _ in 0 ..< 2000:
        var s = ""
        for _ in 0 ..< rnd.rand(30):
          s.add words[rnd.rand(words.high)]
        check spans(s, r) == spans(s, slow)
    let r = re("(?i)[jqv]+.*err", {rfLineMode})
    when BlockScan:
      check r.lineRun != nil
    check spans("err\nq\nq err\nerr q\nj\nQ ERR q\nerr", r) ==
      @[Span(a: 6, b: 11), Span(a: 20, b: 25)]

  test "the answers under a run are those of a search of every line":
    const
      atoms = [
        "a", "b", "s", "k", "st", "ss", "to", "err", "to", "err", "bk", "oS", "\\s",
        "\\w", "\\S", "\\d", "[ab]", "[^a]", "[ßs]", "ß", "[s]", "[a-z]", "[qz]",
        "[a-z&&[^b]]", "(?iI:[as])", "é", "日", "ﬆ", "[kK]", ".", "\\R", "\\X",
        "\\h", "(?:a|é)", "(?:ss|ß|b)", "(a|b)", "(?:st|ke|é)", "(?:to|err)",
        "(?i:s)", "(?-i:s)", "(?i)", "(?=st)", "(?=.*q)", "(?!b)", "(?<=a)", "\\b",
        "\\B", "\\K", "^", "$", "(?>a+)", "(?:a(?i)s|t)", "\\1", "\\xE9", "K",
        "(?<n>ab)",
      ]
      quants = [
        "", "", "", "", "", "", "", "", "?", "*", "+", "{2}", "{1}", "+?", "*+", "{0}",
        "{1,2}",
      ]
      pieces = [
        "a", "b", "s", "S", "k", "q", "e", "r", "t", "T", "o", "err", "ERR", "to", " ",
        "\t", "ß", "ẞ", "é", "日", "ﬆ", "ſ", "K", "1", "\r", "\n", "\n", "\r\n",
        "\xE9", "\x80", "\xC3", "ss", "st", "\xE1", "aaaaaaaaaaaaaaaaaaaa", "ŉ", "ẖ",
      ]
    var rng = initRand(20261125)
    var tested, hits = 0
    for _ in 0 ..< 10000:
      var p = ""
      for _ in 0 .. 1 + rng.rand(4):
        let atom = rng.sample(atoms)
        p.add atom
        if atom notin ["(?i)", "^", "$", "\\K", "\\b", "\\B"]:
          p.add rng.sample(quants)
      if rng.rand(5) == 0:
        p = p & "|" & rng.sample(atoms) & rng.sample(atoms)
      var flags = {rfLineMode}
      if rng.rand(1) == 0:
        flags.incl rfIgnoreCase
      if rng.rand(2) == 0:
        flags.incl rfCrlf
      if rng.rand(5) == 0:
        flags.incl rfFindLongest
      var r: Regex
      try:
        r = re(p, flags)
      except RegexError:
        continue
      if r.lineRun == nil:
        continue
      inc tested
      var plain = r
      plain.lineRun = nil
      for _ in 0 ..< 20:
        var s = ""
        for _ in 0 .. rng.rand(60):
          s.add rng.sample(pieces)
        checkpoint p & " " & $flags & " " & s.escape
        let got = spans(s, r)
        hits += got.len
        check got == spans(s, plain)
        let at = rng.rand(s.len)
        check search(s, r, start = at).boundaries ==
          search(s, plain, start = at).boundaries
    when BlockScan:
      check tested > 500
      check hits > 1000

  test "a hit inside a character is no start":
    # 0xE9 declares three bytes, so the character walk steps from it over the
    # two ``q`` after it, to the third, as a byte at a time does.
    let r = re("q|z|j")
    check r.leadScan.runs > 0
    let s = "aaaaaaaaaaaaaaaaaaaaaaaaa\xE9qqq"
    check spans(s, r) == @[Span(a: 28, b: 29)]
    check spans(s, byteAtATime(r)) == @[Span(a: 28, b: 29)]

  test "a prefix inside a character is no start":
    # 0xE9 declares three bytes, so the walk steps from it over "fo" to "o".
    let r = re("foo|bar|qux")
    when BlockScan:
      check r.prefixScan != nil
    for s in [
      "aaaaaaaaaaaaaaaaaaaaaaaaa\xE9foo", "aaaaaaaaaaaaaaaaaaaaaaaaa\xE9foo bar foo"
    ]:
      check spans(s, r) == spans(s, byteAtATime(r))
    check spans("aaaaaaaaaaaaaaaaaaaaaaaaa\xE9foo", r).len == 0

  test "a prefix begins with no byte the first byte alone rules out":
    for pattern in ["(?i)while", "(?i)hello", "(?i)stop|halt", "(?i)foo|bar"]:
      let r = re(pattern)
      when BlockScan:
        check r.prefixScan != nil
        check r.prefixScan.sets[0] <= r.firstCharInfo.bytes
        check r.leadScan == initByteSetScan(r.prefixScan.sets[0])
