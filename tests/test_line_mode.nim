## ``rfLineMode``: each line of the subject, without its ``\n``, is searched
## as a subject of its own, and the answers come back in the subject's
## offsets.  Every case below states what the line searched alone answers;
## the rule is notes/LINE_MODE.md §1.

import std/[importutils, random, sequtils, strutils, unittest]

import reni
import reni/engine {.all.}
import reni/line_mode {.all.}

proc lm(pattern: string): Regex =
  re(pattern, {rfLineMode})

proc spanOf(m: Match): Span =
  if m.found: m.matchSpan else: UnsetSpan

suite "rfLineMode: a line is a subject of its own":
  test "a stray lead byte before a newline does not hide the next line":
    # Over the whole buffer the lead byte 0xE9 declares three bytes and the
    # character walk steps over the ``\n`` and the ``f``.  Its line ends
    # first, so it is a truncated sequence there, and ``foo`` starts a line.
    let s = "caf\xE9\nfoo"
    check spanOf(search(s, lm("[a-z]oo"))) == 5 .. 8
    check spanOf(search(s, lm("f.o"))) == 5 .. 8
    check spanOf(search(s, lm("foo"))) == 5 .. 8
    check not search(s, lm("caf.")).found
    check spanOf(search("x\xE9\nABC_DEF", lm("[A-Z]{3,}_[A-Z]+"))) == 3 .. 10

  test "no match holds a newline":
    check not search("foo\nbar", lm("o\\sb")).found
    check not search("foo\nbar", lm("(?m)o.b")).found
    check not search("foo\nbar", lm("o\\Ob")).found
    check spanOf(search("ab\ncd", lm("b[^x]*"))) == 1 .. 2
    check spanOf(search("a\nb", lm("[^a]"))) == 2 .. 3
    check spanOf(search("a\n\vb", lm("\\R"))) == 2 .. 3

  test "the string anchors hold at a line's edges":
    let s = "foo\nbar\nfoo bar\n"
    check spanOf(search(s, lm("\\Abar"))) == 4 .. 7
    check spanOf(search(s, lm("bar\\z"))) == 4 .. 7
    check spanOf(search(s, lm("bar\\Z"))) == 4 .. 7
    check spanOf(search("foo\nbar x\nfoo bar", lm("bar\\z"))) == 14 .. 17
    check spanOf(search("ab\nb", lm("\\Ab"))) == 3 .. 4

  test "a look-around stops at a line's edges":
    check spanOf(search("foo\nbar", lm("foo(?!\\s)"))) == 0 .. 3
    check not search("foo\nbar", lm("foo(?=\\s)")).found
    check not search("a\nb", lm("(?<=a)b")).found
    check spanOf(search("x\nab", lm("(?<=a)b"))) == 3 .. 4
    check spanOf(search("a\nb", lm("(?<!\\s)b"))) == 2 .. 3

  test "a CR LF's CR ends its line":
    check spanOf(search("\r\nx", lm("\\X"))) == 0 .. 1
    check spanOf(search("a\r\nx", lm("\\r\\y"))) == 1 .. 2

  test "\\G holds at start, then at the start of each later line":
    check spanOf(search("ab\nbc", lm("\\Gb"), start = 1)) == 1 .. 2
    check spanOf(search("ax\nbc", lm("\\Gb"), start = 1)) == 3 .. 4

  test "an anchor option holds in the line that has the place it denies":
    # ``moNotBeginString`` says the buffer does not begin a string: the line
    # at offset 0 loses its ``\A``, searched in either direction, and every
    # later line keeps it.
    let notString = {moNotBeginString}
    check spanOf(search("ab\nb", lm("\\Ab"), options = notString)) == 3 .. 4
    check spanOf(search("x\nab", lm("\\Aa"), start = 2, options = notString)) == 2 .. 3
    check not searchBackward("b\nab", lm("\\Ab"), options = notString).found
    check spanOf(searchBackward("b\nab", lm("\\Aa"), options = notString)) == 2 .. 3
    check not matchAt("b\nb", lm("\\Ab"), options = notString).found
    check spanOf(matchAt("ab\nb", lm("\\Ab"), pos = 3, options = notString)) == 3 .. 4
    # ``moNotBeginPosition`` says the search did not begin at ``start``: the
    # line holding ``start`` loses its ``\G``.
    check spanOf(search("ab\nb", lm("\\Gb"), start = 1, options = {moNotBeginPosition})) ==
      3 .. 4

  test "a final newline ends the last line rather than beginning one":
    check not search("a\n", lm("^$")).found
    check spanOf(search("a\n\n", lm("^$"))) == 2 .. 2
    check not search("", lm("")).found
    check not search("", lm("^")).found
    check not search("a\n", lm(""), start = 2).found
    check spanOf(search("a", lm("$"), start = 1)) == 1 .. 1

  test "groups move to the subject's offsets, an unset one stays unset":
    let m = search("x\nb", lm("(a)|(b)"))
    check m.found
    check m.boundaries == @[span(2, 3), UnsetSpan, span(2, 3)]
    check m.startChar == 2
    check not m.captured(1)

  test "(?L) takes the longest match of the first line that has one":
    check spanOf(search("b\naab\naaab", lm("(?L)a+|a+b"))) == 2 .. 5

  test "matchAt reads the line holding the position":
    check spanOf(matchAt("a\nb", lm("$"), pos = 1)) == 1 .. 1
    check spanOf(matchAt("a\nb", lm("^b"), pos = 2)) == 2 .. 3
    check not matchAt("a\nb", lm("\\s"), pos = 1).found
    check not matchAt("a\n", lm(""), pos = 2).found
    check not matchAt("ab\nb", lm("(?<=b)b"), pos = 3).found

  test "searchBackward walks the lines back from start":
    check spanOf(searchBackward("ab\nab\nx", lm("a\\w"))) == 3 .. 5
    check spanOf(searchBackward("ab\nab\nx", lm("a\\w"), start = 2)) == 0 .. 2
    check spanOf(searchBackward("ab\n", lm("b$"))) == 1 .. 2
    check not searchBackward("", lm("")).found

  test "a scan steps from line to line":
    proc spans(s: string, r: Regex): seq[Span] =
      for m in findAll(s, r):
        result.add m.matchSpan

    check spans("ab\n\ncd", lm("x*")) == (0 .. 6).toSeq.mapIt(span(it, it))
    # The stray lead byte is matched by nothing and stays in its line, so the
    # empty match after it is the line's end, not a position inside the next
    # line.
    check spans("\xE9\nx", lm("")) == (0 .. 3).toSeq.mapIt(span(it, it))
    check spans("a b\nc d\n", lm("\\w\\s*\\w")) == @[span(0, 3), span(4, 7)]
    check replace("a b\nc d", lm("\\s"), "_") == "a_b\nc_d"
    check split("a b\nc", lm("\\s+")) == @["a", "b\nc"]

  test "a scan keeps its line's memos from match to match":
    # A bounded repeat walks the run it starts in to the run's end, and the
    # region memo spares the walk on the run's later matches.  The memo is
    # keyed on the address of the view, which is the subject's only for the
    # first line: dropped on every other line, a scan of one long line went
    # quadratic, as did one reading to the line's end on every match.
    privateAccess(MatchContext)
    let rx = lm("(?:[a-z][0-9]){1,3}")
    let s = "z\n" & repeat("a1", 30)
    let ctx = newMatchContext()
    var sc = initMatchScanner(s)
    var m: Match
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 2 .. 8
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 8 .. 14
    # The second search walked on from the stretch the first one began at
    # the line's start, in the view's offsets; a new walk begins at 6.
    check ctx.seqRegionFrom == 0
    check ctx.seqRegionEnd == 60
    check ctx.lineMemoStart == 2
    check ctx.lineMemoEnd == s.len

  test "the step budget covers the whole call, not each line":
    # Each line alone stays under the limit; 2,000 of them do not, as the
    # same buffer searched without the flag does not.
    let line = repeat('a', 12)
    let pat = "a+a*a*(?<!a)"
    discard search(line, re(pat), stepLimit = 20_000)
    expect RegexLimitError:
      discard search(repeat(line & "\n", 2000), lm(pat), stepLimit = 20_000)

