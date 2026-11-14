import std/[unittest, strutils]

import ../reni
import ../reni/[types, parser]
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
    # A call is a turn of the matcher loop and holds no native frame, so 60
    # nested calls never reach the stack budget.  ``maxRecursionDepth``
    # (default 20) fails the 21st, the group's own place counted as a call,
    # and the 20 characters the open calls took are the match.
    let m = search("a".repeat(60), re("(a(?1)?)"))
    check m.matchSpan == Span(a: 0, b: 20)

  test "maxRecursionDepth bounds recursion before the call depth guard does":
    # The public maxRecursionDepth is only meaningful if it is reachable: the
    # call depth guard must not fire first and turn a bounded partial match
    # into an error. Subroutine calls hold no native frame per level, so 60
    # characters fit every budget on every build and the depth cap answers
    # with the 50 the open calls took.
    let m = search("a".repeat(60), re("(a(?1)?)"), maxRecursionDepth = 50)
    check m.found
    check m.matchSpan == Span(a: 0, b: 50)

  test "a call that returned no longer counts toward maxRecursionDepth":
    # The depth counts the calls still open, as Oniguruma's nest counter does,
    # so a call repeated in a loop runs any number of times.  A Swift grammar's
    # operator pattern missed a ``//===`` banner of 80 characters.
    let m = search("//" & "=".repeat(78), re("(?<oph>[/=])\\g<oph>*$"))
    check m.found
    check m.matchSpan == Span(a: 0, b: 80)
    let r = re("\\A\\g<r>\\g<r>\\g<r>\\z(?<r>ab){0}")
    check search("ababab", r, maxRecursionDepth = 1).found

  test "the default depth is Oniguruma's nest limit, its own place counted":
    # Twenty calls may be open, as in Oniguruma, where a group a call can run
    # is a call where it is written too: 20 parentheses deep is 20 calls, and
    # at 21 the outermost group fails and the search takes the 20 inside.
    let r = re("(?<p>\\((?:[^()]|\\g<p>)*\\))")
    let at20 = search("(".repeat(20) & "x" & ")".repeat(20), r)
    check at20.matchSpan == Span(a: 0, b: 41)
    let at21 = search("(".repeat(21) & "x" & ")".repeat(21), r)
    check at21.matchSpan == Span(a: 1, b: 42)
    # ``\g<0>`` makes the whole pattern a call, so a match starts one deep.
    let whole = re("a\\g<0>?b")
    check search("a".repeat(20) & "b".repeat(20), whole).matchSpan == Span(a: 0, b: 40)
    check search("a".repeat(21) & "b".repeat(21), whole).matchSpan == Span(a: 1, b: 41)

  test "a limit below one leaves a \\g<0> pattern nothing to match":
    # ``\g<0>`` makes a match a call, which Oniguruma's level 0 fails before
    # anything is read; at one, only the call inside fails.
    let whole = re("a\\g<0>?b")
    check not search("ab", whole, maxRecursionDepth = 0).found
    check not searchBackward("ab", whole, maxRecursionDepth = 0).found
    check not matchAt("ab", whole, maxRecursionDepth = 0).found
    check search("aabb", whole, maxRecursionDepth = 1).matchSpan == Span(a: 1, b: 3)
    # A negative limit is read as zero, ``int.low`` included.
    check not search("ab", whole, maxRecursionDepth = int.low).found
    check search("x", re("x"), maxRecursionDepth = int.low).found

  test "backtracking into a call that returned opens it again":
    # The lazy call is skipped, the body returns, and ``\z`` fails; retrying
    # the call then nests one inside the call open again: two, past a limit
    # of one.
    let r = re("\\A\\g<r>\\z(?<r>a\\g<r>??b?){0}")
    check not search("aabb", r, maxRecursionDepth = 1).found
    check search("aabb", r, maxRecursionDepth = 2).matchSpan == Span(a: 0, b: 4)

  test "a call that returned keeps its level for a leveled reference":
    # A call's capture writes the level slot its group depth names, and the
    # depth stays until backtracking leaves the call.  Lowered when the call
    # returned, two calls in a row shared one slot.  Both answers are
    # Oniguruma's.
    check not search("abcc", re("(?<n>.)\\g<n>\\g<n>\\k<n+2>")).found
    let m = search("abab", re("(?<n>.(?:\\g<n>|))\\g<n>\\k<n+2>"))
    check m.matchSpan == Span(a: 0, b: 4)

  test "a call gives the caller its flags back":
    # The called group runs under the flags where it is written, and what
    # follows the call under the caller's.
    let m = search("aaB", re("(?<n>a)(?i:\\g<n>b)"))
    check m.found
    check m.matchSpan == Span(a: 0, b: 3)
    check not search("aAb", re("(?<n>a)(?i:\\g<n>b)")).found
    # Backtracking into the returned body runs it under its own flags again.
    let back = search("xYYc", re("\\g<n>c(?<n>(?i)x(?:y|yy)){0}"))
    check back.found
    check back.matchSpan == Span(a: 0, b: 4)
    # ``\g<0>`` is written where the pattern starts, under no ``(?i)``.
    check not search("xXy", re("x(?i:\\g<0>|y)")).found
    check search("xxy", re("x(?i:\\g<0>|y)")).matchSpan == Span(a: 0, b: 3)

  test "a called group runs under the grapheme mode it is written under":
    # As under its flags: Oniguruma settles the mode while compiling, so the
    # caller's has no say in what the body reads.  Spans read off Oniguruma
    # 6.9.10.
    check search("xab cd", re("(?<n>\\X)(?y{w}:\\g<n>)")).matchSpan == 0 .. 2
    # By number and by a relative number, reading the mode of the group named
    # and not of the one after it.
    check search("xab cd", re("(\\X)(?y{w}:\\g<1>)")).matchSpan == 0 .. 2
    check search("xab cd", re("(\\X)(?y{w}:\\g<-1>)")).matchSpan == 0 .. 2
    check search("ab cd", re("(?y{w}:\\g<+1>)(\\X)")).matchSpan == 0 .. 2
    check search("xabc d", re("(\\X)(?y{w}:(a))\\g<1>")).matchSpan == 0 .. 3
    check search("ab cd e", re("(?y{w}:(\\X)) \\g<1>")).matchSpan == 0 .. 5
    check search("ab cd e", re("(?y{w}:(\\X)) \\g<-1>")).matchSpan == 0 .. 5
    # A group renumbered when the unnamed one before it stops capturing.
    check search("xab cd", re("(x)(?y{w}:(?<n>\\X))\\g<n>")).matchSpan == 0 .. 4
    check search("ab cd", re("(?y{g}:(?<n>\\X))(?y{w}:\\g<n>)")).matchSpan == 0 .. 2
    check search("ab cd e", re("(?y{w}:(?<n>\\X)) \\g<n>")).matchSpan == 0 .. 5
    check search("ab cd e", re("(?y{w}:(?<n>\\X)) (?y{g}:\\g<n>)")).matchSpan == 0 .. 5
    # ``\y`` and ``\Y`` read it as ``\X`` does.
    check search("abab", re("(?<n>a\\yb)(?y{w}:\\g<n>)")).matchSpan == 0 .. 4
    check search("abab", re("(?y{w}:(?<n>a\\Yb))\\g<n>")).matchSpan == 0 .. 4
    # A call in a look-ahead, and a call from a called group.
    check search("ab cd", re("(?y{w}:(?=\\g<n>b)\\X)(?<n>\\X){0}")).matchSpan == 0 .. 2
    check search("xab cd ef", re("(?<a>\\X)(?<b>(?y{w}:\\g<a>\\X))\\g<b>")).matchSpan ==
      0 .. 6
    # A look-behind in the called group, against the same body under the
    # caller's mode, and one whose branches its tails pass over.
    check not search("ab-", re("(?<n>(?<=^\\X)-){0}(?y{w}:\\g<n>)")).found
    check search("ab-", re("(?y{w}:(?<=^\\X)-)")).matchSpan == 2 .. 3
    check search("abc", re("(?<n>ab(?<=ab|x)c){0}(?y{g}:\\g<n>)")).matchSpan == 0 .. 3

  test "\\g<0> runs under the modes the pattern writes, not the caller's":
    check search("qbcd e", re("b\\X|(?y{w}:q\\g<0>)")).matchSpan == 0 .. 3
    check search("qbcd e", re("(?y{w}:b\\X|q\\g<0>)")).matchSpan == 0 .. 4

  test "a call leaves the caller's grapheme mode as it found it":
    # After the body, whichever of the two set a mode.
    check search("abcd ef", re("(?y{w}:\\g<n>\\X)(?<n>\\X){0}")).matchSpan == 0 .. 4
    check search("aabc", re("(?y{w}:(?<n>a))\\g<n>\\X")).matchSpan == 0 .. 3
    # After a call that failed.
    check search("abcd ef", re("(?y{w}:(?:\\g<n>z|\\X))(?<n>\\X){0}")).matchSpan ==
      0 .. 4
    # Backtracking into the returned body runs it under its own mode again.
    check search("abcde", re("(?<n>\\X?\\X)(?y{w}:\\g<n>)d")).matchSpan == 0 .. 4

  test "only a call into another grapheme mode is wrapped":
    proc wrappers(n: Node): seq[GraphemeMode] =
      ## The mode of every flag group that holds a call and nothing else.
      if n.kind == nkFlagGroup and n.flagBody != nil and n.flagBody.kind == nkSubexpCall:
        result.add n.graphemeMode
      for c in n.childNodes:
        result.add wrappers(c)

    check wrappers(re("(?<n>a)\\g<n>").ast).len == 0
    check wrappers(re("(?y{g}:(?<n>a)\\g<n>)").ast).len == 0
    check wrappers(re("(?y{g}:(?<n>a))\\g<n>").ast) == @[gmGrapheme]
    check wrappers(re("(?<n>a)(?y{g}:b\\g<n>)").ast) == @[gmOff]
    check wrappers(re("(?y{g}:(?<n>a))(?y{w}:b\\g<n>)").ast) == @[gmGrapheme]
    # ``\g<0>`` enters under no mode, and a name called twice its first group.
    check wrappers(re("(?y{w}:q\\g<0>?)").ast) == @[gmOff]
    check wrappers(re("(?y{g}:(a))|q\\g<0>?").ast).len == 0
    check wrappers(re("(?<n>a)|(?y{g}:(?<n>b))|c\\g<n>").ast).len == 0
    # A repeat of a call keeps its target, wrapped or not.
    check search("aaa", re("(?y{g}:(?<n>a))\\g<n>{2}")).matchSpan == 0 .. 3

  test "a look-behind a call reaches keeps what the compiler marked on it":
    # A mode the look-behind was not measured under used to cost it the mark
    # that runs it without a window, and ``\b`` at a window's start holds where
    # the subject's does not: ``2 .. 2``, past the two letters.
    proc span(pattern: string): Span =
      search("ck ", re(pattern, {rfCaptureGroup})).matchSpan

    const body = "(?<=\\1\\b)"
    check span("()(?<n>" & body & ")\\g<n>") == 0 .. 0
    check span("()(?<n>" & body & ")(?y{g}:\\g<n>)") == 0 .. 0
    check span("()(?<n>" & body & ")(?y{w}:\\g<n>)") == 0 .. 0
    check span("(?y{g}:()(?<n>" & body & "))\\g<n>") == 0 .. 0
    check span("(?y{g}:()(?<n>" & body & "))(?y{w}:\\g<n>)") == 0 .. 0

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

  test "a greedy repeat of one character is the loop around an absent pattern":
    # Oniguruma runs the absent pattern in the repeat's own loop, so ``{0}``
    # never runs it, nor marks the groups its calls reach.  What its parser
    # makes of the expression counts: ``(?:a{0}){5}`` is ``a{0}``.
    for pattern in [
      "(?~|\\g<0>|a{0})", "(?~|\\g<0>|(?:a){0})", "(?~|\\g<0>|\\d{0})",
      "(?~|\\g<0>|[ab]{0})", "(?~|\\g<0>|(?:a{0}){5})", "(((?~|(\\g<3>)|a{0})))",
    ]:
      check search("x", re(pattern)).matchSpan == 0 .. 0
    # Two characters, a ``\w``, a lazy repeat or ``{1}`` are no such loop, and
    # neither is a group that captured while the pattern was parsed.
    for pattern in [
      "(?~|\\g<0>|(?:ab){0})", "(?~|\\g<0>|\\w{0})", "(?~|\\g<0>|a{0}?)",
      "(?~|\\g<0>|a{1})", "(?<n>(?~|\\g<n>|(a){0}))",
    ]:
      expect RegexError:
        discard re(pattern)
    # Oniguruma makes a ``\p{Word}`` outside ``[...]`` the node of ``\w``, in
    # any spelling and either sense; inside, it is a class.
    for pattern in [
      "(?~|\\g<0>|\\p{Word}{0})", "(?~|\\g<0>|\\p{^Word}{0})",
      "(?~|\\g<0>|\\P{Word}{0})", "(?~|\\g<0>|\\P{^Word}{0})",
      "(?~|\\g<0>|\\p{w_O-r d}{0})", "(a|(?~|\\g<0>|\\p{Word}{0}))",
    ]:
      expect RegexError:
        discard re(pattern)
    for pattern in [
      "(?~|\\g<0>|[\\p{Word}]{0})", "(?~|\\g<0>|[[:word:]]{0})",
      "(?~|\\g<0>|\\p{Alnum}{0})",
    ]:
      check search("x", re(pattern)).matchSpan == 0 .. 0
    # Nor is a ``[...]`` holding a character with a multi-character fold under
    # ``(?i)``, which Oniguruma's parser makes an alternation: ``[ß]|ss``.  A
    # negated class, ``\p{...}``, a literal and ``(?iI)`` take no such fold.
    for pattern in [
      "(?i)(?~|\\g<0>|[ß]{0})",
      "(?i)(?~|\\g<0>|[ẞ]{0})",
      "(?i)(?~|\\g<0>|[sﬁ]{0})",
      "(?i)(?~|\\g<0>|[\\p{Ll}]{0})",
      "(?i)(?~|\\g<0>|(?>[ß]{0}))",
      "(?i:(?~|\\g<0>|(?:[ß]){0}))",
      # Folds the matcher does not expand count too.
      "(?i)(?~|\\g<0>|[ᾀ]{0})",
      "(?i)(?~|\\g<0>|[ᾈ]{0})",
      "(?i)(?~|\\g<0>|[ﬓ]{0})",
      "(?i)(?~|\\g<0>|[\\p{Lt}]{0})",
    ]:
      expect RegexError:
        discard re(pattern)
    expect RegexError:
      discard re("(?~|\\g<0>|[ß]{0})", {rfIgnoreCase})
    for pattern in [
      "(?i)(?~|\\g<0>|[^ß]{0})", "(?i)(?~|\\g<0>|\\p{Ll}{0})", "(?i)(?~|\\g<0>|ß{0})",
      "(?iI)(?~|\\g<0>|[ß]{0})", "(?~|\\g<0>|[ß]{0})",
    ]:
      check search("x", re(pattern)).matchSpan == 0 .. 0
    check search("ax", re("(?i)a(?-i)(?~|\\g<0>|[ß]{0})")).matchSpan == 0 .. 1
    # Exact counts multiply only while Oniguruma's ``int`` holds the product.
    # Past it Oniguruma refuses the pattern, and here the pair stays as
    # written, so the expression is no loop and ``\g<0>`` is reached first.
    check not search("a", re("(?~|x|(?:(?:(?:a{100000}){100000}){100000}){100000})")).found
    expect RegexError:
      discard re("(?~|\\g<0>|(?:(?:a{100000}){100000}){0})")

  test "the matcher never runs the absent pattern a {0} loop holds either":
    # Accepted for that reason, its recursion never ends, so running it at
    # each position of a long subject only reached the step limit.  The spans
    # are libonig 6.9.10's.
    check search("a".repeat(20_000), re("(?~|a*\\g<0>|b{0})")).matchSpan == 0 .. 0
    check search("a".repeat(1000), re("(?~|(a*)\\g<1>?\\g<0>|b{0})")).matchSpan == 0 .. 0
    check search("a", re("(?~|(\\g<1>*+\\g<0>?+)?+|(?:a){0})")).matchSpan == 0 .. 0

  test "an absent pattern's length is worked out where Oniguruma walks it":
    # Group 1's length is being worked out when ``\1`` in the absent pattern
    # is measured, so group 3, a call to group 1, counts as empty from then
    # on, and ``\g<0>`` after it is reached before anything is consumed.
    expect RegexError:
      discard re("(?~(?~(?~\\1))|(a(\\3))|(\\g<1>)\\g<0>)")
    check search("aaa", re("(?~(?~(?~\\2))|(a(\\3))|(\\g<1>)\\g<0>)")).found

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
