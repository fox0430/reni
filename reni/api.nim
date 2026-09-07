## High-level public API for the reni regex engine.
##
## This module is the user-facing entry point re-exported from ``reni``.
## It wraps the low-level matcher in ``engine`` with the documented
## operations: ``search`` / ``searchBackward`` / ``matchAt`` to run a
## pattern against a subject, ``matchSpan`` / ``captureSpan`` /
## ``captureText`` / ``captured`` / ``groupCount`` / ``captureIndex`` to
## inspect ``Match`` results (including named groups), the ``findAll``
## iterator, string / callback ``replace`` (with ``$0``-``$N``, ``${name}``,
## ``$$`` substitutions), and ``split``.
##
## All matching procs accept ``stepLimit`` and ``maxRecursionDepth``
## parameters for ReDoS protection; out-of-range indices raise
## ``ValueError`` and invalid replacement references raise ``RegexError``.

import std/options

import types, engine

export MatchContext, newMatchContext

proc searchIntoCtx*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): bool {.discardable.} =
  ## Allocation-reusing search.  Writes the result into ``m`` and reuses
  ## ``ctx``'s scratch buffers, so after the first call the matcher itself
  ## allocates nothing.  ``ctx`` must not be shared across threads.
  ##
  ## Returns ``m.found`` for ``if searchIntoCtx(...): ...`` usage.
  if start < 0 or start > subject.len:
    raise newException(ValueError, "start index out of range: " & $start)
  searchImplInto(
    ctx,
    subject,
    regex,
    m,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )
  m.found

proc searchBackwardIntoCtx*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): bool {.discardable.} =
  ## In-place variant of ``searchBackward``.  See ``searchIntoCtx`` for
  ## the allocation-reuse contract.
  ##
  ## ``start = -1`` means "scan from the end of ``subject``"; any other
  ## negative value or ``start > subject.len`` raises ``ValueError``.
  if start < -1 or start > subject.len:
    raise newException(ValueError, "start index out of range: " & $start)
  searchBackwardImplInto(
    ctx,
    subject,
    regex,
    m,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )
  m.found

proc matchAtIntoCtx*(
    ctx: MatchContext,
    subject: string,
    regex: Regex,
    m: var Match,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): bool {.discardable.} =
  ## In-place variant of ``matchAt``.  See ``searchIntoCtx`` for the
  ## allocation-reuse contract.
  if pos < 0 or pos > subject.len:
    raise newException(ValueError, "pos index out of range: " & $pos)
  matchAtImplInto(
    ctx,
    subject,
    regex,
    m,
    pos = pos,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )
  m.found

