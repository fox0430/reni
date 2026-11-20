## ``rfLineMode``: each line of the subject, without its ``\n``, is searched
## as a subject of its own, and the answers come back in the subject's
## offsets.  Every case below states what the line searched alone answers;
## the rule is notes/LINE_MODE.md §1.

import std/[importutils, sequtils, strutils, unittest]

import reni
import reni/engine {.all.}

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
    # The truncated lead byte is the last character of its line, so the empty
    # match after it is the line's end, not a position inside the next line.
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
