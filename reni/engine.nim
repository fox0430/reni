## Backtracking regex matching engine.
## Uses closure-based continuation passing for correct backtracking
## through alternations, quantifiers, and flag groups.

import std/[unicode, tables]

import pkg/unicodedb/casing

import types, unicode_utils

type
  MatchContext = object
    subject: string
    pos: int
    flags: RegexFlags
    captures: seq[Span]
    searchStart: int
    keepStart: int
    regex: Regex
    subjectEnd: int ## effective end of subject (for absent expression limiting)
    recursionDepth: int ## for detecting never-ending recursion
    captureStacks: seq[seq[Span]]
      ## per-group capture history for recursion-level backrefs
    groupRecursionDepth: seq[int] ## per-group recursion depth counter
    steps: int ## match step counter for ReDoS protection
    graphemeMode: GraphemeMode ## current grapheme mode from (?y{g}) or (?y{w})
    stepLimit: int ## max steps allowed (0 = unlimited)
    maxRecursionDepth: int ## max subexpression recursion depth
    calloutCounters: Table[string, int] ## (*COUNT) / (*MAX) tag counters
    callDepth: int ## matchWithCont recursion depth for stack overflow protection

  MatchCont = proc(ctx: var MatchContext): bool {.closure.}

  SavedState = object
    pos: int
    captures: seq[Span]
    flags: RegexFlags
    keepStart: int
    subjectEnd: int
    graphemeMode: GraphemeMode

const MaxQuantRepetitions = 10_000
const MaxCallDepth* = 400
  ## Guard against stack overflow. Each concat node uses ~4 real call frames
  ## (matchWithCont + matchSeqCont + matchLiteral + closure), so this must be
  ## well below Nim's debug call depth limit (2000) to catch deep recursion.

# Forward declarations
proc matchWithCont(ctx: var MatchContext, node: Node, cont: MatchCont): bool

proc trueCont(ctx: var MatchContext): bool =
  true

proc save(ctx: MatchContext): SavedState =
  SavedState(
    pos: ctx.pos,
    captures: ctx.captures,
    flags: ctx.flags,
    keepStart: ctx.keepStart,
    subjectEnd: ctx.subjectEnd,
    graphemeMode: ctx.graphemeMode,
  )

proc restore(ctx: var MatchContext, s: SavedState) =
  ctx.pos = s.pos
  ctx.captures = s.captures
  ctx.flags = s.flags
  ctx.keepStart = s.keepStart
  ctx.subjectEnd = s.subjectEnd
  ctx.graphemeMode = s.graphemeMode

proc getNodeRune(node: Node): (bool, Rune) =
  ## Extract the rune from a literal node.
  if node.kind == nkLiteral:
    (true, node.rune)
  elif node.kind == nkEscapedLiteral:
    (true, node.escapedRune)
  else:
    (false, Rune(0))

proc matchSeqCont(
    ctx: var MatchContext, nodes: seq[Node], idx: int, cont: MatchCont
): bool =
  if idx >= nodes.len:
    return cont(ctx)
  # Handle absent range markers in sequence
  let node = nodes[idx]
  if node.kind == nkAbsent and node.absentKind == abRange:
    # (?~|absent) - limit matching range to exclude absent
    let rangeStart = ctx.pos
    let absentBody = node.absentBody
    # Find first position where absent matches
    var absentPos = ctx.subjectEnd
    block findAbsent:
      var checkPos = rangeStart
      while checkPos < ctx.subjectEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if matchWithCont(ctx, absentBody, trueCont):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.subjectEnd:
          break
        var r: Rune
        fastRuneAt(ctx.subject, checkPos, r, true)
    ctx.pos = rangeStart
    let savedEnd = ctx.subjectEnd
    ctx.subjectEnd = absentPos
    let restoreCont = proc(ctx: var MatchContext): bool =
      ctx.subjectEnd = savedEnd
      let ok = cont(ctx)
      if not ok:
        ctx.subjectEnd = absentPos
      ok
    let ok = matchSeqCont(ctx, nodes, idx + 1, restoreCont)
    ctx.subjectEnd = savedEnd
    return ok
  if node.kind == nkAbsent and node.absentKind == abClear:
    # (?~|) or (?~) in sequence - restore subject end (clear absent range limit)
    ctx.subjectEnd = ctx.subject.len
    return matchSeqCont(ctx, nodes, idx + 1, cont)
  # Multi-char fold: subject char folds to match consecutive pattern literals
  # e.g., subject "ß" matching pattern "ss"
  if rfIgnoreCase in ctx.flags and ctx.pos < ctx.subjectEnd and idx + 1 < nodes.len:
    let (isLit1, r1) = getNodeRune(nodes[idx])
    let (isLit2, r2) = getNodeRune(nodes[idx + 1])
    if isLit1 and isLit2:
      let reverses = getReverseMultiCharFolds(simpleFold(r1), simpleFold(r2))
      if reverses.len > 0:
        let savedPos = ctx.pos
        var sr: Rune
        fastRuneAt(ctx.subject, ctx.pos, sr, true)
        let srFold = simpleFold(sr)
        for i in 0 ..< reverses.len:
          if srFold == simpleFold(reverses.runes[i]):
            # Subject char matches a multi-char fold of the pattern pair
            if matchSeqCont(ctx, nodes, idx + 2, cont):
              return true
            break
        ctx.pos = savedPos
  matchWithCont(
    ctx,
    nodes[idx],
    proc(ctx: var MatchContext): bool =
      matchSeqCont(ctx, nodes, idx + 1, cont),
  )

proc caseInsensitiveMatch(r, target: Rune, flags: RegexFlags): bool =
  ## Case-insensitive comparison respecting rfIgnoreCaseAscii flag.
  if rfIgnoreCase notin flags:
    return r == target
  if rfIgnoreCaseAscii in flags:
    # ASCII-only: only fold if both are ASCII
    if int32(r) <= 127 and int32(target) <= 127:
      return simpleFold(r) == simpleFold(target)
    return r == target
  simpleFold(r) == simpleFold(target)

proc matchLiteral(ctx: var MatchContext, target: Rune, cont: MatchCont): bool =
  if ctx.pos >= ctx.subjectEnd:
    return false
  let savedPos = ctx.pos
  var r: Rune
  fastRuneAt(ctx.subject, ctx.pos, r, true)
  if r == target or caseInsensitiveMatch(r, target, ctx.flags):
    if cont(ctx):
      return true
  ctx.pos = savedPos
  # Multi-char fold: pattern char folds to multiple chars (e.g., ß → ss)
  if rfIgnoreCase in ctx.flags and
      (rfIgnoreCaseAscii notin ctx.flags or int32(target) <= 127):
    let fold = getMultiCharFold(target)
    if fold.len > 0:
      ctx.pos = savedPos
      var matched = true
      for i in 0 ..< fold.len:
        if ctx.pos >= ctx.subjectEnd:
          matched = false
          break
        var sr: Rune
        fastRuneAt(ctx.subject, ctx.pos, sr, true)
        if not caseInsensitiveMatch(sr, fold.runes[i], ctx.flags):
          matched = false
          break
      if matched and cont(ctx):
        return true
      ctx.pos = savedPos
  false

proc matchString(ctx: var MatchContext, runes: seq[Rune], cont: MatchCont): bool =
  let savedPos = ctx.pos
  var i = 0
  while i < runes.len:
    if ctx.pos >= ctx.subjectEnd:
      ctx.pos = savedPos
      return false
    let target = runes[i]
    let posBeforeSubjChar = ctx.pos
    var r: Rune
    fastRuneAt(ctx.subject, ctx.pos, r, true)
    let posAfterSubjChar = ctx.pos
    if r == target or caseInsensitiveMatch(r, target, ctx.flags):
      inc i
      continue
    # Try forward multi-char fold: pattern char folds to multiple subject chars (e.g., ß → ss)
    if rfIgnoreCase in ctx.flags and
        (rfIgnoreCaseAscii notin ctx.flags or int32(target) <= 127):
      let fold = getMultiCharFold(target)
      if fold.len > 0:
        ctx.pos = posBeforeSubjChar
        var matched = true
        for j in 0 ..< fold.len:
          if ctx.pos >= ctx.subjectEnd:
            matched = false
            break
          var sr: Rune
          fastRuneAt(ctx.subject, ctx.pos, sr, true)
          if not caseInsensitiveMatch(sr, fold.runes[j], ctx.flags):
            matched = false
            break
        if matched:
          inc i
          continue
    # Try reverse multi-char fold: subject char folds to consecutive pattern chars
    # e.g., subject "ß" matches pattern "ss" because ß full-folds to ss
    if rfIgnoreCase in ctx.flags and rfIgnoreCaseAscii notin ctx.flags:
      let fold = getMultiCharFold(r)
      if fold.len > 0 and i + fold.len <= runes.len:
        var matched = true
        for j in 0 ..< fold.len:
          if not caseInsensitiveMatch(fold.runes[j], runes[i + j], ctx.flags):
            matched = false
            break
        if matched:
          ctx.pos = posAfterSubjChar
          i += fold.len
          continue
    ctx.pos = savedPos
    return false
  if cont(ctx):
    return true
  ctx.pos = savedPos
  false

