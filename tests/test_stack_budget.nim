import std/[unittest, strutils]

import ../reni
import ../reni/engine

suite "the parser measures the same stack budget the matcher does":
  test "deep nesting is answered, never overflowed":
    # 255 nested lookaheads is inside ``MaxNestingDepth`` but not inside every
    # stack: the same pattern parses in well under 256 KiB with goto
    # exceptions under ORC and needs more than 1 MiB with setjmp, which is a
    # segfault on the 2 MiB worker thread the budget is sized for. The level
    # cap cannot tell those apart; the byte budget can.
    let deep = "(?=".repeat(255) & "a" & ")".repeat(255)
    when engine.MaxStackBytes <= 64 * 1024:
      # A budget this small cannot hold 255 parser levels in any model, so the
      # guard is what must stop it -- the level cap allows 256.
      expect RegexLimitError:
        discard re(deep)
    else:
      # With a real budget, whether 255 levels fit depends on the exception
      # model and the memory model: a level costs a few hundred bytes under
      # goto exceptions and much more under setjmp. That is exactly why the
      # guard counts bytes and not levels, and why this pins the property
      # rather than one build's outcome -- the answer is a value or a
      # catchable error, never an overflow.
      var answered = false
      try:
        answered = search("a", re(deep)).found
      except RegexLimitError:
        answered = true
      check answered

  test "the level cap still reports a parse error, not a resource one":
    let tooDeep = "(?:".repeat(300) & "a" & ")".repeat(300)
    when engine.MaxStackBytes <= 64 * 1024:
      # A budget this small runs out before the 300th level is reached, so the
      # resource error is the right answer here and there is nothing to tell
      # apart.
      expect RegexLimitError:
        discard re(tooDeep)
    else:
      # ``RegexLimitError`` is a ``RegexError``, so ``expect RegexError``
      # would pass on either one. What this pins is *which* of the two
      # rejects a pattern this deep, so each build names its own answer.
      var sawLevelCap = false
      var sawByteGuard = false
      try:
        discard re(tooDeep)
      except RegexLimitError:
        sawByteGuard = true
      except RegexError as e:
        sawLevelCap = "nesting too deep" in e.msg
      when compileOption("exceptions", "setjmp") and defined(gcDestructors):
        # A level costs much more under setjmp (see the test above), so the
        # frame size decides which guard answers first. Under ``orc`` the
        # parser runs past the byte budget before the 300th level -- which is
        # the whole reason the guard counts bytes.
        check sawByteGuard
      else:
        # Every other build leaves a level small enough to reach the cap
        # first: goto exceptions spend a few hundred bytes on one, and
        # ``refc`` frames carry no destructor bookkeeping.
        check sawLevelCap

suite "the compiler's walks that follow calls measure the same stack budget":
  test "a ring of calls is answered, never overflowed":
    # Each group calls the next and the last calls the first, so checking one
    # walks the whole ring: 30,000 groups, far past the default budget.
    var ring = ""
    for i in 1 .. 30_000:
      ring.add "(a\\g<" & $(i mod 30_000 + 1) & ">?)"
    expect RegexLimitError:
      discard re(ring)

  test "an open chain of calls is marked without recursion":
    # No group here runs itself again, so none is walked, but finding that out
    # follows the chain, 100,000 calls long.
    var chain = ""
    for i in 1 ..< 100_000:
      chain.add "(a\\g<" & $(i + 1) & ">?)"
    chain.add "(a)"
    check re(chain).captureCount == 100_000

  test "a look-behind's call down a chain is answered, never overflowed":
    # The group a look-behind calls is searched for absent operators through
    # each call in turn, from a list, then measured through them, which runs
    # past the budget: 100,000 groups.
    var chain = "(?<=\\g<1>)"
    for i in 1 ..< 100_000:
      chain.add "(a\\g<" & $(i + 1) & ">?)"
    chain.add "(a)"
    expect RegexLimitError:
      discard re(chain)

  test "a repeat's body measured down a chain is answered, never overflowed":
    # A backreference has the empty check measure every repeat's body, here
    # through the 100,000 groups each one calls in turn.
    var chain = ""
    for i in 1 ..< 100_000:
      chain.add "(a\\g<" & $(i + 1) & ">*)"
    chain.add "(a)\\1"
    expect RegexLimitError:
      discard re(chain)
