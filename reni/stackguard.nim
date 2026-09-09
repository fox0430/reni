## Native-stack budget shared by the parser and the matcher.
## Both recurse over nested patterns, so both measure consumed bytes
## against the same budget instead of guessing a per-level cost.

const MaxStackBytes* {.intdefine: "reniMaxStackBytes".} = 1024 * 1024
  ## Max native-stack bytes one parse or match may consume.
  ##
  ## Measures bytes, not levels: per-level cost varies with exceptions
  ## model, optimization, and node kinds, so level counting is unreliable.
  ##
  ## Default is half of a 2 MiB worker thread; the rest covers frames outside
  ## the counted recursion. Exceeding it raises catchable ``RegexLimitError``.
  ## A parse and a match never run at once, so they share one budget.
  ##
  ## Override with ``-d:reniMaxStackBytes=N``. Keep it at most half of the
  ## real thread stack: past depth 16 the matcher samples every 16 levels,
  ## so up to 15 levels can overshoot before the next reading.

static:
  doAssert MaxStackBytes >= 16 * 1024,
    "-d:reniMaxStackBytes must be at least 16 KiB; below that a single " &
      "setjmp-model recursion level (~11.9 KB) can consume the whole budget " &
      "and no pattern matches"

const StackProbeInterval* = 16
  ## Levels between stack measurements past depth 16. The first 16 levels
  ## are measured every level; afterwards sampling amortizes the read cost
  ## at the price of up to 15 levels of overshoot (see ``MaxStackBytes``).

static:
  doAssert (StackProbeInterval and (StackProbeInterval - 1)) == 0,
    "StackProbeInterval must be a power of two; the hot path tests it with AND"

when defined(gcc) or defined(clang):
  proc builtinFrameAddress(
    level: cint
  ): pointer {.importc: "__builtin_frame_address", nodecl.}

  template currentStackAddr*(): int =
    ## Calling frame address via builtin; avoids the cost of an out-of-line call.
    cast[int](builtinFrameAddress(0))

else:
  template currentStackAddr*(): int =
    ## Portable fallback for compilers without ``__builtin_frame_address``.
    var probe {.noinit.}: int
    cast[int](addr probe)

template stackUsedFrom*(base: int): int =
  ## Stack bytes consumed since ``base``. Uses ``abs`` for either growth direction.
  abs(currentStackAddr() - base)
