import std/[unittest, strutils]

import ../reni
import ../reni/[engine, types, parser]
import ../reni/compiler {.all.}

# Subroutine calls, recursion, and the recursions the compiler turns away.
# Split out of ``test_engine.nim`` because ``refc`` allows 3500 module-level
# globals and a ``unittest`` body is module-level.

suite "Subroutine calls and recursion":
  test "numeric call (?1)":
    let m = search("aa", re("(a)(?1)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "call re-evaluates body, not backref":
    let m = search("aab", re("([abc])\\1(?1)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "call second group (?2)":
    let m = search("aba", re("(a)(b)(?1)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "named call (?&name)":
    let m = search("42", re("(?<d>[0-9])(?&d)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "named call triple":
    let m = search("789", re("(?<d>[0-9])(?&d)(?&d)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "simple recursion a(?R)?b":
    let m = search("aabb", re("a(?R)?b"))
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "whole pattern recursion balanced parens":
    let m = search("(a(b)c)", re("\\((?:[^()]*|(?R))*\\)"))
    check m.found
    check m.boundaries[0] == 0 .. 7

  test "deep recursion balanced parens":
    let m = search("(a(b(c)d)e)", re("\\((?:[^()]*|(?R))*\\)"))
    check m.found
    check m.boundaries[0] == 0 .. 11

  test "relative call (?-1)":
    let m = search("aa", re("(a)(?-1)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "relative call (?-1) two groups":
    let m = search("abb", re("(a)(b)(?-1)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "Python (?P>name)":
    let m = search("ab", re("(?P<L>[a-z])(?P>L)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "recursion depth limit does not crash":
    let s = "a".repeat(60)
    # Each subject character costs about one ``matchNodeRecursive`` level,
    # and ``maxRecursionDepth`` (default 50) caps the subroutine nesting, so
    # this stays near ~50 delegation levels: inside the byte budget in both
    # exception models, and the partial match the depth cap bounds is the
    # answer. Under a small ``-d:reniMaxStackBytes`` the same shape is what
    # the budget guard turns into RegexLimitError. A segfault is neither.
    when compileOption("exceptions", "setjmp") or engine.MaxStackBytes <= 64 * 1024:
      try:
        check search(s, re("(a(?1)?)")).found
      except RegexLimitError:
        discard
    else:
      check search(s, re("(a(?1)?)")).found

  test "maxRecursionDepth bounds recursion before the call depth guard does":
    # The public maxRecursionDepth is only meaningful if it is reachable: the
    # call depth guard must not fire first and turn a bounded partial match
    # into an error. Subroutine calls hold no native frame per level, so 40
    # characters fit every budget on every build and the depth cap answers.
    let m = search("a".repeat(40), re("(a(?1)?)"), maxRecursionDepth = 50)
    check m.found
    check m.matchSpan == Span(a: 0, b: 40)

suite "Mutual recursion detection":
  test "direct self-recursion (?<a>(?&a)) detected":
    expect RegexError:
      discard re("(?<a>(?&a))")

  test "mutual 2-cycle (?<a>(?&b))(?<b>(?&a)) detected":
    expect RegexError:
      discard re("(?<a>(?&b))(?<b>(?&a))")

  test "mutual 3-cycle a→b→c→a detected":
    expect RegexError:
      discard re("(?<a>(?&b))(?<b>(?&c))(?<c>(?&a))")

  test "self-recursion with consumption is valid":
    let r = re("(?<a>x(?&a)?)")
    check r.captureCount == 1

  test "mutual recursion with consumption is valid":
    let r = re("(?<a>x(?&b)?)(?<b>y(?&a)?)")
    check r.captureCount == 2

  test "mutual recursion via optional quantifier is detected":
    # Each group may call the other before it consumes anything.  Oniguruma:
    # -221, as for any left recursion.
    expect RegexError:
      discard re("(?<a>(?&b)?x)(?<b>(?&a)?y)")

  test "self-recursion under an inverted range is detected":
    # ``{2,0}`` behaves like ``{0,2}``: the body may be skipped, but the call
    # in it comes before anything is consumed.  Oniguruma: -221.
    expect RegexError:
      discard re("(?<a>(?&a){2,0})")

  test "recursion after an inverted range is detected":
    # ``b{2,0}`` can match empty, so the call is reachable without consuming
    # input.
    expect RegexError:
      discard re("(?<a>b{2,0}(?&a))")

  test "recursion after an inverted range is detected before a consumer":
    expect RegexError:
      discard re("(?<a>b{2,0}(?&a)c)")

  test "recursion in a pattern condition detected":
    # The condition runs before either branch.  Oniguruma: -221.
    expect RegexError:
      discard re("(?<n>(?(\\g<n>)a|b))")
    check search("b", re("(?<n>(?(x\\g<n>)a|b))")).matchSpan == 0 .. 1

  test "a call that consumes keeps a conditional's branch off the start":
    # ``\\g<m>`` consumes ``x``, so the no branch calls ``n`` past it, as
    # Oniguruma reads it too.
    check not search("xb", re("(?<n>(?(a)b|\\g<m>\\g<n>))(?<m>x)")).found

  test "recursion behind a conditional with no else branch detected":
    # /(?(<a>)x)/ matches empty when the condition is false, so \g<a> is
    # reachable without consuming input.  Oniguruma rejects this pattern with
    # ONIGERR_NEVER_ENDING_RECURSION.
    expect RegexError:
      discard re("(?<a>(?(<a>)x)\\g<a>)")

  test "recursion behind a conditional with an else branch is valid":
    # Both branches consume, so the call is only reached after input.
    let r = re("(?<a>(?(<a>)x|y)\\g<a>?)")
    check r.captureCount == 1

  # The rest of the suite follows Oniguruma's ``infinite_recursive_call_check``;
  # every pattern rejected below is -221 in libonig 6.9.10, every other one
  # compiles there.

  test "a call to the whole pattern is checked like a group":
    for pattern in [
      "\\g<0>", "a\\g<0>", "a|\\g<0>", "(?=\\g<0>)", "x|(?<=\\g<0>)", "x|(?<!\\g<0>)"
    ]:
      expect RegexError:
        discard re(pattern)
    check search("abb", re("a|b\\g<0>")).matchSpan == 0 .. 1

  test "a branch that recurses before it consumes is detected":
    # Another branch that stops the recursion does not help.
    for pattern in ["(a|\\g<1>)", "(?<n>(?:\\g<n>)?a|b)", "(?<a>\\g<b>|x)(?<b>\\g<a>)"]:
      expect RegexError:
        discard re(pattern)

  test "a recursion with no way out is detected after a consumer":
    for pattern in [
      "(a\\g<1>)", "a(?<a>b\\g<b>)(?<b>\\g<a>)", "(?<a>x(?<b>\\g<a>))\\g<b>"
    ]:
      expect RegexError:
        discard re(pattern)

  test "a group no call can run is not checked":
    # A call under ``{0}`` runs only from a group that is called.
    check search("a", re("(?<a>\\g<a>){0}a")).matchSpan == 0 .. 1
    check search("b", re("(?<a>\\g<b>){0}(?<b>\\g<a>){0}b")).matchSpan == 0 .. 1
    expect RegexError:
      discard re("(?<a>\\g<a>){0}\\g<a>")
    expect RegexError:
      discard re("(?<a>\\g<b>){0}(?<b>\\g<a>){0}\\g<b>")

  test "what counts as consuming before a recursion":
    # Zero-width items do not, and neither does ``(*FAIL)``, which Oniguruma
    # reads as a callout here.
    for pattern in [
      "(?<n>\\K\\g<n>|c)", "(?<n>\\y\\g<n>|c)", "(?<n>(*FAIL)\\g<n>|c)",
      "(?<n>(*MAX{2})\\g<n>|c)", "(?<n>a{0}\\g<n>|c)", "(?<n>(?(a)b)\\g<n>|d)",
    ]:
      expect RegexError:
        discard re(pattern)
    check search("c", re("(?<n>(?(a)b|c)\\g<n>|d)")).found == false
    # A backreference counts as the shortest group it reads, and as empty
    # inside a group it reads.
    expect RegexError:
      discard re("(\\2\\g<1>|c)()")
    expect RegexError:
      discard re("(\\1\\g<1>|c)")
    expect RegexError:
      discard re("(?<n>a)(?<n>)(?<m>\\k<n>\\g<m>|c)")
    check search("ca", re("(\\2\\g<1>|c)(a)")).matchSpan == 0 .. 2
    check search("abc", re("(?<n>a)(?<n>b)(?<m>\\k<n>\\g<m>|c)")).matchSpan == 0 .. 3
    # ``(?~|X|E)`` consumes what ``E`` does; the other absent forms nothing.
    check search("c", re("(?<n>(?~|a|b)\\g<n>|c)")).matchSpan == 0 .. 1
    for pattern in [
      "(?<n>(?~|a|b*)\\g<n>|c)", "(?<n>(?~a)\\g<n>|c)", "(?<n>(?~|a)\\g<n>|c)",
      "(?<n>(?~|)\\g<n>|c)",
    ]:
      expect RegexError:
        discard re(pattern)

  test "a recursion in an absent pattern is never one every path takes":
    check search("c", re("(?<n>(?~a\\g<n>)|c)")).found
    for pattern in [
      "(?<n>(?~\\g<n>)|c)", "(?<n>(?~|\\g<n>|b)|c)", "(?<n>(?~|a|\\g<n>)|c)",
      "(?<n>(?~|a|b\\g<n>))",
    ]:
      expect RegexError:
        discard re(pattern)

  test "a conditional's yes branch starts where its condition ends":
    for pattern in [
      "(?<n>(?(<n>)\\g<n>|b))", "(?<n>(?(*FAIL)a|\\g<n>))",
      "(?<n>a(?(<n>)\\g<n>|\\g<n>))",
    ]:
      expect RegexError:
        discard re(pattern)
    check search("b", re("(?<n>(?(b\\g<n>)a|b))")).matchSpan == 0 .. 1
    check search("a", re("(?<n>a(?(<n>)\\g<n>))")).matchSpan == 0 .. 1

  test "a length worked out during one group's check is kept for the next":
    # Oniguruma fixes a group's length the first time it is asked for.  Asked
    # while group 1 is checked, group 2 (a call to group 1) counts group 1 as
    # empty, so group 3 then sees ``\2`` as empty too.  In the other order
    # group 2's length is worked out first, and is 1.
    expect RegexError:
      discard re("(\\2x\\g<1>|w)(\\g<1>)(\\2\\g<3>|v)")
    check re("(\\3\\g<1>|v)(\\3x\\g<2>|w)(\\g<2>)").captureCount == 3

  test "a group called twice by each next one is walked once":
    # Each of the 40 groups calls the one before twice, so walking every call
    # would take 2^40 steps.  None of them leads back to ``r``, so each walk
    # into one goes the same way.
    var levels = ""
    for i in 1 .. 40:
      levels.add "(?<a" & $i & ">\\g<a" & $(i - 1) & ">\\g<a" & $(i - 1) & ">)"
    check re("(?<r>(?<a0>x)" & levels & "(?:\\g<r>)?)").captureCount == 42

  test "a check that would go down too many paths gives up":
    # Each of the 12 groups calls all 12, so inside the cycle the walk goes
    # down every path, as Oniguruma's does: billions of steps.
    var calls: seq[string]
    for i in 1 .. 12:
      calls.add "\\g<" & $i & ">"
    let group = "(a(?:" & calls.join("|") & "))"
    expect RegexLimitError:
      discard re(group.repeat(12))

  test "a cycle each check walks once is not cut short":
    # 2,000 groups each call a hub that calls them all, so each one's check
    # walks the whole cycle: 16 million steps, though none into a group the
    # check has walked into before.
    var hub = "(b"
    for i in 2 .. 2_001:
      hub.add "|\\g<" & $i & ">"
    hub.add ")"
    check re(hub & "(a\\g<1>)".repeat(2_000)).captureCount == 2_001

proc searchAbsent(pattern: string): (bool, seq[int8]) =
  ## Whether group 1 of ``pattern`` reaches a ``(?~|...)`` form, and the
  ## answers kept for each group.
  var p = initParser(pattern)
  let ast = p.parseRegex()
  var bodies: seq[Node]
  var flags: seq[RegexFlags]
  collectGroupBodies(ast, bodies, flags)
  var calledAbsent = newSeq[int8](bodies.len)
  result[0] = containsAbsent(0, bodies, p.namedCaptures, calledAbsent)
  result[1] = calledAbsent

suite "Absent operators reached through a look-behind's call":
  test "a search that finds none keeps that for every group it went through":
    # So look-behinds that each call into one chain search it once: 20,000
    # of them into a chain of 20,000 took 10 seconds searching it anew each.
    check searchAbsent("(\\g<2>)(a\\g<3>)(\\g<1>)(b)") == (false, @[-1'i8, -1, -1, 0])

  test "a search that finds one keeps that for the group asked only":
    # Group 3 holds the form and group 2 does not, but only group 1 was asked
    # about.
    check searchAbsent("(\\g<2>\\g<3>)(b)((?~|a))") == (true, @[1'i8, 0, 0])