suite "rfLineMode: a byte that is not UTF-8 is matched by nothing":
  # Well-formed is RFC 3629's.  Each stretch between malformed bytes is
  # searched as a view of its own, so the matcher never reads one, and no
  # match holds one, as in rg (notes/LINE_MODE.md).
  proc spans(s: string, r: Regex): seq[Span] =
    for m in findAll(s, r):
      result.add m.matchSpan

  test "a stray lead byte does not take the bytes after it":
    # Read the Oniguruma way, 0xE9 declares three bytes and swallows " a".
    check spanOf(search("caf\xE9 alpha", lm("(?i)alpha"))) == 5 .. 10
    check spanOf(search("\xE9xx", lm("(?i)x"))) == 1 .. 2
    check spanOf(search("\xC3 ", lm("\\s"))) == 1 .. 2
    check spanOf(search("caf\xE9 alpha", lm("\\w+$"))) == 5 .. 10
    check not search("bad \xC3 byte", lm("\\b\\w{5}\\b")).found

  test "no character, class or escape matches it":
    check spanOf(search("\xE9a", lm("."))) == 1 .. 2
    check spanOf(search("\xE9a", lm("(?m)."))) == 1 .. 2
    check spanOf(search("\xE9 ", lm("[^a]"))) == 1 .. 2
    check spanOf(search("\xE9 ", lm("\\W"))) == 1 .. 2
    check spanOf(search("\xE9a", lm("\\S"))) == 1 .. 2
    check spanOf(search("\xE9a", lm("\\X"))) == 1 .. 2
    check spanOf(search("\xE9a", lm("\\O"))) == 1 .. 2
    check not search("caf\xE9", lm("caf.")).found

  test "the forms RFC 3629 refuses are malformed, well-formed ones are not":
    check not search("\xE0\x83\xA9", lm("é")).found # overlong
    check spanOf(search("\xC0\xAFa", lm("."))) == 2 .. 3 # overlong
    check spanOf(search("\xED\xA0\x80a", lm("."))) == 3 .. 4 # surrogate
    check spanOf(search("\xF4\x90\x80\x80a", lm("."))) == 4 .. 5 # past U+10FFFF
    check spanOf(search("\xF5a", lm("."))) == 1 .. 2
    check spanOf(search("\x80a", lm("."))) == 1 .. 2
    check spanOf(search("\xE6\x97\nb", lm("."))) == 3 .. 4 # cut by its line
    check spanOf(search("é", lm("."))) == 0 .. 2
    check spanOf(search("\xF0\x9F\x98\x80", lm("."))) == 0 .. 4
    check spanOf(search("\xF4\x8F\xBF\xBF", lm("."))) == 0 .. 4

  test "the scans that find a line read its bytes past ASCII as a walk does":
    # A candidate line is checked for malformed bytes by the scans that find
    # its start and end, and by a DFA where it holds a byte past ASCII; each
    # against a byte at a time, over pieces that put a hit anywhere in a word
    # or a block.
    const pieces = [
      "a", "b", "\n", "\r", "é", "日", "😀", "\xE9", "\xC3", "\x80", "\xBF",
      "\xE0\xA0", "\xE0\x9F\xBF", "\xED\x9F\xBF", "\xED\xA0\x80", "\xF0\x8F",
      "\xF0\x90\x80\x80", "\xF4\x8F\xBF\xBF", "\xF4\x90\x80\x80", "\xF5", "\xC1\xBF",
      "\xC2\x80", "aaaaaaaaaaaaaaa", "\x7F",
    ]
    var r = initRand(20261124)
    for _ in 0 ..< 3000:
      var s = ""
      for _ in 0 ..< r.rand(12):
        s.add pieces[r.rand(pieces.high)]
      for lo in 0 .. s.len:
        for hi in lo .. s.len:
          var high: bool
          let nl = line_mode.lastNewlineIn(s, lo, hi, high)
          var want = -1
          for i in lo ..< hi:
            if s[i] == '\n':
              want = i
          check nl == want
          let ls =
            if nl >= 0:
              nl + 1
            else:
              lo
          check high == s[ls ..< hi].anyIt(it.uint8 >= 0x80'u8)
          check line_mode.wellFormed(s, lo, hi) ==
            (line_mode.nextMalformed(s, lo, hi) >= hi)
        var high: bool
        let le = line_mode.lineEndAt(s, lo, high)
        check le == (let q = s.find('\n', lo); if q < 0: s.len else: q)
        check high == s[lo ..< le].anyIt(it.uint8 >= 0x80'u8)

  test "a stretch found backward is the one the forward walk finds":
    const pieces = [
      "a", "bcdefghijk", "é", "日", "😀", "\xE9", "\xC3", "\x80",
      "\x80\x80\x80\x80", "\xE0\xA0", "\xE0\x9F\xBF", "\xED\xA0\x80", "\xF0\x90\x80",
      "\xF4\x90\x80\x80", "\xFF", "aaaaaaaaaaaaaaaa",
    ]
    var r = initRand(20261125)
    for _ in 0 ..< 3000:
      var s = ""
      for _ in 0 ..< r.rand(12):
        s.add pieces[r.rand(pieces.high)]
      for first in [0, s.len div 2]:
        # A walk may not begin inside a well-formed sequence.
        if first > 0 and line_mode.nextMalformed(s, first, s.len) == first and
            line_mode.prevMalformed(s, 0, first + 1, s.len) != first:
          continue
        for last in [s.len, max(first, s.len - 1)]:
          var cuts: seq[int]
          var i = line_mode.nextMalformed(s, first, last)
          while i < last:
            cuts.add i
            i = line_mode.nextMalformed(s, i + 1, last)
          for p in first .. last:
            var want = first - 1
            for c in cuts:
              if c < p:
                want = c
            check line_mode.prevMalformed(s, first, p, last) == want

  test "\\b reads back over three continuation bytes at most":
    check not search("a\x97\x97\x97b", lm("\\bb")).found
    check spanOf(search("a\x97\x97\x97\x97b", lm("\\bb"))) == 5 .. 6

  test "^, \\A, $, \\z and \\Z hold only at the line's own edges":
    check not search("\xE9a", lm("^a")).found
    check not search("\xE9a", lm("\\Aa")).found
    check not search("a\xE9", lm("a$")).found
    check not search("a\xE9", lm("a\\z")).found
    check not search("a\xE9", lm("a\\Z")).found
    check not search("\xE9", lm("^$")).found
    check spanOf(search("\xE9abc", lm("^"))) == 0 .. 0
    check spanOf(search("abc\xE9", lm("$"))) == 4 .. 4
    check spanOf(search("a\xE9", lm("^a"))) == 0 .. 1
    check spanOf(search("\xE9b", lm("b$"))) == 1 .. 2

  test "\\B does not hold beside it, and \\b reads it as a non-word side":
    check not search("\x97\x97", lm("\\B")).found
    check spanOf(search("\xE9 ", lm("\\B"))) == 2 .. 2
    check spanOf(search(" \xE9", lm("\\B"))) == 0 .. 0
    check spanOf(search("\x97a", lm("\\b"))) == 1 .. 1
    check spanOf(search("\xE9a", lm("\\ba"))) == 1 .. 2
    check spanOf(search("a\xE9", lm("a\\b"))) == 0 .. 1
    check spanOf(search("\xE9a", re("\\<a", {rfLineMode, rfWordBeginEnd}))) == 1 .. 2

  test "empty matches fall on every side of it":
    check spans("\x97\x97", lm("x*")) == @[span(0, 0), span(1, 1), span(2, 2)]
    check spans("a\xE9\nb", lm("")) == (0 .. 4).toSeq.mapIt(span(it, it))
    # A scan steps one byte past a malformed byte, not the three its lead
    # declares, and a well-formed character whole.
    check spans("\xE9ab", lm("x*")) == (0 .. 3).toSeq.mapIt(span(it, it))
    check spans("\xF0ab\r\n", re("x*", {rfLineMode, rfCrlf})) ==
      (0 .. 3).toSeq.mapIt(span(it, it))
    check spans("é\xE9", lm("")) == @[span(0, 0), span(2, 2), span(3, 3)]

  test "a scan goes on across the stretches and the lines":
    check spans("ab\xE9cd\xE9\nef", lm("\\w+")) == @[span(0, 2), span(3, 5), span(7, 9)]
    check spans("caf\xE9 \xE9x", lm("(?i)X")) == @[span(6, 7)]

  test "a scan keeps the stretch it is in from match to match":
    # Walking the stretches from the line's start on every match would cost
    # a long line a pass per match.
    privateAccess(MatchContext)
    let rx = lm("b")
    let s = "a\xE9b b\xE9b"
    let ctx = newMatchContext()
    var sc = initMatchScanner(s)
    var m: Match
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 2 .. 3
    check ctx.lineMemoStretch == 2
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 4 .. 5
    check ctx.lineMemoStretch == 2
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 6 .. 7
    check ctx.lineMemoStretch == 6
    check not scanNext(sc, ctx, s, rx, m)

  test "a scan keeps its stretch's end and the region walked in it":
    privateAccess(MatchContext)
    let rx = lm("(?:[a-c][0-9]){3}")
    let s = "z\xE9" & repeat("a1", 30) & "\xE9b"
    let ctx = newMatchContext()
    var sc = initMatchScanner(s)
    var m: Match
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 2 .. 8
    check ctx.lineMemoStretch == 2
    check ctx.lineMemoStretchEnd == 62
    check scanNext(sc, ctx, s, rx, m)
    check m.matchSpan == 8 .. 14
    # In the view's offsets; a new walk begins at 6.
    check ctx.seqRegionFrom == 0
    check ctx.seqRegionEnd == 60

  test "a CR put before the line's end between two calls moves the stretch's":
    let rx = re("\\w", {rfLineMode, rfCrlf})
    for (before, after, want) in [
      ("\xE9ab\r\n", "\xE9abc\n", 3 .. 4), ("\xE9abc\n", "\xE9ab\r\n", -1 .. -1)
    ]:
      var s = before
      let ctx = newMatchContext()
      var sc = initMatchScanner(s)
      var m: Match
      check scanNext(sc, ctx, s, rx, m)
      check scanNext(sc, ctx, s, rx, m)
      check m.matchSpan == 2 .. 3
      prepareMutation(s)
      copyMem(addr s[0], unsafeAddr after[0], s.len)
      let found = scanNext(sc, ctx, s, rx, m)
      check found == (want.a >= 0)
      if found:
        check spanOf(m) == want

  test "find-longest takes the longest match of all the line's stretches":
    check spans("ab\xE9abcd", lm("(?L)\\w+")) == @[span(3, 7)]
    check spans("abcd\xE9ab", lm("(?L)\\w+")) == @[span(0, 4), span(5, 7)]
    check spans("ab\xE9cd\xE9e", lm("(?L)\\w+")) == @[
      span(0, 2), span(3, 5), span(6, 7)
    ]
    check spans("a\xE9\nabc", lm("(?L)\\w+")) == @[span(0, 1), span(3, 6)]
    check search("ab\xE9xcd", lm("(?L)(x)?(\\w)\\w+")).boundaries ==
      @[span(3, 6), span(3, 4), span(4, 5)]
    check search("ab\xE9abcd", re("\\w+", {rfLineMode, rfFindLongest})).matchSpan ==
      3 .. 7

  test "a cut at the far end leaves \\b at the line's start as it is":
    for pat in ["(?<=\\bx?)a", "(?<=\\b(?~z))a"]:
      check not search("a", lm(pat)).found
      check not search("a\xE9", lm(pat)).found
      check not search("a\x97b", lm(pat)).found
    # A cut start is not the line's.
    check spanOf(search("\xE9a", lm("(?<=\\bx?)a"))) == 1 .. 2
    check spanOf(search(" a", lm("(?<=\\bx?)a"))) == 1 .. 2

  test "an anchor at a cut reads the word flags in force where it is":
    proc lw(p: string): Regex =
      re(p, {rfLineMode, rfWordBeginEnd})

    let s = "é\x97b"
    check not search(s, lm("\\bb")).found
    for pat in ["(?W)\\bb", "(?W:\\bb)", "(?P:\\bb)", "(?W:\\<b)"]:
      check spanOf(search(s, lw(pat))) == 3 .. 4
    check spanOf(search(s, lm("\\Bb"))) == 3 .. 4
    check not search(s, lm("(?W:\\Bb)")).found
    check not search(s, lw("\\<b")).found
    check spanOf(search(s, re("\\bb", {rfLineMode, rfAsciiWord}))) == 3 .. 4

  test "under an ASCII word flag a malformed byte is a non-word one":
    # rg's (?-u:\b) and (?-u:\B), which read one byte on each side.
    proc lw(p: string): Regex =
      re(p, {rfLineMode, rfWordBeginEnd, rfAsciiWord})

    for s in ["a\x97b", "a\xE9b"]:
      for pat in ["\\bb", "\\<b"]:
        check spanOf(search(s, lw(pat))) == 2 .. 3
      for pat in ["(?W)\\bb", "(?P:\\bb)"]:
        check spanOf(search(s, lm(pat))) == 2 .. 3
      check not search(s, lw("\\Bb")).found
      check spanOf(search(s, lw("a\\b"))) == 0 .. 1
      check not search(s, lw("a\\B")).found
    check not search("a\x97b", lm("\\bb")).found
    check spanOf(search("a\x97-", lw("\\B-"))) == 2 .. 3
    check spanOf(search("a\xE9-", lw("\\B-"))) == 2 .. 3
    check spanOf(search("é\xE9a", lw("é\\B"))) == 0 .. 2
    check not search("é\xE9a", lm("é\\B")).found

  test "groups come back in the subject's offsets":
    let m = search("\xE9ab", lm("(a)(b)"))
    check m.boundaries == @[span(1, 3), span(1, 2), span(2, 3)]

  test "searchBackward and matchAt read the stretch holding the position":
    check spanOf(searchBackward("a\xE9b", lm("[ab]"))) == 2 .. 3
    check spanOf(searchBackward("a\xE9b", lm("^."))) == 0 .. 1
    check spanOf(searchBackward("a\xE9b", lm("[ab]"), start = 1)) == 0 .. 1
    check spanOf(matchAt("a\xE9b", lm("b"), pos = 2)) == 2 .. 3
    check not matchAt("a\xE9b", lm("^b"), pos = 2).found
    check not matchAt("a\xE9b", lm("\\Bb"), pos = 2).found
    check not matchAt("a\xE9b", lm("$"), pos = 1).found
    check spanOf(matchAt("a\xE9", lm("$"), pos = 2)) == 2 .. 2
    check spanOf(matchAt("日\xE9é", lm("\\w"), pos = 4)) == 4 .. 6
    check spanOf(matchAt("日é", lm("\\w"), pos = 3)) == 3 .. 5
    check spanOf(searchBackward("日\xE9é日\nab", lm("[日é]"), start = 8)) == 6 .. 9

  test "a pattern that begins at the line's start is tried there alone":
    for p in ["^", "^a", "\\A", "\\Aa", "(?:^a|^b)", "(^)a?", "^(?=a)", "(?:^a?)+"]:
      checkpoint p
      let r = lm(p)
      for s in [
        "a\xE9a", "\xE9a", "a\xE9a\na\xE9\n\xE9a", "b\xE9a\n\xE9", "\xC3\xA9\xE9a"
      ]:
        checkpoint s.escape
        # Each position's own answer, by ``matchAt``.
        var starts: seq[int]
        for i in 0 .. s.len:
          if s.len > 1 and i == 1 and s.startsWith("\xC3\xA9"):
            continue
          if matchAt(s, r, pos = i).found:
            starts.add i
        check spans(s, r).mapIt(it.a) == starts
        for start in 0 .. s.len:
          if s.startsWith("\xC3\xA9") and start == 1:
            continue
          let ahead = starts.filterIt(it >= start)
          let back = starts.filterIt(it <= start)
          check spanOf(search(s, r, start = start)).a ==
            (if ahead.len > 0: ahead[0] else: UnsetSpan.a)
          check spanOf(searchBackward(s, r, start = start)).a ==
            (if back.len > 0: back[^1] else: UnsetSpan.a)
    # A branch that is not so anchored is tried in every stretch.
    check spans("a\xE9b", lm("^a|b")) == @[span(0, 1), span(2, 3)]
    check spans("\xE9b", lm("(?:^a)?b")) == @[span(1, 2)]
    check spans("\xE9b", lm("(?!^)b")) == @[span(1, 2)]
    check spanOf(searchBackward("a\xE9b", lm("^a|b"))) == 2 .. 3
    check spanOf(search("a\xE9aa", re("^a|^aa", {rfLineMode, rfFindLongest}))) == 0 .. 1

  test "searchBackward reads every stretch at or before start, and no other":
    let ctx = newMatchContext()
    var m: Match
    let s = "a\xE9\xE9b\xE9c"
    for (start, want) in [
      (0, 0 .. 1),
      (1, 0 .. 1),
      (2, 0 .. 1),
      (3, 3 .. 4),
      (4, 3 .. 4),
      (5, 5 .. 6),
      (6, 5 .. 6),
    ]:
      searchBackwardIntoCtx(ctx, s, lm("\\w"), m, start = start)
      check spanOf(m) == want
    check spanOf(searchBackward(s, lm("a"))) == 0 .. 1
    check spanOf(searchBackward(s, lm("$"))) == 6 .. 6
    check not searchBackward(s, lm("$"), start = 5).found

  test "\\y holds on both sides of it, and \\Y on neither":
    for mode in ["", "(?y{w})"]:
      checkpoint mode
      check spans("\xE9", lm(mode & "\\y")) == @[span(0, 0), span(1, 1)]
      check spans("a\xE9b", lm(mode & "\\y")) == (0 .. 3).mapIt(span(it, it))
      check spans("a\xE9b", lm(mode & "\\Y")).len == 0
      check spans("\xE9", lm(mode & "\\Y")).len == 0
    check spans("ab\xE9cd", lm("\\X\\y")) ==
      @[span(0, 1), span(1, 2), span(3, 4), span(4, 5)]
    check spans("ab\xE9cd", lm("(?y{w})\\y\\w+\\y")) == @[span(0, 2), span(3, 5)]

  test "\\G holds only in the stretch the search starts in":
    check not search("\xE9b", lm("\\Gb")).found
    check spanOf(search("x\xE9b", lm("\\Gb"), start = 2)) == 2 .. 3
    check spanOf(search("\xE9\nb", lm("\\Gb"))) == 2 .. 3
    check spanOf(search("a\xE9\xE9\nx\xE9b", lm("\\G(?:x|b)"))) == 4 .. 5
    # Not every way through these begins with it.
    check spanOf(search("a\xE9b", lm("\\Gb|b"))) == 2 .. 3
    check spanOf(search("a\xE9b", lm("(?:\\G|)b"))) == 2 .. 3
    # Find-longest keeps what the one stretch gave.
    check spanOf(search("ab\xE9abc", re("\\Ga(?:|bc?)", {rfLineMode, rfFindLongest}))) ==
      0 .. 2

  test "backward, \\G is the line's end and no cut":
    # As on a clean line.
    for s in ["abXcd", "ab\xE9cd"]:
      for start in 0 .. 4:
        check not searchBackward(s, lm("b\\G"), start = start).found
        check not searchBackward(s, lm("\\G"), start = start).found
    check spanOf(searchBackward("ab\xE9cd", lm("d\\G"))) == 4 .. 5
    check spanOf(searchBackward("ab\xE9cd", lm("\\G"))) == 5 .. 5
    check spanOf(searchBackward("a\xE9", lm("\\G"))) == 2 .. 2
    # Nothing in the last line: on to the line before it.
    check spanOf(searchBackward("ab\nc\xE9d", lm("\\G(?<=b)"))) ==
      spanOf(searchBackward("ab\ncXd", lm("\\G(?<=b)")))

  test "under rfCrlf the CR still ends the line after it":
    check not search("a\xE9\r\n", re("a$", {rfLineMode, rfCrlf})).found
    check spanOf(search("a\xE9\r\n", re("$", {rfLineMode, rfCrlf}))) == 2 .. 2
    check spanOf(search("\xE9a\r\n", re("^a|a$", {rfLineMode, rfCrlf}))) == 1 .. 2

  test "the walk goes straight to the stretch of the next candidate":
    # Stretches that lack what every match holds are skipped; the one a
    # candidate begins, ends or lies inside is not.
    check spans("ab\xE9b\xE9\xE9ab", lm("(?<=a)b")) == @[span(1, 2), span(7, 8)]
    check spans("z\xE9az\xE9z", lm("(?=.*z)a")) == @[span(2, 3)]
    check spans("a\xE9z", lm("(?=.*z)a")).len == 0
    check spans("é\xE9日\xC3é\xC3", lm("é")) == @[span(0, 2), span(7, 9)]
    check spans("\xC3\xE9\xC3é", lm("[éè]")) == @[span(3, 5)]
    check spans("q\xE9q\xE9Q\xE9q", lm("(?i)q")) ==
      @[span(0, 1), span(2, 3), span(4, 5), span(6, 7)]
    check spans("fo\xE9foo\xE9oof\xE9foo", lm("foo")) == @[span(3, 6), span(11, 14)]
    check spans("a\xE9\xE9", lm("b*")) ==
      @[span(0, 0), span(1, 1), span(2, 2), span(3, 3)]
    let longest = re("a+b", {rfLineMode, rfFindLongest})
    check spanOf(search("ab\xE9a\xE9aab\xE9ab", longest)) == 5 .. 8
    check spanOf(search("z\xE9z", lm("z"), start = 1)) == 2 .. 3

  test "a pattern that begins with an end anchor matches in the last stretch alone":
    for p in ["$", "\\z", "\\Z"]:
      check spans("a\xE9b\xE9cd", lm(p)) == @[span(6, 6)]
      check spans("a\xE9", lm(p)) == @[span(2, 2)]
      check spans("a\xE9b\n\xE9c\xE9", lm(p)) == @[span(3, 3), span(7, 7)]
      check spanOf(search("a\xE9b", lm(p), start = 1)) == 3 .. 3
      check spanOf(searchBackward("a\xE9b", lm(p))) == 3 .. 3
      check not searchBackward("a\xE9b", lm(p), start = 1).found
    check not search("a\xE9b", lm("^$")).found
    check not search("a\xE9b", lm("\\G$")).found

  test "the leading-assertion prefilter stays on beside a cut":
    check spans("\xE9a\xE9", lm("\\Ba")).len == 0
    check spans("\xE9 \xE9", lm("\\B ")).len == 0
    check spans("\xE9a\xE9", lm("\\ba")) == @[span(1, 2)]
    check spans("a\x97b", lm("\\Bb")) == @[span(2, 3)]
    check spans("a\x97b", lm("\\bb")).len == 0

suite "rfLineMode: a pattern may not spell a newline":
  test "every spelling of a literal newline is refused":
    for p in [
      "\\n", "a\\nb", "\\x0a", "\\x0A", "\\x{a}", "\\x{61 0a}", "\\012", "\\o{12}",
      "\\cJ", "\\C-j", "\\u000a", "a\nb", "[\\n]", "[\\n\\n]", "[\\n-\\n]", "[[\\n]]",
      "\\Q\n\\E", "(?:a|\\n)", "(?=\\n)", "(?~\\n)",
    ]:
      checkpoint p.escape
      expect RegexError:
        discard lm(p)
      # Without the flag each one compiles.
      discard re(p)

  test "a class or escape with other members is taken, and never meets one":
    for p in ["[\\na]", "[^a]", "\\s", "\\R", "\\p{Cc}", "(?m).", "\\O", "(?x)a\nb"]:
      checkpoint p.escape
      discard lm(p)

  test "the error says where":
    try:
      discard lm("ab\\n")
      fail()
    except RegexError as e:
      check "line mode" in e.msg
      check e.msg.endsWith("at position 2")

proc cr(pattern: string): Regex =
  re(pattern, {rfLineMode, rfCrlf})

proc crSpans(s: string, r: Regex): seq[Span] =
  for m in findAll(s, r):
    result.add m.matchSpan

suite "rfCrlf: a CR that ends a line lies outside it":
  test "the line ends before the CR of a CR LF":
    check spanOf(search("foo\r\n", cr("foo$"))) == 0 .. 3
    check spanOf(search("foo\r\n", cr("foo\\z"))) == 0 .. 3
    check spanOf(search("foo\r\n", cr("foo\\Z"))) == 0 .. 3
    for p in ["a.", "a\\s", "a[^x]", "a\\W", "a\\p{Cc}", "(?m)a.", "a\\R", "a\\X"]:
      checkpoint p.escape
      check not search("a\r\nb", cr(p)).found
    check spanOf(search("a\r\n\r\nb\r\n", cr("^$"))) == 3 .. 3
    check spanOf(search("x\r\nab\r\n", cr("(?<=a)b$"))) == 4 .. 5
    # Without the flag the CR stays in the line.
    check not search("foo\r\n", lm("foo$")).found
    check spanOf(search("a\r\nb", lm("a."))) == 0 .. 2

  test "a final CR with no newline after it lies outside the line too":
    check spanOf(search("x\na\r", cr("a$"))) == 2 .. 3
    check not search("a\r", cr("a.")).found
    check spanOf(search("\r", cr("^$"))) == 0 .. 0

  test "a CR inside a line is an ordinary character":
    check spanOf(search("b\rc\r\n", cr("b.c"))) == 0 .. 3
    check spanOf(search("b\rc\r\n", cr("b\\sc$"))) == 0 .. 3
    check not search("a\rb\r\n", cr("a$")).found
    check not search("a\rb\r\n", cr("^b")).found
    check spanOf(search("a\r\r\n", cr("a\\s$"))) == 0 .. 2

  test "the newline of a CR LF, and the end after a final CR, hold no line":
    let s = "a\r\nb\r"
    # A search from there begins with the next line; there is none after
    # the final CR.
    check spanOf(search(s, cr("$"), start = 2)) == 4 .. 4
    check spanOf(search(s, cr("^"), start = 2)) == 3 .. 3
    check not search(s, cr(""), start = 5).found
    # A backward search begins at the end of the line before.
    check spanOf(searchBackward(s, cr("$"), start = 2)) == 1 .. 1
    check spanOf(searchBackward(s, cr("$"), start = 5)) == 4 .. 4
    check spanOf(searchBackward(s, cr("\\w$"))) == 3 .. 4
    # matchAt finds nothing there, and the line's end before the CR is the
    # end it has.
    check not matchAt(s, cr(""), pos = 2).found
    check not matchAt(s, cr(""), pos = 5).found
    check spanOf(matchAt(s, cr("$"), pos = 1)) == 1 .. 1
    check spanOf(matchAt(s, cr("$"), pos = 4)) == 4 .. 4

  test "a scan steps from a line's end over the CR LF to the next line":
    check crSpans("a\r\n\r\nb\r\nc\r", cr("")) ==
      @[0, 1, 3, 5, 6, 8, 9].mapIt(span(it, it))
    # A lead byte cut short by the CR is the last character of its line, so
    # the step from it stops at the CR, where the line ends.
    check crSpans("\xE9\r\nx", cr("")) == @[0, 1, 3, 4].mapIt(span(it, it))
    check crSpans("a b\r\nc d\r\n", cr("\\w\\s*\\w")) == @[span(0, 3), span(5, 8)]
    check replace("a\r\nb\r\n", cr("$"), ";") == "a;\r\nb;\r\n"
    check split("a b\r\nc", cr("\\s+")) == @["a", "b\r\nc"]

suite "rfCrlf: a pattern may not spell a CR":
  test "every spelling of a literal CR is refused":
    for p in [
      "\\r", "a\\rb", "a\\r?", "\\x0d", "\\x0D", "\\x{d}", "\\x{61 0d}", "\\015",
      "\\o{15}", "\\cM", "\\C-m", "\\u000d", "a\rb", "[\\r]", "[\\r\\r]", "[\\r-\\r]",
      "[[\\r]]", "[\\r\\n]", "[\\n\\r]", "[[\\r][\\n]]", "\\Q\r\\E", "(?:a|\\r)",
      "(?=\\r)", "(?~\\r)",
    ]:
      checkpoint p.escape
      expect RegexError:
        discard cr(p)
      # Under rfLineMode alone each one compiles.
      discard lm(p)

  test "a class or escape with other members is taken":
    for p in [
      "[\\ra]", "[\\r\\na]", "[^a]", "\\s", "\\R", "\\p{Cc}", "(?m).", "\\O", "(?x)a\rb"
    ]:
      checkpoint p.escape
      discard cr(p)

  test "the error names the flag, and a newline keeps its own":
    try:
      discard cr("ab\\r")
      fail()
    except RegexError as e:
      check "rfCrlf" in e.msg
      check e.msg.endsWith("at position 2")
    try:
      discard cr("ab\\n")
      fail()
    except RegexError as e:
      check "line mode" in e.msg

  test "a spelling of both a CR and a newline names the CR":
    for p in ["\\x{d a}", "\\x{a d}", "[\\r\\n]", "[\\n\\r]", "[[\\n][\\r]]"]:
      checkpoint p.escape
      try:
        discard cr(p)
        fail()
      except RegexError as e:
        check "rfCrlf" in e.msg
    for p in ["\\n", "\\x{61 a}", "[\\n]", "[[\\n]]"]:
      checkpoint p.escape
      try:
        discard cr(p)
        fail()
      except RegexError as e:
        check "line mode" in e.msg

  test "rfCrlf without rfLineMode is refused":
    expect RegexError:
      discard re("a", {rfCrlf})

privateAccess(Regex)

proc tailOf(pattern: string, flags: RegexFlags = {}): set[uint8] =
  re(pattern, flags + {rfLineMode}).lineTail

suite "rfLineMode: a line that ends as no match does is not searched":
  const high = {0x80'u8 .. 0xFF'u8}

  test "the bytes a match ends its line with":
    check tailOf("\\t$") == {9'u8}
    check tailOf("foo\\z") == {uint8('o')}
    check tailOf("foo\\Z") == {uint8('o')}
    check tailOf("(?:a|b)(?=.|$)\\b$") == {uint8('a'), uint8('b')}
    check tailOf("[ab]c?$") == {uint8('a'), uint8('b'), uint8('c')}
    check tailOf("(?:ab$)+") == {uint8('b')}
    check tailOf("a(?:b$|c*$)") == {uint8('a'), uint8('b'), uint8('c')}
    check tailOf("日本$") == high
    check tailOf("a(?i)b$") * {0'u8 .. 0x7F'u8} == {uint8('B'), uint8('b')}
    check tailOf("(?i)s$") == {uint8('S'), uint8('s')} + high
    check tailOf("(?i)[0-9]+$") * {0'u8 .. 0x7F'u8} ==
      {uint8('0') .. uint8('9')} + {uint8('S'), uint8('s'), uint8('K'), uint8('k')}
    check tailOf("(?i)[a-c]$") >= {uint8('A') .. uint8('C'), uint8('a') .. uint8('c')}
    check uint8('x') notin tailOf("(?i)[a-c]$")
    check tailOf("(?i)[a-z]+$") >= high
    check tailOf("\\s+$") * {0'u8 .. 0x7F'u8} == {9'u8 .. 13'u8, 32'u8}

  test "none where a match may end elsewhere, be empty, or end with anything":
    for p in [
      "a", "a$|b", "a(?:$|b)", "a(?:b$)?", "a(?:$|\\b)", "$", "\\s*$", "^$", "a$b?",
      "a(?=$)", ".$", "\\R$", "\\X$", "(a)\\1$", "(?<n>a)\\g<n>$", "(?~a)$", "(?i)ß$",
      "(?i)[ß]$", "(?i)[aß]$", "(?i)[^a]$", "(a)?(?(1)b|c)$",
    ]:
      checkpoint p
      check tailOf(p) == {}
    check re("a$").lineTail == {}

  test "no attempt is made in such a line":
    # Each attempt would run into the step limit.
    let r = lm("(a+)+$")
    let s = repeat('a', 40) & "b"
    check not search(s, r).found
    check not searchBackward(s, r).found
    check spanOf(search(s & "\na", r)) == 42 .. 43
    check spanOf(searchBackward("a\n" & s, r)) == 0 .. 1
    # ``matchAt`` makes the one attempt it is asked for.
    expect RegexLimitError:
      discard matchAt(s, r, 0)

  test "only the last stretch of a line is searched":
    let r = lm("(a+)+$")
    let s = "\xE9" & repeat('a', 40) & "b\xE9"
    check spanOf(search(s & "a", r)) == 43 .. 44
    check spanOf(searchBackward(s & "a", r)) == 43 .. 44
    check not searchBackward(s & "a", r, 41).found

  test "the answers are those of a search of every line":
    const
      atoms = [
        "a", "b", "s", "S", "\\s", "\\w", "\\S", "\\d", "[ab]", "[^a]", "[ßs]", "ß",
        "[s]", "[a-z]", "[0-9]", "[[ab]s]", "[a-z&&[^b]]", "(?iI:[as])", "(?I:[as])",
        "é", "日", "ﬆ", "st", "ss", ".", "\\R", "\\X", "\\h", "(?:a|é)",
        "(?:ss|ß|b)", "(a|b)", "(?i:s)", "(?-i:s)", "(?i)", "(?=a)", "(?!b)", "(?<=a)",
        "\\b", "\\B", "\\K", "^", "(?>a+)", "(?:a$|b)", "(?:b$|\\s$)", "(?:$)", "\\xE9",
        "K", "\\1",
      ]
      quants = ["", "", "", "?", "*", "+", "{2}", "+?", "*+", "{0}", "{0,2}", "??"]
      ends =
        ["$", "$", "$", "\\z", "\\Z", "$\\b", "(?:$|b$)", "$(?!a)", "$?", "($)", ""]
      pieces = [
        "a", "b", "s", "S", " ", "\t", "ß", "é", "日", "ﬆ", "ſ", "K", "1", "\r",
        "\n", "\n", "\r\n", "\xE9", "\x80", "\xC3", "ss", "st", "\f",
      ]
    var rng = initRand(20261125)
    var tested, hits = 0
    for _ in 0 ..< 6000:
      var p = ""
      for _ in 0 .. rng.rand(3):
        let atom = rng.sample(atoms)
        p.add atom
        if atom notin ["(?i)", "^", "\\K", "\\b", "\\B"]:
          p.add rng.sample(quants)
      p.add rng.sample(ends)
      if rng.rand(4) == 0:
        p = p & "|" & rng.sample(atoms) & rng.sample(ends)
      var flags = {rfLineMode}
      if rng.rand(2) == 0:
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
      if r.lineTail == {}:
        continue
      inc tested
      var plain = r
      plain.lineTail = {}
      for _ in 0 ..< 12:
        var s = ""
        for _ in 0 .. rng.rand(14):
          s.add rng.sample(pieces)
        checkpoint p & " " & $flags & " " & s.escape
        let spans = toSeq(s.findAll(r)).mapIt(it.matchSpan)
        hits += spans.len
        check spans == toSeq(s.findAll(plain)).mapIt(it.matchSpan)
        let at = rng.rand(s.len)
        check spanOf(search(s, r, start = at)) == spanOf(search(s, plain, start = at))
        check spanOf(searchBackward(s, r, at)) == spanOf(searchBackward(s, plain, at))
    check tested > 500
    check hits > 1000
