## Public-API regressions found while comparing TextMate tokenization with
## vscode-oniguruma 2.0.1 (which compiles with ONIG_OPTION_CAPTURE_GROUP).
import std/[options, sequtils, strutils, unittest]
import ../reni

suite "capture-group compile option":
  test "mixed groups keep their original numbers and names":
    let regex = re(r"(a)(?<name>b)(c)", {rfCaptureGroup})
    let matched = search("abc", regex)
    check regex.captureCount == 3
    check captureIndex(regex, "name") == 2
    check matched.boundaries == @[span(0, 3), span(0, 1), span(1, 2), span(2, 3)]
    check captureText(matched, "name", "abc", regex) == some("b")
    check rfCaptureGroup in regex.flags

  test "numbered, named, and relative backreferences can coexist":
    for pattern in [
      r"(a)(?<name>b)\1\k<name>", r"(a)(?<name>b)\k<1>\k<2>",
      r"(a)(?<name>b)\k<-2>\k<-1>",
    ]:
      let matched = search("abab", re(pattern, {rfCaptureGroup}))
      check matched.boundaries == @[span(0, 4), span(0, 1), span(1, 2)]

  test "duplicate names remain individually addressable by number":
    let regex = re(r"(?<x>a)(?<x>b)\1\2", {rfCaptureGroup})
    let matched = search("abab", regex)
    check matched.boundaries == @[span(0, 4), span(0, 1), span(1, 2)]
    # The public name accessor returns the first group with that name.
    check captureText(matched, "x", "abab", regex) == some("a")
    check search("abb", re(r"(?<x>a)(?<x>b)\k<x>", {rfCaptureGroup})).found

  test "numbered and named subexpression calls preserve capture indices":
    for pattern in [r"(a)(?<name>b)\g<1>\g<name>", r"(a)(?<name>b)\g<-2>\g<-1>"]:
      let matched = search("abab", re(pattern, {rfCaptureGroup}))
      check matched.boundaries == @[span(0, 4), span(2, 3), span(3, 4)]

  test "numbered conditionals test the original ordinary group":
    let regex = re(r"\A(a)?(?<name>b)(?(1)c|d)", {rfCaptureGroup})
    check search("abc", regex).matchSpan == 0 .. 3
    let matched = search("bd", regex)
    check matched.matchSpan == 0 .. 2
    check not matched.captured(1)
    check matched.captureSpan(2) == 0 .. 1
    check not search("abd", regex).found

  test "invalid references still fail at compilation":
    for pattern in [r"(a)(?<name>b)\k<3>", r"(a)(?<name>b)\g<3>"]:
      expect RegexError:
        discard re(pattern, {rfCaptureGroup})

  test "oversized numeric references raise RegexError rather than a defect":
    let huge = "9".repeat(100)
    for suffix in [
      "\\k<" & huge & ">",
      "\\k<1+" & huge & ">",
      "\\g<" & huge & ">",
      "\\g<+" & huge & ">",
      "(?" & huge & ")",
      "(?+" & huge & ")",
      "(?('" & huge & "')a|b)",
      "(*MAX{" & huge & "})",
      "\\k<+" & $high(int) & ">",
      "\\g<+" & $high(int) & ">",
      "(?+" & $high(int) & ")",
    ]:
      checkpoint(suffix)
      expect RegexError:
        discard re("(a)(?<name>b)" & suffix, {rfCaptureGroup})
    # A condition number that large is a pattern, as in Oniguruma.
    let cond = re("(a)(?<name>b)(?(" & huge & ")a|b)", {rfCaptureGroup})
    check search("abb", cond).matchSpan == 0 .. 3

  test "long plain numeric escapes retain their octal fallback":
    let digits = "1".repeat(100)
    check search("I" & "1".repeat(97), re("\\" & digits)).found

  test "the default still demotes ordinary captures and rejects numbered refs":
    let regex = re("(a)(?<name>b)(c)")
    check regex.captureCount == 1
    check captureIndex(regex, "name") == 1
    check search("abc", regex).boundaries == @[span(0, 3), span(1, 2)]
    expect RegexError:
      discard re(r"(a)(?<name>b)\1")