proc matchCharType(ctx: var MatchContext, ct: CharTypeKind, cont: MatchCont): bool =
  if ctx.pos >= ctx.subjectEnd:
    return false
  let savedPos = ctx.pos
  var r: Rune
  fastRuneAt(ctx.subject, ctx.pos, r, true)
  # Grapheme cluster: \X or . in grapheme/word mode
  if ct == ctGraphemeCluster or
      (ct == ctDot and ctx.graphemeMode in {gmGrapheme, gmWord}):
    if ct == ctDot:
      let dotOk = rfMultiLine in ctx.flags or r != Rune(0x0A)
      if not dotOk:
        ctx.pos = savedPos
        return false
    ctx.pos = savedPos
    let clusterEnd =
      if ctx.graphemeMode == gmWord:
        nextWordSegmentEnd(ctx.subject, savedPos)
      else:
        nextGraphemeClusterEnd(ctx.subject, savedPos)
    if clusterEnd > savedPos:
      ctx.pos = clusterEnd
      if cont(ctx):
        return true
    ctx.pos = savedPos
    return false
  # Newline sequence: \R matches \r\n, \r, \n, \v, \f, or Unicode line separators
  if ct == ctNewlineSeq:
    let c = int32(r)
    if c == 0x0D:
      if ctx.pos < ctx.subjectEnd and ctx.subject[ctx.pos] == '\n':
        inc ctx.pos
      if cont(ctx):
        return true
      ctx.pos = savedPos
      return false
    elif c == 0x0A or c == 0x0B or c == 0x0C or c == 0x85 or c == 0x2028 or c == 0x2029:
      if cont(ctx):
        return true
      ctx.pos = savedPos
      return false
    else:
      ctx.pos = savedPos
      return false
  # Standard character type matching
  let matched =
    case ct
    of ctDot:
      rfMultiLine in ctx.flags or r != Rune(0x0A)
    of ctWord:
      isWordChar(r, rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctNotWord:
      not isWordChar(r, rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctDigit:
      isDigitChar(r, rfAsciiDigit in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctNotDigit:
      not isDigitChar(r, rfAsciiDigit in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctSpace:
      isSpaceChar(r, rfAsciiSpace in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctNotSpace:
      not isSpaceChar(r, rfAsciiSpace in ctx.flags or rfAsciiPosix in ctx.flags)
    of ctHexDigit:
      isHexDigitChar(r)
    of ctNotHexDigit:
      not isHexDigitChar(r)
    of ctAnyChar:
      true
    of ctNotNewline:
      r != Rune(0x0A)
    of ctNewlineSeq, ctGraphemeCluster:
      false # unreachable: handled above
  if matched:
    if cont(ctx):
      return true
  ctx.pos = savedPos
  false

proc matchAnchor(ctx: var MatchContext, kind: AnchorKind, cont: MatchCont): bool =
  let matched =
    case kind
    of akLineBegin:
      ctx.pos == 0 or (ctx.pos > 0 and ctx.subject[ctx.pos - 1] == '\n')
    of akLineEnd:
      ctx.pos >= ctx.subjectEnd or ctx.subject[ctx.pos] == '\n'
    of akStringBegin:
      ctx.pos == 0
    of akStringEnd:
      ctx.pos >= ctx.subjectEnd
    of akStringEndOrNewline:
      ctx.pos >= ctx.subjectEnd or
        (ctx.pos == ctx.subjectEnd - 1 and ctx.subject[ctx.pos] == '\n')
    of akSearchBegin:
      ctx.pos == ctx.searchStart
    of akKeep:
      true
    of akWordBoundary, akNotWordBoundary:
      false # handled in matchWithCont dispatch before reaching here
    of akGraphemeBoundary:
      if ctx.graphemeMode == gmWord:
        isWordBoundaryUax29(ctx.subject, ctx.pos)
      else:
        isGraphemeBoundary(ctx.subject, ctx.pos)
    of akNotGraphemeBoundary:
      if ctx.graphemeMode == gmWord:
        not isWordBoundaryUax29(ctx.subject, ctx.pos)
      else:
        not isGraphemeBoundary(ctx.subject, ctx.pos)
  if matched:
    if kind == akKeep:
      ctx.keepStart = ctx.pos
    return cont(ctx)
  false

proc matchQuantGreedyIter(
    ctx: var MatchContext, body: Node, minRep, maxRep, startCount: int, cont: MatchCont
): bool =
  ## Iterative greedy fallback for large repetition counts.
  ## Matches body greedily, then tries cont from longest to shortest.
  var states: seq[SavedState]
  states.add(save(ctx))
  var reps = 0

  while (maxRep < 0 or startCount + reps < maxRep) and reps < MaxQuantRepetitions:
    let before = save(ctx)
    if not matchWithCont(ctx, body, trueCont):
      restore(ctx, before)
      break
    if ctx.pos == before.pos:
      # Zero-width match: try cont, then force capture changes (matches recursive version)
      if startCount + reps >= minRep:
        if cont(ctx):
          return true
      for _ in 0 ..< ctx.captures.len:
        let s2 = save(ctx)
        let prevCaps = ctx.captures
        let changeCont = proc(ctx: var MatchContext): bool =
          ctx.captures != prevCaps
        if not matchWithCont(ctx, body, changeCont):
          restore(ctx, s2)
          break
        if ctx.pos != s2.pos:
          restore(ctx, s2)
          break
        inc reps
        if startCount + reps >= minRep:
          if cont(ctx):
            return true
      restore(ctx, before)
      break
    states.add(save(ctx))
    inc reps

  for i in countdown(states.high, 0):
    if startCount + i >= minRep:
      restore(ctx, states[i])
      if cont(ctx):
        return true

  restore(ctx, states[0])
  false

proc matchQuantLazyIter(
    ctx: var MatchContext, body: Node, minRep, maxRep, startCount: int, cont: MatchCont
): bool =
  ## Iterative lazy fallback for large repetition counts.
  var reps = 0

  while startCount + reps < minRep and (maxRep < 0 or startCount + reps < maxRep) and
      reps < MaxQuantRepetitions:
    let before = save(ctx)
    if not matchWithCont(ctx, body, trueCont):
      restore(ctx, before)
      return false
    if ctx.pos == before.pos:
      break
    inc reps

  if startCount + reps < minRep:
    return false

  while reps < MaxQuantRepetitions:
    let saved = save(ctx)
    if cont(ctx):
      return true
    restore(ctx, saved)

    if maxRep >= 0 and startCount + reps >= maxRep:
      break

    let before = save(ctx)
    if not matchWithCont(ctx, body, trueCont):
      restore(ctx, before)
      break
    if ctx.pos == before.pos:
      # Zero-width match: try cont, then force capture changes (matches recursive version)
      if cont(ctx):
        return true
      for _ in 0 ..< ctx.captures.len:
        let s2 = save(ctx)
        let prevCaps = ctx.captures
        let changeCont = proc(ctx: var MatchContext): bool =
          ctx.captures != prevCaps
        if not matchWithCont(ctx, body, changeCont):
          restore(ctx, s2)
          break
        if ctx.pos != s2.pos:
          restore(ctx, s2)
          break
        inc reps
        if cont(ctx):
          return true
      restore(ctx, before)
      break
    inc reps

  false

const QuantRecursionThreshold = 300
  ## Switch from recursive (fully correct) to iterative (stack-safe) after
  ## this many repetitions. 300 × ~4 frames ≈ 1200, safe within Nim debug
  ## call-depth limit of 2000.

proc matchQuantGreedy(
    ctx: var MatchContext, body: Node, minRep, maxRep, count: int, cont: MatchCont
): bool =
  if count >= QuantRecursionThreshold:
    return matchQuantGreedyIter(ctx, body, minRep, maxRep, count, cont)
  # Greedy: try one more repetition first, then fall back to continuation
  if maxRep < 0 or count < maxRep:
    let saved = save(ctx)
    let moreRepsCont = proc(ctx: var MatchContext): bool =
      if ctx.pos == saved.pos:
        # Zero-width body match. Try cont, then try more iterations
        # in a bounded loop to set different captures (no recursive backtracking).
        if cont(ctx):
          return true
        # Force body to pick alternatives that change captures
        for _ in 0 ..< ctx.captures.len:
          let s2 = save(ctx)
          let prevCaps = ctx.captures
          let changeCont = proc(ctx: var MatchContext): bool =
            ctx.captures != prevCaps # only accept if captures changed
          if not matchWithCont(ctx, body, changeCont):
            restore(ctx, s2)
            break
          if ctx.pos != s2.pos:
            restore(ctx, s2)
            break
          if cont(ctx):
            return true
        return false
      matchQuantGreedy(ctx, body, minRep, maxRep, count + 1, cont)
    if matchWithCont(ctx, body, moreRepsCont):
      return true
    restore(ctx, saved)

  # Fall back: stop repeating, try continuation
  if count >= minRep:
    return cont(ctx)
  false

proc matchQuantLazy(
    ctx: var MatchContext, body: Node, minRep, maxRep, count: int, cont: MatchCont
): bool =
  if count >= QuantRecursionThreshold:
    return matchQuantLazyIter(ctx, body, minRep, maxRep, count, cont)
  # Lazy: try continuation first, then one more repetition
  if count >= minRep:
    let saved = save(ctx)
    if cont(ctx):
      return true
    restore(ctx, saved)

  if maxRep < 0 or count < maxRep:
    let saved = save(ctx)
    let moreRepsCont = proc(ctx: var MatchContext): bool =
      if ctx.pos == saved.pos:
        if cont(ctx):
          return true
        for _ in 0 ..< ctx.captures.len:
          let s2 = save(ctx)
          let prevCaps = ctx.captures
          let changeCont = proc(ctx: var MatchContext): bool =
            ctx.captures != prevCaps
          if not matchWithCont(ctx, body, changeCont):
            restore(ctx, s2)
            break
          if ctx.pos != s2.pos:
            restore(ctx, s2)
            break
          if cont(ctx):
            return true
        return false
      matchQuantLazy(ctx, body, minRep, maxRep, count + 1, cont)
    if matchWithCont(ctx, body, moreRepsCont):
      return true
    restore(ctx, saved)
  false

proc matchQuantPossessive(
    ctx: var MatchContext, body: Node, minRep, maxRep: int, cont: MatchCont
): bool =
  # Possessive: match greedily, no backtracking on count
  var count = 0
  while maxRep < 0 or count < maxRep:
    let savedPos = ctx.pos
    if not matchWithCont(ctx, body, trueCont):
      ctx.pos = savedPos
      break
    count += 1
    if ctx.pos == savedPos:
      break # zero-width: count as one rep, then stop
  if count >= minRep:
    return cont(ctx)
  false

proc matchCcAtom(r: Rune, atom: CcAtom, flags: RegexFlags): bool =
  case atom.kind
  of ccLiteral:
    r == atom.rune or caseInsensitiveMatch(r, atom.rune, flags)
  of ccRange:
    let lo = int32(atom.rangeFrom)
    let hi = int32(atom.rangeTo)
    let ri = int32(r)
    if ri >= lo and ri <= hi:
      true
    elif rfIgnoreCase in flags:
      if rfIgnoreCaseAscii in flags:
        # ASCII-only: only fold ASCII characters
        if ri <= 127:
          let fi = int32(simpleFold(r))
          fi >= lo and fi <= hi
        else:
          false
      else:
        # Check if any case variant of r falls in the original range
        for variant in resolveCaseFold(r):
          if int32(variant) >= lo and int32(variant) <= hi:
            return true
        false
    else:
      false
  of ccCharType:
    case atom.charType
    of ctWord:
      isWordChar(r, rfAsciiWord in flags)
    of ctNotWord:
      not isWordChar(r, rfAsciiWord in flags)
    of ctDigit:
      isDigitChar(r, rfAsciiDigit in flags)
    of ctNotDigit:
      not isDigitChar(r, rfAsciiDigit in flags)
    of ctSpace:
      isSpaceChar(r, rfAsciiSpace in flags)
    of ctNotSpace:
      not isSpaceChar(r, rfAsciiSpace in flags)
    of ctHexDigit:
      isHexDigitChar(r)
    of ctNotHexDigit:
      not isHexDigitChar(r)
    of ctDot, ctAnyChar:
      true
    of ctNotNewline:
      r != Rune(0x0A)
    of ctNewlineSeq:
      let c = int32(r)
      c == 0x0A or c == 0x0D or c == 0x0B or c == 0x0C or c == 0x85 or c == 0x2028 or
        c == 0x2029
    of ctGraphemeCluster:
      true # \X in character classes: any character
  of ccPosix:
    matchPosixClass(r, atom.posixClass, posixAsciiOnly(atom.posixClass, flags))
  of ccNegPosix:
    not matchPosixClass(r, atom.posixClass, posixAsciiOnly(atom.posixClass, flags))
  of ccUnicodeProp:
    matchUnicodeProp(r, atom.propName, flags)
  of ccNegUnicodeProp:
    not matchUnicodeProp(r, atom.propName, flags)
  of ccNestedClass:
    var anyMatch = false
    for nested in atom.nestedAtoms:
      if matchCcAtom(r, nested, flags):
        anyMatch = true
        break
    if atom.nestedNegated:
      not anyMatch
    else:
      anyMatch
  of ccIntersection:
    # Character must match BOTH left and right sides
    var leftMatch = false
    for a in atom.interLeft:
      if matchCcAtom(r, a, flags):
        leftMatch = true
        break
    if atom.interLeftNeg:
      leftMatch = not leftMatch
    var rightMatch = false
    for a in atom.interRight:
      if matchCcAtom(r, a, flags):
        rightMatch = true
        break
    if atom.interRightNeg:
      rightMatch = not rightMatch
    leftMatch and rightMatch

proc matchCcAtomWithFold(r: Rune, atom: CcAtom, flags: RegexFlags): bool =
  ## Match a character class atom, checking case-fold variants for
  ## POSIX, char type, and Unicode property atoms when case-insensitive.
  if matchCcAtom(r, atom, flags):
    return true
  if rfIgnoreCase in flags:
    # With rfIgnoreCaseAscii, only fold ASCII characters
    if rfIgnoreCaseAscii in flags and int32(r) > 127:
      return false
    case atom.kind
    of ccPosix, ccNegPosix, ccCharType, ccUnicodeProp, ccNegUnicodeProp:
      # Check case-fold variants
      for variant in resolveCaseFold(r):
        if variant != r and matchCcAtom(variant, atom, flags):
          return true
    of ccNestedClass:
      for variant in resolveCaseFold(r):
        if variant != r and matchCcAtom(variant, atom, flags):
          return true
    else:
      discard
  false

proc tryMultiCharFold(ctx: var MatchContext, node: Node, cont: MatchCont): bool =
  ## Try multi-character case fold expansions for bracket character classes.
  ## e.g., (?i:[ß]) should match "ss" because ß folds to "ss".
  if not (rfIgnoreCase in ctx.flags and node.bracketClass and not node.negated):
    return false
  for fold in MultiCharFolds:
    let (srcCP, expCP, expLen) = fold
    let srcRune = Rune(srcCP)
    # Check if the source rune matches any atom in the class
    var atomMatch = false
    for atom in node.atoms:
      if matchCcAtomWithFold(srcRune, atom, ctx.flags):
        atomMatch = true
        break
    if not atomMatch:
      continue
    # Check if the expansion matches at the current position (case-insensitively)
    var p = ctx.pos
    var ok = true
    for i in 0 ..< expLen:
      if p >= ctx.subjectEnd:
        ok = false
        break
      var subjRune: Rune
      fastRuneAt(ctx.subject, p, subjRune, true)
      let expRune = Rune(expCP[i])
      if subjRune != expRune and simpleFold(subjRune) != simpleFold(expRune):
        ok = false
        break
    if ok:
      let savedPos = ctx.pos
      ctx.pos = p
      if cont(ctx):
        return true
      ctx.pos = savedPos
  false

proc matchCharClass(ctx: var MatchContext, node: Node, cont: MatchCont): bool =
  if ctx.pos >= ctx.subjectEnd:
    return false
  # Try multi-char case fold first (e.g., ß → ss)
  if rfIgnoreCase in ctx.flags:
    if tryMultiCharFold(ctx, node, cont):
      return true
  let savedPos = ctx.pos
  var r: Rune
  fastRuneAt(ctx.subject, ctx.pos, r, true)

  var anyMatch = false
  for atom in node.atoms:
    if node.bracketClass and matchCcAtomWithFold(r, atom, ctx.flags):
      anyMatch = true
      break
    elif not node.bracketClass and matchCcAtom(r, atom, ctx.flags):
      anyMatch = true
      break

  let matched =
    if node.negated:
      not anyMatch
    else:
      anyMatch
  if matched:
    if cont(ctx):
      return true
  ctx.pos = savedPos
  false

proc prevRune(s: string, pos: int): Rune =
  ## Decode the rune ending just before `pos`.
  if pos <= 0:
    return Rune(0)
  var startPos = pos - 1
  while startPos > 0 and (s[startPos].uint8 and 0xC0'u8) == 0x80'u8:
    dec startPos
  var p = startPos
  var r: Rune
  fastRuneAt(s, p, r, true)
  r

proc matchWordBoundary(ctx: MatchContext): bool =
  let asciiOnly = rfAsciiWord in ctx.flags or rfAsciiPosix in ctx.flags
  let prevIsWord =
    if ctx.pos > 0:
      isWordChar(prevRune(ctx.subject, ctx.pos), asciiOnly)
    else:
      false
  let nextIsWord =
    if ctx.pos < ctx.subjectEnd:
      var p = ctx.pos
      var r: Rune
      fastRuneAt(ctx.subject, p, r, true)
      isWordChar(r, asciiOnly)
    else:
      false
  prevIsWord xor nextIsWord

proc resolveCapture(ctx: MatchContext, capIdx: int, level: int): Span =
  ## Resolve a capture, optionally using recursion-level stack.
  ## level > 0: access the level-th entry (1-based) in the capture stack for this group.
  ## level 0: use the current capture value.
  if level > 0 and capIdx > 0 and capIdx - 1 < ctx.captureStacks.len:
    let stack = ctx.captureStacks[capIdx - 1] # captureStacks is 0-based by group
    if level <= stack.len:
      return stack[level - 1] # 1-based: level 1 = first entry
    return UnsetSpan
  if capIdx >= ctx.captures.len:
    return UnsetSpan
  ctx.captures[capIdx]

proc matchBackref(
    ctx: var MatchContext, capIdx: int, cont: MatchCont, level: int = 0
): bool =
  let cap = resolveCapture(ctx, capIdx, level)
  if cap.a < 0:
    return false # unset capture
  let capLen = cap.b - cap.a
  if rfIgnoreCase in ctx.flags:
    # Compare rune by rune with case fold. Also handle multi-character folds
    # (e.g. ß ↔ ss) symmetrically on both captured and subject sides.
    var sp = cap.a
    var mp = ctx.pos
    while sp < cap.b:
      if mp >= ctx.subjectEnd:
        return false
      let mpBefore = mp
      var sr, mr: Rune
      fastRuneAt(ctx.subject, sp, sr, true)
      fastRuneAt(ctx.subject, mp, mr, true)
      if sr == mr or caseInsensitiveMatch(sr, mr, ctx.flags):
        continue
      let asciiOnly = rfIgnoreCaseAscii in ctx.flags
      # Forward multi-char fold: captured rune folds to multiple subject runes.
      block forwardFold:
        if asciiOnly and int32(sr) > 127:
          break forwardFold
        let fold = getMultiCharFold(sr)
        if fold.len == 0:
          break forwardFold
        var tp = mpBefore
        var ok = true
        for j in 0 ..< fold.len:
          if tp >= ctx.subjectEnd:
            ok = false
            break
          var tr: Rune
          fastRuneAt(ctx.subject, tp, tr, true)
          if not caseInsensitiveMatch(tr, fold.runes[j], ctx.flags):
            ok = false
            break
        if ok:
          mp = tp
          continue
      # Reverse multi-char fold: subject rune folds to multiple captured runes.
      block reverseFold:
        if asciiOnly:
          break reverseFold
        let fold = getMultiCharFold(mr)
        if fold.len == 0:
          break reverseFold
        if not caseInsensitiveMatch(sr, fold.runes[0], ctx.flags):
          break reverseFold
        var tp = sp
        var ok = true
        for j in 1 ..< fold.len:
          if tp >= cap.b:
            ok = false
            break
          var tr: Rune
          fastRuneAt(ctx.subject, tp, tr, true)
          if not caseInsensitiveMatch(tr, fold.runes[j], ctx.flags):
            ok = false
            break
        if ok:
          sp = tp
          continue
      return false
    let savedPos = ctx.pos
    ctx.pos = mp # use actual bytes consumed, not capture byte length
    if cont(ctx):
      return true
    ctx.pos = savedPos
    false
  else:
    if ctx.pos + capLen > ctx.subjectEnd:
      return false
    for i in 0 ..< capLen:
      if ctx.subject[cap.a + i] != ctx.subject[ctx.pos + i]:
        return false
    let savedPos = ctx.pos
    ctx.pos += capLen
    if cont(ctx):
      return true
    ctx.pos = savedPos
    false

proc matchCapture(
    ctx: var MatchContext, index: int, body: Node, cont: MatchCont
): bool =
  let capIdx = index + 1 # boundaries[0] = overall match
  let startPos = ctx.pos
  let savedFlags = ctx.flags
  # Capture recursion depth at entry time (before continuations modify it)
  let myDepth =
    if index < ctx.groupRecursionDepth.len:
      ctx.groupRecursionDepth[index]
    else:
      -1
  let capCont = proc(ctx: var MatchContext): bool =
    let endPos = ctx.pos
    let savedCap = ctx.captures[capIdx]
    ctx.captures[capIdx] = span(startPos, endPos)
    # Record capture in recursion-level stack
    var savedStackEntry = UnsetSpan
    if myDepth >= 0:
      if index >= ctx.captureStacks.len:
        ctx.captureStacks.setLen(index + 1)
      if myDepth >= ctx.captureStacks[index].len:
        ctx.captureStacks[index].setLen(myDepth + 1)
      savedStackEntry = ctx.captureStacks[index][myDepth]
      ctx.captureStacks[index][myDepth] = span(startPos, endPos)
    let modFlags = ctx.flags
    ctx.flags = savedFlags # restore flags at group boundary
    let ok = cont(ctx)
    if not ok:
      ctx.captures[capIdx] = savedCap
      ctx.flags = modFlags
      if myDepth >= 0:
        ctx.captureStacks[index][myDepth] = savedStackEntry
    ok
  matchWithCont(ctx, body, capCont)

proc fixedByteLen(node: Node): int =
  ## Returns the fixed byte length consumed by a node, or -1 if variable/unknown.
  if node == nil:
    return 0
  case node.kind
  of nkLiteral:
    node.rune.size
  of nkEscapedLiteral:
    node.escapedRune.size
  of nkString:
    var total = 0
    for r in node.runes:
      total += r.size
    total
  of nkConcat:
    var total = 0
    for child in node.children:
      let cl = fixedByteLen(child)
      if cl < 0:
        return -1
      total += cl
    total
  of nkAlternation:
    if node.alternatives.len == 0:
      return 0
    let first = fixedByteLen(node.alternatives[0])
    if first < 0:
      return -1
    for i in 1 ..< node.alternatives.len:
      if fixedByteLen(node.alternatives[i]) != first:
        return -1
    first
  of nkQuantifier:
    if node.quantMin == node.quantMax and node.quantMin >= 0:
      let bodyLen = fixedByteLen(node.quantBody)
      if bodyLen < 0:
        return -1
      bodyLen * node.quantMin
    else:
      -1
  of nkCapture:
    fixedByteLen(node.captureBody)
  of nkNamedCapture:
    fixedByteLen(node.namedCaptureBody)
  of nkGroup:
    fixedByteLen(node.groupBody)
  of nkFlagGroup:
    if node.flagBody != nil:
      fixedByteLen(node.flagBody)
    else:
      0
  of nkAtomicGroup:
    fixedByteLen(node.atomicBody)
  of nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    0 # zero-width
  of nkCharType:
    -1 # variable UTF-8 width
  of nkCharClass:
    -1 # variable UTF-8 width
  else:
    -1

proc maxByteLen(node: Node): int =
  ## Returns an upper bound on bytes consumed, or -1 if unbounded/unknown.
  if node == nil:
    return 0
  case node.kind
  of nkLiteral:
    node.rune.size
  of nkEscapedLiteral:
    node.escapedRune.size
  of nkString:
    var total = 0
    for r in node.runes:
      total += r.size
    total
  of nkConcat:
    var total = 0
    for child in node.children:
      let cl = maxByteLen(child)
      if cl < 0:
        return -1
      total += cl
      if total < 0:
        return -1 # overflow guard
    total
  of nkAlternation:
    var best = 0
    for alt in node.alternatives:
      let al = maxByteLen(alt)
      if al < 0:
        return -1
      best = max(best, al)
    best
  of nkQuantifier:
    if node.quantMax < 0:
      return -1 # unbounded
    let bodyLen = maxByteLen(node.quantBody)
    if bodyLen < 0:
      return -1
    let total = bodyLen * node.quantMax
    if node.quantMax > 0 and total div node.quantMax != bodyLen:
      return -1 # overflow
    total
  of nkCapture:
    maxByteLen(node.captureBody)
  of nkNamedCapture:
    maxByteLen(node.namedCaptureBody)
  of nkGroup:
    maxByteLen(node.groupBody)
  of nkFlagGroup:
    if node.flagBody != nil:
      maxByteLen(node.flagBody)
    else:
      0
  of nkAtomicGroup:
    maxByteLen(node.atomicBody)
  of nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    0
  of nkCharType:
    4 # max UTF-8 bytes per rune
  of nkCharClass:
    4
  of nkBackreference, nkNamedBackref, nkSubexpCall:
    -1 # can't bound
  of nkConditional:
    let yesLen = maxByteLen(node.condYes)
    let noLen =
      if node.condNo != nil:
        maxByteLen(node.condNo)
      else:
        0
    if yesLen < 0 or noLen < 0:
      -1
    else:
      max(yesLen, noLen)
  of nkAbsent:
    -1

proc matchLookbehindFixed(
    ctx: var MatchContext, body: Node, targetEnd: int, fbl: int, cont: MatchCont
): bool =
  ## Fixed-length lookbehind: only one starting position to try.
  let st = targetEnd - fbl
  if st < 0:
    return false
  var tryCtx = ctx
  tryCtx.pos = st
  let te = targetEnd
  let endCheck = proc(tryCtx: var MatchContext): bool =
    tryCtx.pos == te
  if matchWithCont(tryCtx, body, endCheck):
    ctx.captures = tryCtx.captures
    return cont(ctx)
  false

proc matchNegLookbehindFixed(
    ctx: var MatchContext, body: Node, targetEnd: int, fbl: int, cont: MatchCont
): bool =
  ## Fixed-length negative lookbehind: only one starting position to try.
  let st = targetEnd - fbl
  if st < 0:
    return cont(ctx) # can't match → negative succeeds
  var tryCtx = ctx
  tryCtx.pos = st
  let te = targetEnd
  let endCheck = proc(tryCtx: var MatchContext): bool =
    tryCtx.pos == te
  if matchWithCont(tryCtx, body, endCheck):
    return false
  cont(ctx)

proc matchLookaround(ctx: var MatchContext, node: Node, cont: MatchCont): bool =
  let kind = node.lookKind
  case kind
  of lkAhead:
    let saved = save(ctx)
    let bodyMatch = matchWithCont(ctx, node.lookBody, trueCont)
    let savedCaps = ctx.captures # keep captures from positive lookahead
    restore(ctx, saved)
    if bodyMatch:
      ctx.captures = savedCaps
      return cont(ctx)
    false
  of lkNegAhead:
    let saved = save(ctx)
    let bodyMatch = matchWithCont(ctx, node.lookBody, trueCont)
    restore(ctx, saved)
    if not bodyMatch:
      return cont(ctx)
    false
  of lkBehind:
    let targetEnd = ctx.pos
    # For alternation at top level: try each branch independently with its own length
    let body = node.lookBody
    if body.kind == nkAlternation:
      for alt in body.alternatives:
        let altFbl = fixedByteLen(alt)
        if altFbl >= 0:
          # Fixed-length alternative: try at exact start position
          let st = targetEnd - altFbl
          if st >= 0:
            var tryCtx = ctx
            tryCtx.pos = st
            let te = targetEnd
            let endCheck = proc(tryCtx: var MatchContext): bool =
              tryCtx.pos == te
            if matchWithCont(tryCtx, alt, endCheck):
              ctx.captures = tryCtx.captures
              if cont(ctx):
                return true
        else:
          # Variable-length alternative: scan from shortest to longest
          let altMbl = maxByteLen(alt)
          let altMinPos =
            if altMbl >= 0:
              max(0, targetEnd - altMbl)
            else:
              0
          var startTry = targetEnd
          while startTry >= altMinPos:
            var tryCtx = ctx
            tryCtx.pos = startTry
            let te = targetEnd
            let endCheck = proc(tryCtx: var MatchContext): bool =
              tryCtx.pos == te
            if matchWithCont(tryCtx, alt, endCheck):
              ctx.captures = tryCtx.captures
              return cont(ctx) # shortest priority: commit
            if startTry == 0:
              break
            dec startTry
            while startTry > 0 and (ctx.subject[startTry].uint8 and 0xC0'u8) == 0x80'u8:
              dec startTry
      return false
    let fbl = fixedByteLen(body)
    if fbl >= 0:
      return matchLookbehindFixed(ctx, body, targetEnd, fbl, cont)
    # Variable-length (non-alternation): shortest priority (commit to first match)
    let mbl = maxByteLen(body)
    let minPos =
      if mbl >= 0:
        max(0, targetEnd - mbl)
      else:
        0
    var startTry = targetEnd
    while startTry >= minPos:
      var tryCtx = ctx
      tryCtx.pos = startTry
      let endCheck = proc(tryCtx: var MatchContext): bool =
        tryCtx.pos == targetEnd
      if matchWithCont(tryCtx, body, endCheck):
        ctx.captures = tryCtx.captures
        return cont(ctx) # shortest priority: commit to this match
      if startTry == 0:
        break
      dec startTry
      while startTry > 0 and (ctx.subject[startTry].uint8 and 0xC0'u8) == 0x80'u8:
        dec startTry
    false
  of lkNegBehind:
    let targetEnd = ctx.pos
    let body = node.lookBody
    if body.kind == nkAlternation:
      # Try each alternative independently — if ANY matches, negative fails
      for alt in body.alternatives:
        let altFbl = fixedByteLen(alt)
        if altFbl >= 0:
          let st = targetEnd - altFbl
          if st >= 0:
            var tryCtx = ctx
            tryCtx.pos = st
            let te = targetEnd
            let endCheck = proc(tryCtx: var MatchContext): bool =
              tryCtx.pos == te
            if matchWithCont(tryCtx, alt, endCheck):
              return false
        else:
          let altMbl = maxByteLen(alt)
          let altMinPos =
            if altMbl >= 0:
              max(0, targetEnd - altMbl)
            else:
              0
          var startTry = targetEnd
          while startTry >= altMinPos:
            var tryCtx = ctx
            tryCtx.pos = startTry
            let te = targetEnd
            let endCheck = proc(tryCtx: var MatchContext): bool =
              tryCtx.pos == te
            if matchWithCont(tryCtx, alt, endCheck):
              return false
            if startTry == 0:
              break
            dec startTry
            while startTry > 0 and (ctx.subject[startTry].uint8 and 0xC0'u8) == 0x80'u8:
              dec startTry
      return cont(ctx)
    let fbl = fixedByteLen(body)
    if fbl >= 0:
      return matchNegLookbehindFixed(ctx, body, targetEnd, fbl, cont)
    # Variable-length (non-alternation): scan from right to left
    let negMbl = maxByteLen(body)
    let negMinPos =
      if negMbl >= 0:
        max(0, targetEnd - negMbl)
      else:
        0
    var startTry = targetEnd
    while startTry >= negMinPos:
      var tryCtx = ctx
      tryCtx.pos = startTry
      let endCheck = proc(tryCtx: var MatchContext): bool =
        tryCtx.pos == targetEnd
      if matchWithCont(tryCtx, body, endCheck):
        return false
      if startTry == 0:
        break
      dec startTry
      while startTry > 0 and (ctx.subject[startTry].uint8 and 0xC0'u8) == 0x80'u8:
        dec startTry
    cont(ctx)

proc matchAtomic(ctx: var MatchContext, body: Node, cont: MatchCont): bool =
  let saved = save(ctx)
  if matchWithCont(ctx, body, trueCont):
    # Body matched — commit, no backtracking into body
    if cont(ctx):
      return true
  restore(ctx, saved)
  false

proc matchAbsent(ctx: var MatchContext, node: Node, cont: MatchCont): bool =
  case node.absentKind
  of abClear:
    # (?~) or (?~|) - always matches empty, restore subject end
    ctx.subjectEnd = ctx.subject.len
    return cont(ctx)
  of abFunction:
    # (?~pattern) - match longest text not containing pattern
    let startPos = ctx.pos
    # Find first position where absent pattern matches with non-zero width
    var firstAbsentPos = ctx.subjectEnd # default: no absent found -> match to end
    var checkPos = startPos
    while checkPos < ctx.subjectEnd:
      let saved = save(ctx)
      ctx.pos = checkPos
      let cp = checkPos
      let nonZeroCont = proc(ctx: var MatchContext): bool =
        ctx.pos > cp # only accept non-zero-width matches
      if matchWithCont(ctx, node.absentBody, nonZeroCont):
        firstAbsentPos = checkPos
        restore(ctx, saved)
        break
      restore(ctx, saved)
      var r: Rune
      fastRuneAt(ctx.subject, checkPos, r, true)
    # Match from startPos to firstAbsentPos (longest text before absent)
    ctx.pos = firstAbsentPos
    if cont(ctx):
      return true
    # If continuation fails, try shorter matches
    var tryPos = firstAbsentPos - 1
    while tryPos >= startPos:
      # Walk back to valid UTF-8 boundary
      if tryPos > startPos and (ctx.subject[tryPos].ord and 0xC0) == 0x80:
        dec tryPos
        continue
      ctx.pos = tryPos
      if cont(ctx):
        return true
      dec tryPos
    ctx.pos = startPos
    false
  of abExpression:
    # (?~|absent|expr) - match expr, limiting range to exclude absent
    let startPos = ctx.pos
    let absentBody = node.absentBody
    # Find first position where absent matches
    var absentPos = ctx.subjectEnd
    block findAbsent:
      var checkPos = startPos
      while checkPos < ctx.subjectEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if matchWithCont(ctx, absentBody, trueCont):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.subjectEnd:
          break
        var r: Rune
        fastRuneAt(ctx.subject, checkPos, r, true)
    # Limit matching range to [startPos, absentPos)
    let savedEnd = ctx.subjectEnd
    ctx.pos = startPos
    ctx.subjectEnd = absentPos
    let restoreCont = proc(ctx: var MatchContext): bool =
      ctx.subjectEnd = savedEnd
      let ok = cont(ctx)
      if not ok:
        ctx.subjectEnd = absentPos
      ok
    let ok = matchWithCont(ctx, node.absentExpr, restoreCont)
    ctx.subjectEnd = savedEnd
    return ok
  of abRange:
    # (?~|absent) - range marker: zero-width, limits subjectEnd
    let absentBody = node.absentBody
    var absentPos = ctx.subjectEnd
    block findAbsent:
      var checkPos = ctx.pos
      while checkPos < ctx.subjectEnd:
        let saved = save(ctx)
        ctx.pos = checkPos
        if matchWithCont(ctx, absentBody, trueCont):
          absentPos = checkPos
          restore(ctx, saved)
          break findAbsent
        restore(ctx, saved)
        if checkPos >= ctx.subjectEnd:
          break
        var r: Rune
        fastRuneAt(ctx.subject, checkPos, r, true)
    let savedEnd = ctx.subjectEnd
    ctx.subjectEnd = absentPos
    let ok = cont(ctx)
    if not ok:
      ctx.subjectEnd = savedEnd # restore only on failure
    return ok

proc matchWithCont(ctx: var MatchContext, node: Node, cont: MatchCont): bool =
  inc ctx.steps
  if ctx.stepLimit > 0 and ctx.steps > ctx.stepLimit:
    raise newException(RegexLimitError, "match step limit exceeded")
  inc ctx.callDepth
  if ctx.callDepth > MaxCallDepth:
    dec ctx.callDepth
    raise newException(RegexLimitError, "match call depth exceeded")
  defer:
    dec ctx.callDepth
  case node.kind
  of nkLiteral:
    matchLiteral(ctx, node.rune, cont)
  of nkEscapedLiteral:
    matchLiteral(ctx, node.escapedRune, cont)
  of nkString:
    matchString(ctx, node.runes, cont)
  of nkConcat:
    matchSeqCont(ctx, node.children, 0, cont)
  of nkAlternation:
    for alt in node.alternatives:
      # Save pos, captures, keepStart — but NOT flags.
      # Isolated flag groups (?i) extend across alternation branches.
      let savedPos = ctx.pos
      let savedCaps = ctx.captures
      let savedKeep = ctx.keepStart
      if matchWithCont(ctx, alt, cont):
        return true
      ctx.pos = savedPos
      ctx.captures = savedCaps
      ctx.keepStart = savedKeep
    false
  of nkCharType:
    matchCharType(ctx, node.charType, cont)
  of nkCharClass:
    matchCharClass(ctx, node, cont)
  of nkGroup:
    # Groups save/restore flags — isolated flag groups inside don't leak out
    let savedFlags = ctx.flags
    let groupCont = proc(ctx: var MatchContext): bool =
      let modFlags = ctx.flags
      ctx.flags = savedFlags
      let ok = cont(ctx)
      if not ok:
        ctx.flags = modFlags
      ok
    let ok = matchWithCont(ctx, node.groupBody, groupCont)
    if not ok:
      ctx.flags = savedFlags
    ok
  of nkCapture:
    let savedFlags = ctx.flags
    let ok = matchCapture(ctx, node.captureIndex, node.captureBody, cont)
    if not ok:
      ctx.flags = savedFlags
    ok
  of nkNamedCapture:
    let savedFlags = ctx.flags
    let ok = matchCapture(ctx, node.namedCaptureIndex, node.namedCaptureBody, cont)
    if not ok:
      ctx.flags = savedFlags
    ok
  of nkFlagGroup:
    if node.flagBody == nil:
      ctx.flags = ctx.flags + node.flagsOn - node.flagsOff
      if node.graphemeMode != gmNone:
        ctx.graphemeMode = node.graphemeMode
      cont(ctx)
    else:
      let savedFlags = ctx.flags
      let savedGM = ctx.graphemeMode
      let modifiedFlags = ctx.flags + node.flagsOn - node.flagsOff
      ctx.flags = modifiedFlags
      if node.graphemeMode != gmNone:
        ctx.graphemeMode = node.graphemeMode
      let flagCont = proc(ctx: var MatchContext): bool =
        ctx.flags = savedFlags
        ctx.graphemeMode = savedGM
        let ok = cont(ctx)
        if not ok:
          ctx.flags = modifiedFlags
          if node.graphemeMode != gmNone:
            ctx.graphemeMode = node.graphemeMode
        ok
      let ok = matchWithCont(ctx, node.flagBody, flagCont)
      if not ok:
        ctx.flags = savedFlags
        ctx.graphemeMode = savedGM
      ok
  of nkAnchor:
    if node.anchor == akWordBoundary:
      if matchWordBoundary(ctx):
        return cont(ctx)
      return false
    elif node.anchor == akNotWordBoundary:
      if not matchWordBoundary(ctx):
        return cont(ctx)
      return false
    else:
      matchAnchor(ctx, node.anchor, cont)
  of nkQuantifier:
    # Oniguruma: {n,m} where n > m → possessive {0, max(n,m)}
    var qmin = node.quantMin
    var qmax = node.quantMax
    var qkind = node.quantKind
    if qmax >= 0 and qmin > qmax:
      swap(qmin, qmax)
      qkind = qkPossessive
    case qkind
    of qkGreedy:
      matchQuantGreedy(ctx, node.quantBody, qmin, qmax, 0, cont)
    of qkLazy:
      matchQuantLazy(ctx, node.quantBody, qmin, qmax, 0, cont)
    of qkPossessive:
      matchQuantPossessive(ctx, node.quantBody, qmin, qmax, cont)
  of nkBackreference:
    matchBackref(ctx, node.backrefIndex, cont, node.backrefLevel)
  of nkNamedBackref:
    # Try ALL capture groups with matching name (for duplicate named captures)
    var anyFound = false
    for (name, i) in ctx.regex.namedCaptures:
      if name == node.backrefName:
        anyFound = true
        let idx = i + 1 # captures are 1-indexed in boundaries
        let saved = save(ctx)
        if matchBackref(ctx, idx, cont, node.namedBackrefLevel):
          return true
        restore(ctx, saved)
    if not anyFound:
      return false
    # All named groups exist but none captured → fail
    false
  of nkLookaround:
    matchLookaround(ctx, node, cont)
  of nkAtomicGroup:
    matchAtomic(ctx, node.atomicBody, cont)
  of nkSubexpCall:
    # \g<n> or \g<name>: match the body of the referenced capture group
    var body: Node = nil
    var captureIdx = -1 # 0-based index for matchCapture
    if node.callIndex == 0:
      # \g<0> = entire pattern recursion
      body = ctx.regex.ast
    elif node.callIndex > 0:
      let idx = node.callIndex - 1 # 0-based in groupBodies
      if idx < ctx.regex.groupBodies.len:
        body = ctx.regex.groupBodies[idx]
      captureIdx = idx
    elif node.callName.len > 0:
      for (name, i) in ctx.regex.namedCaptures:
        if name == node.callName:
          if i < ctx.regex.groupBodies.len:
            body = ctx.regex.groupBodies[i]
          captureIdx = i
          break
    if body == nil:
      return false
    inc ctx.recursionDepth
    if ctx.recursionDepth > ctx.maxRecursionDepth:
      dec ctx.recursionDepth
      return false # too deep recursion — treat as no match
    # Increment per-group recursion depth for recursion-level backrefs
    if captureIdx >= 0:
      if captureIdx >= ctx.groupRecursionDepth.len:
        ctx.groupRecursionDepth.setLen(captureIdx + 1)
      inc ctx.groupRecursionDepth[captureIdx]
    # Apply the flags that were active when the group was defined
    let savedFlags = ctx.flags
    if captureIdx >= 0 and captureIdx < ctx.regex.groupFlags.len:
      ctx.flags = ctx.regex.groupFlags[captureIdx]
    var ok: bool
    if captureIdx >= 0 and captureIdx + 1 < ctx.captures.len:
      ok = matchCapture(ctx, captureIdx, body, cont)
    else:
      ok = matchWithCont(ctx, body, cont)
    if not ok:
      ctx.flags = savedFlags
    # Decrement per-group recursion depth
    if captureIdx >= 0 and captureIdx < ctx.groupRecursionDepth.len:
      dec ctx.groupRecursionDepth[captureIdx]
    dec ctx.recursionDepth
    ok
  of nkConditional:
    var condMet = false
    case node.condKind
    of ckBackref:
      let capIdx = node.condRefIndex # 1-indexed capture
      if capIdx >= 0 and capIdx < ctx.captures.len:
        condMet = ctx.captures[capIdx].a >= 0
    of ckNamedRef:
      # Check ALL capture groups with matching name
      for (name, i) in ctx.regex.namedCaptures:
        if name == node.condRefName:
          let capIdx = i + 1
          if capIdx < ctx.captures.len and ctx.captures[capIdx].a >= 0:
            condMet = true
            break
    of ckAlwaysFalse:
      condMet = false
    of ckAlwaysTrue:
      condMet = true
    of ckRegexCond:
      # Match the condition regex at current position (consuming)
      if node.condBody != nil:
        if node.condBody.kind == nkLookaround and node.condBody.lookKind == lkNegAhead:
          # For negative lookaround conditions, evaluate the body directly.
          # When the body matches (negative lookaround fails → condition false),
          # we still need to preserve captures from the body match.
          let saved = save(ctx)
          let bodyMatch = matchWithCont(ctx, node.condBody.lookBody, trueCont)
          let capsAfterBody = ctx.captures
          restore(ctx, saved)
          if not bodyMatch:
            condMet = true # negative lookaround succeeded
          else:
            condMet = false # negative lookaround failed, preserve captures
            ctx.captures = capsAfterBody
        else:
          let saved = save(ctx)
          if matchWithCont(ctx, node.condBody, trueCont):
            # Condition matched — condMet = true, pos is advanced past condition
            condMet = true
          else:
            restore(ctx, saved)
    if condMet:
      matchWithCont(ctx, node.condYes, cont)
    elif node.condNo != nil:
      matchWithCont(ctx, node.condNo, cont)
    elif node.condKind in {ckBackref, ckNamedRef}:
      false # backref condition false with no else-branch → fail
    else:
      cont(ctx) # regex/other condition false with no else-branch → empty match
  of nkAbsent:
    matchAbsent(ctx, node, cont)
  of nkCalloutMax:
    let tag = node.maxTag
    let cur = ctx.calloutCounters.getOrDefault(tag, 0)
    if cur >= node.maxCount:
      return false
    ctx.calloutCounters[tag] = cur + 1
    let ok = cont(ctx)
    if not ok:
      ctx.calloutCounters[tag] = cur # backtrack
    ok
  of nkCalloutCount:
    let tag = node.countTag
    let cur = ctx.calloutCounters.getOrDefault(tag, 0)
    ctx.calloutCounters[tag] = cur + 1
    let ok = cont(ctx)
    if not ok:
      ctx.calloutCounters[tag] = cur # backtrack
    ok
  of nkCalloutCmp:
    let left = ctx.calloutCounters.getOrDefault(node.cmpLeft, 0)
    let right = ctx.calloutCounters.getOrDefault(node.cmpRight, 0)
    let cmpResult =
      case node.cmpOp
      of "<":
        left < right
      of ">":
        left > right
      of "==":
        left == right
      of "!=":
        left != right
      of "<=":
        left <= right
      of ">=":
        left >= right
      else:
        false
    if cmpResult:
      return cont(ctx)
    false

proc matchNode(ctx: var MatchContext, node: Node): bool =
  matchWithCont(ctx, node, trueCont)

proc initMatchContext(
    subject: string, regex: Regex, stepLimit: int, maxRecursionDepth: int
): MatchContext =
  let capCount = regex.captureCount
  result = MatchContext(
    subject: subject,
    flags: regex.flags,
    regex: regex,
    subjectEnd: subject.len,
    stepLimit: stepLimit,
    maxRecursionDepth: maxRecursionDepth,
  )
  result.captures = newSeq[Span](capCount + 1)
  result.groupRecursionDepth = newSeq[int](capCount)
  result.captureStacks = newSeq[seq[Span]](capCount)

proc resetForPosition(ctx: var MatchContext, startPos: int, searchStart: int) =
  ## Reset per-position state without reallocating.
  ctx.pos = startPos
  ctx.flags = ctx.regex.flags
  ctx.searchStart = searchStart
  ctx.keepStart = startPos
  ctx.subjectEnd = ctx.subject.len
  ctx.recursionDepth = 0
  ctx.callDepth = 0
  for i in 0 ..< ctx.captures.len:
    ctx.captures[i] = UnsetSpan
  for i in 0 ..< ctx.groupRecursionDepth.len:
    ctx.groupRecursionDepth[i] = 0
  for i in 0 ..< ctx.captureStacks.len:
    ctx.captureStacks[i].setLen(0)
  if ctx.calloutCounters.len > 0:
    ctx.calloutCounters.clear()
  ctx.graphemeMode = gmNone

proc writeFoundCopy(m: var Match, captures: seq[Span]) {.inline.} =
  ## Fill ``m`` in place from a capture vector, reusing ``m.boundaries``'
  ## existing capacity when possible.  Used when ``captures`` is still
  ## live (e.g. inside the findLongest closure, which may re-enter).
  m.found = true
  m.boundaries.setLen(captures.len)
  for i in 0 ..< captures.len:
    m.boundaries[i] = captures[i]

proc writeFoundMove(m: var Match, captures: var seq[Span]) {.inline.} =
  ## Fill ``m`` by moving ``captures`` into ``m.boundaries``.  The caller
  ## must guarantee ``captures`` is no longer used (typically the
  ## MatchContext is about to go out of scope).  Saves both a heap copy
  ## of the span vector and — on the common ``search`` return path — the
  ## separate allocation the compiler would otherwise make for the
  ## value-returned Match's ``boundaries``.
  m.found = true
  m.boundaries = move(captures)

proc writeNotFound(m: var Match) {.inline.} =
  m.found = false
  m.boundaries.setLen(0)

proc searchImplInto*(
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
) =
  ## In-place variant of ``searchImpl``. Writes the result into ``m``,
  ## moving ``ctx.captures`` into ``m.boundaries`` on the found path so
  ## that the extra seq copy of the value-returning API is avoided.
  ## (``m.boundaries``' previous buffer is released by the move; it is
  ## not reused across top-level calls. Capacity reuse happens only
  ## within the ``findLongest`` closure, which updates ``bestMatch``
  ## in place via ``setLen``.)
  let findLongest = rfFindLongest in regex.flags
  var bestLen = -1
  # ``m`` is a ``var`` parameter and cannot be captured by the findLongest
  # closure (Nim would reject it for memory safety). Use a local ``Match``
  # for that path and copy into ``m`` at the end.
  var bestMatch: Match
  writeNotFound(m)
  # Quick reject: if the pattern requires a specific byte, check its presence
  let rb = regex.requiredByte
  if rb.valid:
    var found = false
    for i in start ..< subject.len:
      if subject[i].uint8 == rb.byte:
        found = true
        break
    if not found:
      return
  var ctx = initMatchContext(subject, regex, stepLimit, maxRecursionDepth)
  let fc = regex.firstCharInfo
  var startPos = start
  while startPos <= subject.len:
    # Fast skip based on first character optimization
    case fc.kind
    of fcAnchorStart:
      if startPos != 0:
        break
    of fcByte:
      # Scan forward to next occurrence of the required first byte
      var found = false
      while startPos < subject.len:
        if subject[startPos].uint8 == fc.byte:
          found = true
          break
        inc startPos
      if not found:
        break
    of fcByteSet:
      var found = false
      while startPos < subject.len:
        if subject[startPos].uint8 in fc.bytes:
          found = true
          break
        inc startPos
      if not found:
        break
    of fcNone:
      discard
    resetForPosition(ctx, startPos, start)

    if findLongest:
      # Find longest: try all match alternatives at this position.  The
      # closure re-enters and mutates ctx.captures, so we must copy (not
      # move) out of it here.
      let sp = startPos
      var matchCont: MatchCont
      matchCont = proc(ctx: var MatchContext): bool =
        let mLen = ctx.pos - sp
        if mLen > bestLen:
          bestLen = mLen
          writeFoundCopy(bestMatch, ctx.captures)
          bestMatch.boundaries[0] = span(sp, ctx.pos)
          if ctx.keepStart != sp:
            bestMatch.boundaries[0].a = ctx.keepStart
        false # return false to force backtracking for more alternatives
      discard matchWithCont(ctx, regex.ast, matchCont)
    else:
      if matchNode(ctx, regex.ast):
        ctx.captures[0] = span(startPos, ctx.pos)
        if ctx.keepStart != startPos:
          ctx.captures[0].a = ctx.keepStart
        # ctx is local and dies when we return — steal its captures
        # buffer instead of copying.
        writeFoundMove(m, ctx.captures)
        return

    # Advance to next UTF-8 code point boundary
    if startPos >= subject.len:
      break
    inc startPos
    while startPos < subject.len and (subject[startPos].uint8 and 0xC0'u8) == 0x80'u8:
      inc startPos

  if findLongest and bestMatch.found:
    writeFoundMove(m, bestMatch.boundaries)

proc searchImpl*(
    subject: string,
    regex: Regex,
    start: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  searchImplInto(
    subject,
    regex,
    result,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc searchBackwardImplInto*(
    subject: string,
    regex: Regex,
    m: var Match,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
) =
  ## In-place variant of ``searchBackwardImpl``.
  writeNotFound(m)
  # Quick reject: if the pattern requires a specific byte, check its presence
  let rb = regex.requiredByte
  if rb.valid:
    var found = false
    for i in 0 ..< subject.len:
      if subject[i].uint8 == rb.byte:
        found = true
        break
    if not found:
      return
  var ctx = initMatchContext(subject, regex, stepLimit, maxRecursionDepth)
  let fc = regex.firstCharInfo
  var startPos =
    if start >= 0:
      min(start, subject.len)
    else:
      subject.len
  while startPos >= 0:
    # Fast skip based on first character optimization
    case fc.kind
    of fcAnchorStart:
      if startPos != 0:
        startPos = 0
        continue
    of fcByte:
      while startPos > 0 and startPos < subject.len and
          subject[startPos].uint8 != fc.byte:
        dec startPos
        while startPos > 0 and (subject[startPos].uint8 and 0xC0'u8) == 0x80'u8:
          dec startPos
      if startPos < subject.len and subject[startPos].uint8 != fc.byte:
        break
    of fcByteSet:
      while startPos > 0 and startPos < subject.len and
          subject[startPos].uint8 notin fc.bytes:
        dec startPos
        while startPos > 0 and (subject[startPos].uint8 and 0xC0'u8) == 0x80'u8:
          dec startPos
      if startPos < subject.len and subject[startPos].uint8 notin fc.bytes:
        break
    of fcNone:
      discard

    # \G in backward search anchors at the end of the string (the origin of
    # the backward scan), not at each candidate start position.
    resetForPosition(ctx, startPos, subject.len)

    if matchNode(ctx, regex.ast):
      ctx.captures[0] = span(startPos, ctx.pos)
      if ctx.keepStart != startPos:
        ctx.captures[0].a = ctx.keepStart
      writeFoundMove(m, ctx.captures)
      return

    if startPos == 0:
      break
    dec startPos
    while startPos > 0 and (subject[startPos].uint8 and 0xC0'u8) == 0x80'u8:
      dec startPos

proc searchBackwardImpl*(
    subject: string,
    regex: Regex,
    start: int = -1,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Search backward: try starting positions from right to left,
  ## return the first (rightmost) forward match found.
  ## If start >= 0, begin scanning from that position instead of the end.
  searchBackwardImplInto(
    subject,
    regex,
    result,
    start = start,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )

proc matchAtImplInto*(
    subject: string,
    regex: Regex,
    m: var Match,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
) =
  ## In-place variant of ``matchAtImpl``.
  writeNotFound(m)
  var ctx = initMatchContext(subject, regex, stepLimit, maxRecursionDepth)
  resetForPosition(ctx, pos, pos)
  if matchNode(ctx, regex.ast):
    ctx.captures[0] = span(pos, ctx.pos)
    if ctx.keepStart != pos:
      ctx.captures[0].a = ctx.keepStart
    writeFoundMove(m, ctx.captures)

proc matchAtImpl*(
    subject: string,
    regex: Regex,
    pos: int = 0,
    stepLimit: int = DefaultStepLimit,
    maxRecursionDepth: int = DefaultMaxRecursionDepth,
): Match =
  ## Try to match only at the given position (no scanning).
  matchAtImplInto(
    subject,
    regex,
    result,
    pos = pos,
    stepLimit = stepLimit,
    maxRecursionDepth = maxRecursionDepth,
  )
