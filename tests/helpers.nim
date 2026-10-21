## Helpers the test files share.  Not a test itself: ``nimble test`` runs only
## the files whose names start with ``t``.

import ../reni

proc compileError*(pattern: string): string =
  ## The message ``re`` raises for ``pattern``, or "" when it compiles.
  try:
    discard re(pattern)
  except RegexError as e:
    return e.msg