suite "Oniguruma line and search anchors":
  test "line begin excludes the empty position after a terminal newline":
    for subject in ["a\n", "\n"]:
      check not matchAt(subject, re("^"), pos = subject.len).found
      check not search(subject, re("^"), start = subject.len).found
      check toSeq(findAll(subject, re("^"))).len == 1
    check matchAt("", re("^")).found
    check matchAt("a\nb", re("^"), pos = 2).found
    check searchBackward("a\n", re("^")).matchSpan == 0 .. 0

  test "line begin uses the subject end inside an absent range":
    for pattern in [r"(?~|b)a\n^", r"(?~|b|a\n^)"]:
      let regex = re(pattern)
      check search("a\nb", regex).matchSpan == 0 .. 2
      check matchAt("a\nb", regex).matchSpan == 0 .. 2
      check searchBackward("a\nb", regex).matchSpan == 0 .. 2
      check not search("a\n", regex).found

  test "line end and string end still match at EOF":
    for subject in ["", "a", "a\n"]:
      for pattern in ["$", r"\z", r"\Z"]:
        check matchAt(subject, re(pattern), pos = subject.len).found
    check toSeq(findAll("a\n", re("$"))).mapIt(it.matchSpan) == @[
      span(1, 1), span(2, 2)
    ]

  test "a G alternative starts at the supplied mid-line search origin":
    for pattern in [r"(^|\G)y", r"(^(?!\z)|\G)y", r"(?<=^|\G)y"]:
      check search(">y", re(pattern), start = 1).matchSpan == 1 .. 2
      check not search(">xy", re(pattern), start = 1).found

suite "per-call anchor options":
  test "disabling string begin keeps other alternatives and line begin":
    let regex = re(r"\Aa|^b|c")
    check search("abc", regex).matchSpan == 0 .. 1
    check search("abc", regex, options = {moNotBeginString}).matchSpan == 2 .. 3
    check search("b", regex, options = {moNotBeginString}).found
    check not matchAt("a", re(r"\Aa"), options = {moNotBeginString}).found

  test "disabling search begin keeps its negation and other alternatives":
    let regex = re(r"\Gx|y")
    check search(">xy", regex, start = 1).matchSpan == 1 .. 2
    check search(">xy", regex, start = 1, options = {moNotBeginPosition}).matchSpan ==
      2 .. 3
    check matchAt("x", re(r"(?!\G)x"), options = {moNotBeginPosition}).found
    check not matchAt("x", re(r"(?!\G)x")).found

  test "options apply inside lookarounds and calls":
    check not search(">xy", re(r"(?<=\Gx)y"), start = 1, options = {moNotBeginPosition}).found
    check search(">xy", re(r"(?<=\Gx)y"), start = 1).found
    check not search("x", re(r"(?<a>\Ax)\g<a>?"), options = {moNotBeginString}).found
    check search("x", re(r"(?<a>\Ax)\g<a>?")).found

  test "backward search also honors both options":
    let regex = re(r"\Ax|\Gx")
    check searchBackward("x", regex, start = 0).found
    check not searchBackward(
      "x", regex, start = 0, options = {moNotBeginString, moNotBeginPosition}
    ).found

  test "a reused context resets options on every entry point":
    let ctx = newMatchContext()
    let regex = re(r"\Ax|\Gx")
    var matched: Match
    let disabled: MatchOptions = {moNotBeginString, moNotBeginPosition}
    for _ in 0 ..< 3:
      check not searchIntoCtx(ctx, "x", regex, matched, options = disabled)
      check searchIntoCtx(ctx, "x", regex, matched)
      check not matchAtIntoCtx(ctx, "x", regex, matched, options = disabled)
      check matchAtIntoCtx(ctx, "x", regex, matched)
      check not searchBackwardIntoCtx(
        ctx, "x", regex, matched, start = 0, options = disabled
      )
      check searchBackwardIntoCtx(ctx, "x", regex, matched, start = 0)
    check regex.pattern == r"\Ax|\Gx"

  test "find-longest still considers every enabled alternative":
    let regex = re(r"\Gx|xy|\Axyz", {rfFindLongest})
    check search("xyz", regex).matchSpan == 0 .. 3
    check search("xyz", regex, options = {moNotBeginString, moNotBeginPosition}).matchSpan ==
      0 .. 2

suite "default step limit":
  test "a line Oniguruma answers inside its retry limit gets an answer":
    # ``struct_variables_types_fields`` from VS Code's Go grammar, on a
    # shortened line of Python.  The attempt after the brace takes about 4
    # million steps; Oniguruma answers it in 1.1 million of its 10 million
    # retries.
    let regex = re(
      """(?:(?<=\{)((?:\s*(?:(?:(?:\w+\,\s*)+)?(?:\w+\s+))?(?:(?:(?:\s*(?:[\*\[\]]+)?(?:\<\-\s*)?\bchan\b(?:\s*\<\-)?\s*)+)?(?:[^\s/\`"]+)(?:\;)?))+)\s*(?=\}))""",
      {rfCaptureGroup},
    )
    let line = "{}, 'foo', 'foo.py', 0)"
    check not search(line, regex).found
    const previousDefault = 1_000_000
    expect RegexLimitError:
      discard search(line, regex, stepLimit = previousDefault)
