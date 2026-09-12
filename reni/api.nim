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

proc advanceAfterMatch*(
    subject: string, matchSpan: Span
): int {.inline, deprecated: "drive a reni scan with MatchScanner".} =
  ## Return the next search position after a match spanning ``matchSpan``.
  ## For a zero-width match, advance by one rune to avoid an infinite loop.
  ## Returns -1 to signal that iteration should stop.
  ##
  ## **Deprecated.**  This rule assumes a match reports exactly what it
  ## consumed, which holds for every pattern without a ``\K``.  With one,
  ## progress and repetition need separate spans, and a ``\K`` inside a
  ## lookbehind reports a span this loop resumes inside and never ends.
  ## Drive a ``reni`` scan with ``MatchScanner`` instead.
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

proc consumedSpan*(m: Match): Span {.inline.} =
  ## What the attempt behind ``m`` ran over: from the position it started at
  ## to where the match ended.  See ``Match.startChar``.
  ##
  ## Returns ``UnsetSpan`` when ``m.found`` is false, the way ``matchSpan``
  ## does, rather than an ``IndexDefect``.
  if not m.found or m.boundaries.len == 0:
    return UnsetSpan
  Span(a: m.startChar, b: m.boundaries[0].b)

type MatchScanner* = object
  ## Cursor for a left-to-right scan over one subject: what ``findAll``,
  ## ``replace`` and ``split`` run on, and what a caller running its own scan
  ## should run on too.
  ##
  ## A ``\K`` makes the span a match *reports* differ from the one its attempt
  ## *consumed*, and a scan needs both:
  ##
  ## - **Progress** comes from the consumed span.  An attempt that ran over
  ##   text resumes at its end even when its report is empty (``a\K``); one
  ##   that consumed nothing steps a character even when its report is wide (a
  ##   ``\K`` inside a lookbehind reports text behind the scan position).
  ## - **Repetition** comes from the reported span.  ``a*\K`` reports the same
  ##   empty span again from the attempt that resumes where it sat; a scan
  ##   yields that span once, keeping the first match whole.  Captures are not
  ##   part of the key: ``(a*)\K`` over ``"aa"`` reports the empty span at 2
  ##   twice with different captures, and yielding it twice would replace twice
  ##   at one position.
  ##
  ## Stepping on the consumed span is where this scan parts company with
  ## Oniguruma's, which steps on the report because an ovector leaves a caller
  ## no way not to: over ``"aa"``, ``a\K`` answers twice here and once in Ruby,
  ## and a scan of ``(?<=\Ka)`` ends here and runs forever there.  Patterns
  ## without a ``\K`` report what they consumed and cannot tell the two rules
  ## apart.
  ##
  ## Both cursors belong to the scanner: ``scanNext`` moves the scan, ``takeGap``
  ## and ``takeTail`` move the output.  They part company after a match that
  ## consumed nothing, whose stepped-over character belongs to the output.
  ## ``findAll`` has no output and never asks for the gap.
  ##
  ## The cursors are byte offsets into one subject.  The scanner keeps that
  ## subject's length and raises on a string of a different one; it does not
  ## keep the subject itself, so another string of the same length is not told
  ## apart.  The check is a guard against the mistake, not a proof.
  subjectLen: int ## Length of the subject the cursors point into.
  scanPos: int ## Where the next attempt starts.
  outPos: int ## Where the subject text not yet written out begins.
  prevReported: Span ## Reported span of the last yielded match, or unset.
  finished: bool ## Whether the scan has run off the end of the subject.
  stepLimit: int ## Step limit every attempt of this scan runs under.
  maxRecursionDepth: int ## Recursion limit every attempt runs under.

proc initMatchScanner*(
    subject: string,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): MatchScanner {.inline.} =
  ## A scanner over ``subject``, positioned at ``start``, before the first
  ## match.  A ``start`` outside ``subject`` raises ``ValueError`` here rather
  ## than ending the scan later with the empty answer an exhausted scan also
  ## gives.  The limits belong to the scan, so two attempts of one scan cannot
  ## run under different ones.
  if start < 0 or start > subject.len:
    raise newException(ValueError, "start index out of range: " & $start)
  MatchScanner(
    subjectLen: subject.len,
    scanPos: start,
    outPos: start,
    prevReported: UnsetSpan,
    stepLimit: stepLimit,
    maxRecursionDepth: maxRecursionDepth,
  )