proc search*(
    subject: string,
    regex: Regex,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  if start < 0 or start > subject.len:
    raise newException(ValueError, "start index out of range: " & $start)
  searchImpl(
    subject,
    regex,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc searchBackward*(
    subject: string,
    regex: Regex,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Search backward from the end (or from `start` if >= 0).
  ##
  ## ``start = -1`` means "scan from the end of ``subject``"; any other
  ## negative value or ``start > subject.len`` raises ``ValueError``.
  if start < -1 or start > subject.len:
    raise newException(ValueError, "start index out of range: " & $start)
  searchBackwardImpl(
    subject,
    regex,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc matchAt*(
    subject: string,
    regex: Regex,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Try to match only at the given position (no forward scanning).
  if pos < 0 or pos > subject.len:
    raise newException(ValueError, "pos index out of range: " & $pos)
  matchAtImpl(
    subject,
    regex,
    pos = pos,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc matchSpan*(m: Match): Span {.inline.} =
  ## Get the overall match span [a, b).
  ## Returns ``UnsetSpan`` when ``m.found`` is false.
  if not m.found or m.boundaries.len == 0:
    return UnsetSpan
  m.boundaries[0]

proc captureSpan*(m: Match, group: int): Span {.inline.} =
  ## Get the span of a capture group (1-indexed). Unset groups have ``a < 0``.
  ## Returns ``UnsetSpan`` when the group index is out of range.
  if group < 0 or group >= m.boundaries.len:
    return UnsetSpan
  m.boundaries[group]

proc groupCount*(m: Match): int {.inline.} =
  ## Number of capture groups (excluding the overall match).
  max(0, m.boundaries.len - 1)

proc captured*(m: Match, group: int): bool =
  ## Check whether a capture group participated in the match.
  m.found and group >= 0 and group < m.boundaries.len and m.boundaries[group].a >= 0

proc captureText*(m: Match, group: int, subject: string): Option[string] =
  ## Get the text of a capture group.
  ## Returns ``none(string)`` when the group did not participate in the match.
  if not m.found or group < 0 or group >= m.boundaries.len:
    return none(string)
  let b = m.boundaries[group]
  if b.a < 0:
    return none(string)
  some(subject[b.a ..< b.b]) # b.b is exclusive

proc captureIndex*(regex: Regex, name: string): int =
  ## Get the index of a named capture group. Returns -1 if not found.
  for (n, idx) in regex.namedCaptures:
    if n == name:
      return idx + 1 # boundaries are 1-indexed for groups
  -1

proc captured*(m: Match, name: string, regex: Regex): bool =
  ## Check whether a named capture group participated in the match.
  let idx = captureIndex(regex, name)
  if idx < 0:
    return false
  captured(m, idx)

proc captureText*(
    m: Match, name: string, subject: string, regex: Regex
): Option[string] =
  ## Get the text of a named capture group.
  ## Returns ``none(string)`` when the group did not participate in the match.
  let idx = captureIndex(regex, name)
  if idx < 0:
    return none(string)
  captureText(m, idx, subject)

proc nextRunePos*(subject: string, pos: int): int =
  ## Advance past one character. Returns the byte offset after it.
  ##
  ## Uses the same length rule as the scan loops, so the positions
  ## ``findAll`` / ``replace`` / ``split`` step to after a zero-width match
  ## are exactly the positions ``search`` starts an attempt at.
  ##
  ## The step never leaves the subject: a sequence truncated by the end
  ## declares more bytes than are there, and stepping past ``subject.len``
  ## would skip the end position — which is a start position the scan does
  ## visit — and hand a caller an out-of-range slice bound.
  ##
  ## At ``pos == subject.len`` there is no character to advance past, and the
  ## result is ``pos + 1``: one past the end, which ends a scan.
  if pos >= subject.len:
    pos + 1
  else:
    min(pos + encLen(subject[pos].uint8), subject.len)

proc advanceAfterMatch*(subject: string, matchSpan: Span): int {.inline.} =
  ## Return next search position after the match spanning ``matchSpan``.
  ## For zero-width matches, advance by one rune to avoid infinite loop.
  ## Returns -1 to signal that iteration should stop.
  ##
  ## Zero width is ``matchSpan.b == matchSpan.a``, not "the match ended where
  ## the scan began": a zero-width match found past the scan start would
  ## otherwise resume the scan at the position it was just found at and be
  ## yielded a second time.
  ##
  ## The span is taken whole rather than as two ``int`` parameters so that a
  ## caller written against an older argument order fails to compile instead
  ## of silently iterating differently.
  if matchSpan.b == matchSpan.a:
    if matchSpan.a < subject.len:
      nextRunePos(subject, matchSpan.a)
    else:
      -1
  else:
    matchSpan.b

iterator findAll*(
    subject: string,
    regex: Regex,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Yield all non-overlapping matches from left to right.
  var pos = 0
  while pos <= subject.len:
    let m = searchImpl(
      subject,
      regex,
      start = pos,
      stepLimit = stepLimit,
      maxRecursionDepth = maxRecursionDepth,
    )
    if not m.found:
      break
    yield m
    let nextPos = advanceAfterMatch(subject, m.boundaries[0])
    if nextPos < 0:
      break
    pos = nextPos

proc replace*(
    subject: string,
    regex: Regex,
    repl: string,
    count: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): string =
  ## Replace matches with `repl`. Supports $0, $1...$99+, ${name}, $$.
  ## Multi-digit group refs are greedy: $12 means group 12, not group 1 + "2".
  ## Use ${1}2 for group 1 followed by literal "2". count=0 means replace all.
  result = ""
  var pos = 0
  var replaced = 0
  var m: Match
  let ctx = newMatchContext(regex.captureCount)
  while pos <= subject.len:
    searchImplInto(
      ctx,
      subject,
      regex,
      m,
      start = pos,
      stepLimit = stepLimit,
      maxRecursionDepth = maxRecursionDepth,
    )
    if not m.found:
      result.add subject[pos ..< subject.len]
      break
    let matchStart = m.boundaries[0].a
    let matchEnd = m.boundaries[0].b
    result.add subject[pos ..< matchStart]
    # Process replacement string
    var i = 0
    while i < repl.len:
      if repl[i] == '$' and i + 1 < repl.len:
        i += 1
        if repl[i] == '$':
          result.add '$'
          i += 1
        elif repl[i] in {'0' .. '9'}:
          var n = ord(repl[i]) - ord('0')
          i += 1
          # Support multi-digit: $12 etc.
          while i < repl.len and repl[i] in {'0' .. '9'}:
            n = n * 10 + ord(repl[i]) - ord('0')
            i += 1
          if n > regex.captureCount:
            raise
              newException(RegexError, "invalid replacement reference '$" & $n & "'")
          # Group exists but may not have participated — empty string is correct.
          result.add captureText(m, n, subject).get("")
        elif repl[i] == '{':
          i += 1
          var name = ""
          while i < repl.len and repl[i] != '}':
            name.add repl[i]
            i += 1
          if i >= repl.len:
            raise newException(ValueError, "unterminated ${...} in replacement string")
          i += 1 # skip }
          let idx = captureIndex(regex, name)
          if idx < 0:
            raise newException(
              RegexError, "invalid replacement reference '${" & name & "}'"
            )
          result.add captureText(m, idx, subject).get("")
        else:
          result.add '$'
          result.add repl[i]
          i += 1
      else:
        result.add repl[i]
        i += 1
    inc replaced
    if count > 0 and replaced >= count:
      result.add subject[matchEnd ..< subject.len]
      break
    let nextPos = advanceAfterMatch(subject, Span(a: matchStart, b: matchEnd))
    if nextPos < 0:
      break
    if matchEnd == matchStart:
      # Zero-width match: copy the skipped character to output.  Everything
      # before the match is already in ``result``, so this starts at the
      # match, which is not always where the scan started.
      result.add subject[matchStart ..< nextPos]
    pos = nextPos

proc replace*(
    subject: string,
    regex: Regex,
    fn: proc(m: Match, s: string): string,
    count: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): string =
  ## Replace matches using a callback function.
  result = ""
  var pos = 0
  var replaced = 0
  var m: Match
  let ctx = newMatchContext(regex.captureCount)
  while pos <= subject.len:
    searchImplInto(
      ctx,
      subject,
      regex,
      m,
      start = pos,
      stepLimit = stepLimit,
      maxRecursionDepth = maxRecursionDepth,
    )
    if not m.found:
      result.add subject[pos ..< subject.len]
      break
    let matchStart = m.boundaries[0].a
    let matchEnd = m.boundaries[0].b
    result.add subject[pos ..< matchStart]
    result.add fn(m, subject)
    inc replaced
    if count > 0 and replaced >= count:
      result.add subject[matchEnd ..< subject.len]
      break
    let nextPos = advanceAfterMatch(subject, Span(a: matchStart, b: matchEnd))
    if nextPos < 0:
      break
    if matchEnd == matchStart:
      # Zero-width match: copy the skipped character to output.  Everything
      # before the match is already in ``result``, so this starts at the
      # match, which is not always where the scan started.
      result.add subject[matchStart ..< nextPos]
    pos = nextPos

proc split*(
    subject: string,
    regex: Regex,
    maxSplit: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): seq[string] =
  ## Split subject by regex matches.
  result = @[]
  # ``pos`` is where the next field starts, ``scanPos`` where the next search
  # does.  They part company after a zero-width match: the scan has to step
  # over a character to make progress, but that character is not a separator
  # and belongs to the field that follows.
  var pos = 0
  var scanPos = 0
  var splits = 0
  var m: Match
  let ctx = newMatchContext(regex.captureCount)
  while scanPos <= subject.len:
    if maxSplit > 0 and splits >= maxSplit:
      break
    searchImplInto(
      ctx,
      subject,
      regex,
      m,
      start = scanPos,
      stepLimit = stepLimit,
      maxRecursionDepth = maxRecursionDepth,
    )
    if not m.found:
      break
    let matchStart = m.boundaries[0].a
    let matchEnd = m.boundaries[0].b
    result.add subject[pos ..< matchStart]
    # Add capture groups to result (like Python re.split)
    for i in 1 ..< m.boundaries.len:
      let b = m.boundaries[i]
      if b.a >= 0:
        result.add subject[b.a ..< b.b]
      else:
        result.add ""
    inc splits
    pos = matchEnd
    let nextPos = advanceAfterMatch(subject, Span(a: matchStart, b: matchEnd))
    if nextPos < 0:
      break
    scanPos = nextPos
  result.add subject[pos ..< subject.len]
