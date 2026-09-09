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
      # would pass on either one. What this pins is that the level cap, not
      # the byte guard, is what rejects a pattern this deep.
      when compileOption("exceptions", "setjmp"):
        # 300 parser levels cost past 1 MiB under setjmp (see the test above),
        # so the byte guard fires before the 256 level cap is reached. Still
        # a catchable error, never an overflow.
        expect RegexLimitError:
          discard re(tooDeep)
      else:
        var sawLevelCap = false
        try:
          discard re(tooDeep)
        except RegexLimitError:
          discard
        except RegexError as e:
          sawLevelCap = "nesting too deep" in e.msg
        check sawLevelCap