proc scanPos*(sc: MatchScanner): int {.inline.} =
  ## Where the next attempt will start.  A yielded match is stepped past before
  ## ``scanNext`` hands it over, so this reads past the match a caller is
  ## holding.
  ##
  ## Read-only: the scanner moves its own cursor.  A loop that wants to carry
  ## on elsewhere in the subject starts a second scanner there.
  sc.scanPos

proc advancePast(
    sc: var MatchScanner, subject: string, consumed: Span, stepOver: bool
): bool {.inline.} =
  ## Move ``scanPos`` past an attempt that ran over ``consumed``.
  ## ``stepOver`` forces the one-character step an attempt consuming nothing
  ## needs anyway; a suppressed repeat asks for it, since its end is where the
  ## scan already stands.  Returns false when the scan has run off the subject.
  ##
  ## The span is passed in rather than kept on the scanner, so there is no
  ## second copy of it to get out of step with ``scanPos``.
  if stepOver or consumed.b == consumed.a:
    if consumed.b >= subject.len:
      # Nothing left to step onto: end at the end of the subject, not back
      # where this attempt began, which is already answered from.
      sc.scanPos = subject.len
      return false
    sc.scanPos = nextRunePos(subject, consumed.b)
  else:
    sc.scanPos = consumed.b
  sc.scanPos <= subject.len

proc checkSubject(sc: MatchScanner, subject: string) {.inline.} =
  if subject.len != sc.subjectLen:
    raise newException(
      ValueError,
      "scanner is bound to a subject of " & $sc.subjectLen & " bytes, not " &
        $subject.len,
    )

proc scanNext*(
    sc: var MatchScanner, ctx: MatchContext, subject: string, regex: Regex, m: var Match
): bool =
  ## Write the next match of the scan into ``m`` and report whether there was
  ## one.  Advances past the previous match first, so the loop around it is
  ## ``while scanNext(sc, ...): <use m>`` with no cursor arithmetic of its own.
  ##
  ## A match whose reported span repeats the previous one is stepped past
  ## rather than handed back.
  ##
  ## ``subject`` must be the string the scanner was initialized over: one of a
  ## different length raises ``ValueError``, one of the same length is not told
  ## apart -- see ``MatchScanner``.
  sc.checkSubject(subject)
  while not sc.finished and sc.scanPos <= subject.len:
    searchImplInto(
      ctx,
      subject,
      regex,
      m,
      start = sc.scanPos,
      stepLimit = sc.stepLimit,
      maxRecursionDepth = sc.maxRecursionDepth,
    )
    if not m.found:
      sc.finished = true
      return false
    let consumed = consumedSpan(m)
    # One step of memory is enough: reported ends never decrease over a scan,
    # so an answer left behind cannot come back.  The span alone is the key --
    # telling two attempts over it apart by their captures would yield it
    # twice, which is two replacements at one position.
    if m.boundaries[0] == sc.prevReported:
      if not sc.advancePast(subject, consumed, stepOver = true):
        sc.finished = true
        return false
      continue
    sc.prevReported = m.boundaries[0]
    # Step past this match now rather than at the top of the next call, so
    # ``scanPos`` is true while the caller still holds the match.  Running off
    # the subject here ends the scan; this match is still handed over.
    if not sc.advancePast(subject, consumed, stepOver = false):
      sc.finished = true
    return true
  false

proc takeGap*(sc: var MatchScanner, m: Match): Span =
  ## The run of subject text before ``m`` that no match covered; the output
  ## cursor moves past what ``m`` reports, so a replacing loop writes this span,
  ## then the replacement, and owes the cursor nothing.
  ##
  ## The gap ends at the *reported* start, so a plain ``\K`` leaves what it
  ## dropped in the output.  Inside a lookbehind that start can sit behind text
  ## already written out; the gap is clamped at the output cursor, so a match
  ## only ever replaces what is left.
  ##
  ## A match that is not there covers nothing and moves nothing: the answer is
  ## the empty span at the cursor.
  if not m.found or m.boundaries.len == 0:
    return Span(a: sc.outPos, b: sc.outPos)
  let reported = m.boundaries[0]
  result = Span(a: sc.outPos, b: max(reported.a, sc.outPos))
  sc.outPos = max(sc.outPos, reported.b)

proc takeTail*(sc: var MatchScanner, subject: string): Span =
  ## Everything the scan left behind: the text after the last match, and
  ## whatever a match that consumed nothing made it step over.  The cursor ends
  ## at the end of the subject, so asking twice answers empty the second time.
  sc.checkSubject(subject)
  result = Span(a: min(sc.outPos, subject.len), b: subject.len)
  sc.outPos = subject.len

iterator findAll*(
    subject: string,
    regex: Regex,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Yield the matches of a left-to-right scan.
  ##
  ## The scan never stands still and never repeats an answer, but the spans it
  ## yields stay non-overlapping only without a ``\K``: inside a lookbehind one
  ## reports text behind the position the scan stands at.  What the attempts
  ## consumed does not overlap -- see ``Match.startChar``.
  ##
  ## Every attempt that can still make progress is reached, which over a
  ## trailing ``\K`` is further than Oniguruma's own scan reaches: ``a\K`` over
  ## ``"aa"`` yields twice here and once in Ruby.  See ``MatchScanner``.
  var sc = initMatchScanner(
    subject, stepLimit = stepLimit, maxRecursionDepth = maxRecursionDepth
  )
  let ctx = newMatchContext(regex.captureCount)
  var m: Match
  while scanNext(sc, ctx, subject, regex, m):
    yield m

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
  ##
  ## A match replaces what it *reports*, so a ``\K`` leaves what it dropped in
  ## the output.  Where two reports overlap, subject text still passes into the
  ## output once and in order: the earlier replacement stands and the later one
  ## replaces the rest.  The replacement text is not bound by that -- ``$0``
  ## writes what the report covers, which across an overlap is text already
  ## written, so there the identity replacement is not the identity:
  ## ``replace("abcabcabc", re("c(?<=\\Kabcabc)"), "$0")`` answers
  ## ``"abcabcabcabc"``.
  ##
  ## A pattern reporting less than it consumed replaces at more positions than
  ## Ruby's ``gsub``, which scans by the reported end:
  ## ``replace("aa", re("a\\K"), "-")`` answers ``"a-a-"`` where ``gsub``
  ## answers ``"a-a"``.  See ``MatchScanner``.
  result = ""
  var sc = initMatchScanner(
    subject, stepLimit = stepLimit, maxRecursionDepth = maxRecursionDepth
  )
  var replaced = 0
  var m: Match
  let ctx = newMatchContext(regex.captureCount)
  while scanNext(sc, ctx, subject, regex, m):
    let gap = sc.takeGap(m)
    result.add subject[gap.a ..< gap.b]
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
      break
  let tail = sc.takeTail(subject)
  result.add subject[tail.a ..< tail.b]

proc replace*(
    subject: string,
    regex: Regex,
    fn: proc(m: Match, s: string): string,
    count: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): string =
  ## Replace matches using a callback function.  The output rule is the one
  ## the template ``replace`` above states.
  result = ""
  var sc = initMatchScanner(
    subject, stepLimit = stepLimit, maxRecursionDepth = maxRecursionDepth
  )
  var replaced = 0
  var m: Match
  let ctx = newMatchContext(regex.captureCount)
  while scanNext(sc, ctx, subject, regex, m):
    let gap = sc.takeGap(m)
    result.add subject[gap.a ..< gap.b]
    result.add fn(m, subject)
    inc replaced
    if count > 0 and replaced >= count:
      break
  let tail = sc.takeTail(subject)
  result.add subject[tail.a ..< tail.b]

proc split*(
    subject: string,
    regex: Regex,
    maxSplit: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): seq[string] =
  ## Split subject by regex matches.
  ##
  ## A separator is what the match *reports*, so a ``\K`` leaves what it
  ## dropped in the field before it.  Where a report reaches back over a field
  ## already taken, that field stands and the next one starts after the
  ## separator: the fields, plus the text the separators removed, reconstruct
  ## the subject.  What the separators *report* can be more than that text,
  ## since two reports can overlap --
  ## ``split("abcabcabc", re("c(?<=\\Kabcabc)"))`` answers three empty fields
  ## with separators reported at ``0 .. 6`` and ``3 .. 9``.
  result = @[]
  var sc = initMatchScanner(
    subject, stepLimit = stepLimit, maxRecursionDepth = maxRecursionDepth
  )
  var splits = 0
  var m: Match
  let ctx = newMatchContext(regex.captureCount)
  while maxSplit <= 0 or splits < maxSplit:
    if not scanNext(sc, ctx, subject, regex, m):
      break
    let gap = sc.takeGap(m)
    result.add subject[gap.a ..< gap.b]
    # Add capture groups to result (like Python re.split)
    for i in 1 ..< m.boundaries.len:
      let b = m.boundaries[i]
      if b.a >= 0:
        result.add subject[b.a ..< b.b]
      else:
        result.add ""
    inc splits
  let tail = sc.takeTail(subject)
  result.add subject[tail.a ..< tail.b]
