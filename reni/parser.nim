import std/unicode
from std/strutils import find

import types, charclass, unicode_utils, stackguard, leafgate

type Parser* = object
  src: string
  pos: int
  flags: RegexFlags
  captureCount*: int
  namedCaptures*: seq[(string, int)]
  depth: int
  stackBase: int
    ## Parse start frame for the byte-budget check.
    ## Level caps alone cannot bound bytes since per-level cost varies.
  captureDepth: int ## nesting depth inside capture groups
  concatNodeCount: int ## number of nodes already parsed at current concat level
  inNonFirstBranch: bool ## true when parsing non-first alternation branch
  atOptionPrefix: bool
    ## Still inside the run of ``(?:`` / ``(?flags:`` wrappers the pattern opens
    ## with, which is the only place a [LeadingOnlyFlags] group may sit.
  sawLeadingOnlyOption: bool ## a [LeadingOnlyFlags] group has already been taken
  requiresExclusive: bool
    ## true once a [LeadingOnlyFlags] group has been taken and now requires
    ## being the only node of the pattern -- both the scoped ``(?I:a)`` form
    ## and the isolated ``(?I)a`` one, which spans the rest of its own group
    ## but still may not have siblings outside the wrappers around it.
  inLiteralQuote: bool ## true when inside \Q...\E
  sawPlainGroup*: bool
    ## True once a ``(?:...)`` with a body has been parsed, so the compiler can
    ## skip [flattenLiteralGroups] when there is nothing to find.
  sawAbsent*: bool
    ## True once a ``(?~...)`` has been parsed, so the compiler can skip the
    ## passes that only look for absent operators.
  sawGroupRead*: bool
    ## True once a backreference, or a conditional that reads a group or may
    ## (see ``parseConditional``), has been parsed, so the compiler can skip
    ## ``markGroupReads`` when nothing reads a group.
  sawBareNameCondition*: bool
    ## True once a condition whose text may be a group's name has been parsed,
    ## so the compiler can skip ``resolveBareNameConditions`` without one.
  sawCall*: bool
    ## True once a subexpression call has been parsed, so the compiler can
    ## skip ``checkNeverEndingRecursion`` when nothing calls a group.
  branchlessNames*: seq[(string, int)]
    ## Each bare-name condition with no branch, ``(?(n))``, and where the
    ## ``)`` after it is.  The name has to be a group's, which ``re`` checks
    ## once every group is known.

const
  MaxNestingDepth = 256
  MaxRepeat* = 100_000
    ## Largest count a quantifier may spell.  Exported because the compiler's
    ## nested-repeat collapse multiplies two of them and has to refuse the
    ## same overflow this parser does.
  FlagChars = {'i', 'm', 's', 'x', 'W', 'D', 'S', 'P', 'I', 'L'}
  LeadingOnlyFlags = {rfIgnoreCaseAscii, rfFindLongest}
    ## ``I`` and ``L``.  Oniguruma takes these in one group at the very start of
    ## the pattern and nowhere else, and never lets them be cleared.

proc initParser*(pattern: string, flags: RegexFlags = {}): Parser =
  ## Records ``stackBase`` here so nested lookaround re-entry shares one base.
  Parser(
    src: pattern,
    pos: 0,
    flags: flags,
    stackBase: currentStackAddr(),
    atOptionPrefix: true,
  )

proc atEnd*(p: Parser): bool =
  p.pos >= p.src.len

proc position*(p: Parser): int =
  p.pos

proc currentFlags*(p: Parser): RegexFlags =
  p.flags

proc peek(p: Parser): char =
  if p.atEnd:
    '\0'
  else:
    p.src[p.pos]

proc advance(p: var Parser) =
  if not p.atEnd:
    inc p.pos

proc advanceRune(p: var Parser): Rune =
  var r: Rune
  fastRuneAt(p.src, p.pos, r, true)
  r

proc error(p: Parser, msg: string, at: int) {.noreturn.} =
  raise newException(RegexError, msg & " at position " & $at)

proc error(p: Parser, msg: string) {.noreturn.} =
  p.error(msg, p.pos)

proc expect(p: var Parser, ch: char) =
  if p.peek != ch:
    p.error("expected '" & ch & "'")
  p.advance()

proc appendDecimal(value: var int, digit: char) =
  let n = ord(digit) - ord('0')
  if value > (high(int) - n) div 10:
    raise newException(RegexError, "numeric regex argument is too large")
  value = value * 10 + n

proc callNode(p: var Parser, index: int, name: string): Node =
  ## A subexpression call, noted in ``p.sawCall``.
  p.sawCall = true
  Node(kind: nkSubexpCall, callIndex: index, callName: name)

proc relativeForwardIndex(p: Parser, index: int): int =
  if index > high(int) - p.captureCount:
    p.error("relative capture reference is too large")
  p.captureCount + index

type
  GroupRefKind = enum
    grNumber ## ``n``
    grRelative ## ``-n`` or ``+n``
    grName

  GroupRef = object ## A reference to a group, as [readGroupRef] reads it.
    kind: GroupRefKind
    number: int ## signed for grRelative
    name: string ## for grName
    level: int ## signed; 0 when there is none
    leveled: bool
    levelAt: int ## where the level's sign is in the text

proc scanGroupNumber(text: string, i: var int, value: var int): bool =
  ## Read the digits at ``i`` into ``value``.  False when there are none, or
  ## when they pass ``high(int32)``, where Oniguruma's ``scan_number`` gives up.
  let start = i
  value = 0
  while i < text.len and text[i] in {'0' .. '9'}:
    let digit = ord(text[i]) - ord('0')
    if value > (high(int32) - digit) div 10:
      return false
    value = value * 10 + digit
    inc i
  i > start

proc readLevel(text: string, at: int, r: var GroupRef): bool =
  ## Read the level whose sign is at ``at`` into ``r``, if digits alone run
  ## from there to the end of ``text``.
  var i = at + 1
  var level: int
  if not scanGroupNumber(text, i, level) or i != text.len:
    return false
  r.level =
    if text[at] == '-':
      -level
    else:
      level
  r.leveled = true
  r.levelAt = at
  true

proc readGroupRef(text: string): GroupRef =
  ## Read ``text``, what stands between the delimiters of ``\k<...>`` or of a
  ## condition, as Oniguruma's ``fetch_name_with_level`` does: a number ``n``,
  ## ``-n`` or ``+n``, or a name, then perhaps a level ``+n`` or ``-n``.  Any
  ## other text is a name whole, since a name need not be word characters
  ## (``(?<a-b>x)``).  Oniguruma rejects a relative ``±0``, a number past
  ## ``high(int32)`` and ``1a``; as names no group has, they fail here too.
  let signed = text.len > 0 and text[0] in {'-', '+'}
  var i = ord(signed)
  var number: int
  if scanGroupNumber(text, i, number) and not (signed and number == 0):
    result = GroupRef(
      kind: if signed: grRelative else: grNumber,
      number:
        if text[0] == '-':
          -number
        else:
          number,
    )
    if i == text.len or (text[i] in {'-', '+'} and text.readLevel(i, result)):
      return
  result = GroupRef(kind: grName, name: text)
  for at in 1 ..< text.len:
    if text[at] in {'-', '+'}:
      if text.readLevel(at, result):
        result.name = text[0 ..< at]
      break

proc readBareGroupRef(p: var Parser, r: var GroupRef): bool =
  ## Read the condition at ``p.pos`` and the ``)`` after it if it is a group
  ## number with no delimiters, as [readGroupRef] reads one.  Oniguruma reads
  ## any other condition as a pattern, so ``(?(1a)``, ``(?(-)``, ``(?(1+)``
  ## and ``(?(2147483648)`` match their own text.
  var i = p.pos
  while i < p.src.len and p.src[i] in {'0' .. '9', '-', '+'}:
    inc i
  if i == p.src.len or p.src[i] != ')':
    return false
  r = readGroupRef(p.src[p.pos ..< i])
  if r.kind == grName:
    return false
  p.pos = i + 1
  true

proc groupIndex(p: Parser, r: GroupRef): int =
  ## The number of the group ``r`` refers to by number.  A relative one counts
  ## from the groups opened so far: ``-1`` is the last, ``+1`` the next.
  if r.kind == grNumber:
    r.number
  elif r.number < 0:
    p.captureCount + r.number + 1
  else:
    p.relativeForwardIndex(r.number)

proc charToFlag(ch: char): RegexFlag =
  case ch
  of 'i':
    rfIgnoreCase
  of 'm', 's':
    rfMultiLine # 's' is PCRE2/Perl alias for Oniguruma's 'm' (dot matches newline)
  of 'x':
    rfExtended
  of 'W':
    rfAsciiWord
  of 'D':
    rfAsciiDigit
  of 'S':
    rfAsciiSpace
  of 'P':
    rfAsciiPosix
  of 'I':
    rfIgnoreCaseAscii
  of 'L':
    rfFindLongest
  else:
    doAssert false, "unreachable"
    rfIgnoreCase

proc skipWhitespaceAndComments(p: var Parser) =
  if rfExtended notin p.flags:
    return
  while not p.atEnd:
    let ch = p.peek
    if ch in {' ', '\t', '\n', '\r', '\f', '\x0B'}:
      p.advance()
    elif ch == '#':
      while not p.atEnd and p.peek != '\n':
        p.advance()
      if not p.atEnd:
        p.advance() # skip newline
    else:
      break

proc parseQuantifier(p: var Parser, body: Node): Node =
  var qmin, qmax: int
  var isBrace = false
  var braceHasComma = false
  let ch = p.peek
  case ch
  of '*':
    p.advance()
    qmin = 0
    qmax = -1
  of '+':
    p.advance()
    qmin = 1
    qmax = -1
  of '?':
    p.advance()
    qmin = 0
    qmax = 1
  of '{':
    isBrace = true
    let startPos = p.pos
    p.advance() # skip '{'
    # Parse {n}, {n,}, {n,m}, {,m}
    var n = -1
    var m = -1
    # Parse first number (optional)
    if p.peek in {'0' .. '9'}:
      n = 0
      while p.peek in {'0' .. '9'}:
        if n > MaxRepeat:
          p.error("quantifier value too large (max " & $MaxRepeat & ")")
        appendDecimal(n, p.peek)
        p.advance()
    if p.peek == ',':
      braceHasComma = true
      p.advance()
      # Parse second number (optional)
      if p.peek in {'0' .. '9'}:
        m = 0
        while p.peek in {'0' .. '9'}:
          if m > MaxRepeat:
            p.error("quantifier value too large (max " & $MaxRepeat & ")")
          appendDecimal(m, p.peek)
          p.advance()
    if p.peek == '}':
      p.advance()
      if braceHasComma:
        if n < 0 and m < 0:
          # {,} - no numbers at all, treat as literal
          p.pos = startPos
          return body
        if n < 0:
          n = 0 # {,m}
        if n > MaxRepeat or m > MaxRepeat:
          p.error("quantifier value too large (max " & $MaxRepeat & ")")
        qmin = n
        qmax = m # -1 if no second number = unbounded
      else:
        if n < 0:
          # Empty braces {} - treat as literal
          p.pos = startPos
          return body
        if n > MaxRepeat:
          p.error("quantifier value too large (max " & $MaxRepeat & ")")
        qmin = n
        qmax = n # {n}
    else:
      # Not a valid quantifier, treat '{' as literal
      p.pos = startPos
      return body
  else:
    return body

  # Check for lazy or possessive suffix
  # For brace quantifiers in Oniguruma:
  # - '+' after {..} is always chaining (a new quantifier), never possessive
  # - '?' after {n} (no comma) is chaining, after {n,m} is lazy suffix
  p.skipWhitespaceAndComments()
  var qkind = qkGreedy
  if not p.atEnd:
    if p.peek == '?':
      if isBrace and (not braceHasComma or (qmin > qmax and qmax >= 0)):
        discard # {n}? or {n,m}? (n>m) = chaining, don't consume
      else:
        qkind = qkLazy
        p.advance()
    elif p.peek == '+':
      if isBrace:
        discard # {..}+ = chaining, don't consume
      else:
        qkind = qkPossessive
        p.advance()

  # Check for quantifier chain overflow (only for exact-count chains)
  if body.kind == nkQuantifier:
    let innerMin = body.quantMin
    let innerMax = body.quantMax
    # Only error when both quantifiers are exact or have the same min/max
    let innerExact = innerMin == innerMax and innerMax >= 0
    let outerExact = qmin == qmax and qmax >= 0
    if innerExact and outerExact:
      if innerMin > 0 and qmin > 0 and innerMin > MaxRepeat div qmin:
        p.error("too big number for repeat range")

  Node(
    kind: nkQuantifier,
    quantMin: qmin,
    quantMax: qmax,
    quantKind: qkind,
    quantBody: body,
  )

proc isQuantifiable(node: Node): bool =
  ## Check if a node can be the target of a quantifier.
  case node.kind
  of nkAnchor:
    false
  of nkFlagGroup:
    node.flagBody != nil # scoped (?i:...) is quantifiable; isolated (?i) is not
  of nkLookaround:
    true # (?=abc){0}, (?=(a))?
  else:
    true

proc parseEscape(p: var Parser): Node =
  p.expect('\\')
  if p.atEnd:
    p.error("unexpected end after '\\'")

  let ch = p.peek
  case ch
  of 'w':
    p.advance()
    result = Node(kind: nkCharType, charType: ctWord)
  of 'W':
    p.advance()
    result = Node(kind: nkCharType, charType: ctNotWord)
  of 'd':
    p.advance()
    result = Node(kind: nkCharType, charType: ctDigit)
  of 'D':
    p.advance()
    result = Node(kind: nkCharType, charType: ctNotDigit)
  of 's':
    p.advance()
    result = Node(kind: nkCharType, charType: ctSpace)
  of 'S':
    p.advance()
    result = Node(kind: nkCharType, charType: ctNotSpace)
  of 'h':
    p.advance()
    result = Node(kind: nkCharType, charType: ctHexDigit)
  of 'H':
    p.advance()
    result = Node(kind: nkCharType, charType: ctNotHexDigit)
  of 'b':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akWordBoundary)
  of 'B':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akNotWordBoundary)
  of 'O':
    p.advance()
    result = Node(kind: nkCharType, charType: ctAnyChar)
  of 'R':
    p.advance()
    result = Node(kind: nkCharType, charType: ctNewlineSeq)
  of 'N':
    p.advance()
    result = Node(kind: nkCharType, charType: ctNotNewline)
  of 'X':
    p.advance()
    result = Node(kind: nkCharType, charType: ctGraphemeCluster)
  of 'y':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akGraphemeBoundary)
  of 'Y':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akNotGraphemeBoundary)
  of 'A':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akStringBegin)
  of 'z':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akStringEnd)
  of 'Z':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akStringEndOrNewline)
  of 'G':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akSearchBegin)
  of 'K':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akKeep)
  of 'n':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x0A))
  of 't':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x09))
  of 'r':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x0D))
  of 'f':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x0C))
  of 'a':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x07))
  of 'e':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x1B))
  of 'v':
    p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(0x0B))
  of '1' .. '9':
    # \1-\9 are always backreferences (supports forward references).
    # For multi-digit (\10+): backref if index <= captureCount, else octal.
    p.advance()
    var idxStr = $ch
    while p.peek in {'0' .. '9'}:
      idxStr.add(p.peek)
      p.advance()
    var idx = 0
    for c in idxStr:
      let digit = ord(c) - ord('0')
      if idx > (high(int) - digit) div 10:
        idx = high(int)
        break
      appendDecimal(idx, c)
    if idxStr.len == 1 or idx <= p.captureCount:
      # Single digit (\1-\9) or valid multi-digit backref
      result = Node(kind: nkBackreference, backrefIndex: idx)
      p.sawGroupRead = true
    elif ch in {'1' .. '7'}:
      # Multi-digit, invalid capture: treat leading octal digits as octal
      p.pos -= idxStr.len # back up to first digit
      p.advance() # consume first digit
      var octStr = $ch
      for _ in 0 ..< 2:
        if p.peek in {'0' .. '7'}:
          octStr.add(p.peek)
          p.advance()
        else:
          break
      result = Node(kind: nkEscapedLiteral, escapedRune: Rune(parseOctInt(octStr)))
    else:
      # First digit is 8 or 9, can't be octal: treat as backref
      result = Node(kind: nkBackreference, backrefIndex: idx)
      p.sawGroupRead = true
  of 'x':
    p.advance()
    if p.peek == '{':
      p.advance()
      # Multi-codepoint: \x{000A 002f} = sequence of U+000A, U+002F
      var codepoints: seq[Rune]
      while p.peek in {' ', '\t', '\n', '\r'}:
        p.advance()
      while true:
        var hexStr = ""
        while p.peek in HexDigits:
          hexStr.add(p.peek)
          p.advance()
        if hexStr.len == 0:
          if p.peek == '}':
            break
          p.error("invalid code point value")
        if hexStr.len > 8:
          p.error("hex escape value too large")
        let cp = parseHexInt(hexStr)
        if cp > 0x10FFFF:
          p.error("invalid code point (> U+10FFFF)")
        codepoints.add(Rune(cp))
        while p.peek in {' ', '\t', '\n', '\r'}:
          p.advance()
      if codepoints.len == 0:
        p.error("empty hex escape")
      p.expect('}')
      if codepoints.len == 1:
        result = Node(kind: nkEscapedLiteral, escapedRune: codepoints[0])
      else:
        var nodes: seq[Node]
        for cp in codepoints:
          nodes.add(Node(kind: nkEscapedLiteral, escapedRune: cp))
        result = Node(kind: nkConcat, children: nodes)
    else:
      var hexStr = ""
      for _ in 0 ..< 2:
        if p.peek in HexDigits:
          hexStr.add(p.peek)
          p.advance()
        else:
          break
      if hexStr.len == 0:
        p.error("invalid hex escape")
      let val = parseHexInt(hexStr)
      if val <= 0x7F:
        result = Node(kind: nkEscapedLiteral, escapedRune: Rune(val))
      elif val >= 0xF5:
        p.error("invalid code point value")
      elif val >= 0x80 and val <= 0xBF:
        p.error("invalid code point value") # continuation byte without lead
      else:
        # UTF-8 lead byte — try to consume continuation \xHH bytes
        var bytes: seq[uint8] = @[uint8(val)]
        let needed =
          if val >= 0xF0:
            3
          elif val >= 0xE0:
            2
          else:
            1
        let savedPos = p.pos
        for i in 0 ..< needed:
          if p.pos + 3 < p.src.len and p.src[p.pos] == '\\' and p.src[p.pos + 1] == 'x':
            let h1 = p.src[p.pos + 2]
            var h2 = '\0'
            var hlen = 1
            if p.pos + 3 < p.src.len and p.src[p.pos + 3] in HexDigits:
              h2 = p.src[p.pos + 3]
              hlen = 2
            if h1 in HexDigits:
              var hs = $h1
              if hlen == 2:
                hs.add(h2)
              let bval = parseHexInt(hs)
              if bval >= 0x80 and bval <= 0xBF:
                bytes.add(uint8(bval))
                p.pos += 2 + hlen # skip \xHH
              else:
                break
            else:
              break
          else:
            break
        if bytes.len == needed + 1:
          # Decode UTF-8 sequence
          var cp: uint32
          case needed
          of 1:
            cp = (uint32(bytes[0]) and 0x1F) shl 6 or (uint32(bytes[1]) and 0x3F)
          of 2:
            cp =
              (uint32(bytes[0]) and 0x0F) shl 12 or (uint32(bytes[1]) and 0x3F) shl 6 or
              (uint32(bytes[2]) and 0x3F)
          of 3:
            cp =
              (uint32(bytes[0]) and 0x07) shl 18 or (uint32(bytes[1]) and 0x3F) shl 12 or
              (uint32(bytes[2]) and 0x3F) shl 6 or (uint32(bytes[3]) and 0x3F)
          else:
            discard
          if cp > 0x10FFFF'u32:
            p.error("invalid code point value")
          result = Node(kind: nkEscapedLiteral, escapedRune: Rune(cp))
        else:
          p.pos = savedPos
          p.error("too short multi-byte string")
  of 'u':
    p.advance()
    var hexStr = ""
    for _ in 0 ..< 4:
      if p.peek in HexDigits:
        hexStr.add(p.peek)
        p.advance()
      else:
        break
    if hexStr.len != 4:
      p.error("\\u requires exactly 4 hex digits")
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(parseHexInt(hexStr)))
  of 'o':
    p.advance()
    p.expect('{')
    # Multi-codepoint: \o{102 103} = sequence of octal values
    var codepoints: seq[Rune]
    while p.peek in {' ', '\t', '\n', '\r'}:
      p.advance()
    while true:
      var octStr = ""
      while p.peek in {'0' .. '7'}:
        octStr.add(p.peek)
        p.advance()
      if octStr.len == 0:
        break
      if octStr.len > 7:
        p.error("octal escape value too large")
      codepoints.add(Rune(parseOctInt(octStr)))
      while p.peek in {' ', '\t', '\n', '\r'}:
        p.advance()
    if codepoints.len == 0:
      p.error("empty octal escape")
    p.expect('}')
    if codepoints.len == 1:
      result = Node(kind: nkEscapedLiteral, escapedRune: codepoints[0])
    else:
      var nodes: seq[Node]
      for cp in codepoints:
        nodes.add(Node(kind: nkEscapedLiteral, escapedRune: cp))
      result = Node(kind: nkConcat, children: nodes)
  of '0':
    p.advance()
    var octStr = "0"
    for _ in 0 ..< 2:
      if p.peek in {'0' .. '7'}:
        octStr.add(p.peek)
        p.advance()
      else:
        break
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(parseOctInt(octStr)))
  of 'c':
    p.advance()
    if p.atEnd:
      p.error("unexpected end after '\\c'")
    var ctrlCh: char
    if p.peek == '\\':
      # \c\\ = control of '\', \c\n = control of 'n' etc.
      p.advance() # skip first '\'
      if p.atEnd:
        p.error("unexpected end after '\\c\\'")
      ctrlCh = p.peek
      p.advance()
    else:
      ctrlCh = p.peek
      p.advance()
    result = Node(kind: nkEscapedLiteral, escapedRune: Rune(ord(ctrlCh) and 0x1F))
  of 'C':
    p.advance()
    if p.peek == '-':
      p.advance()
      if p.atEnd:
        p.error("unexpected end after '\\C-'")
      let ctrlCh = p.peek
      p.advance()
      result = Node(kind: nkEscapedLiteral, escapedRune: Rune(ord(ctrlCh) and 0x1F))
    else:
      p.error("expected '-' after '\\C'")
  of 'p':
    p.advance()
    var name = ""
    var at = p.pos
    if p.peek == '{':
      p.advance()
      at = p.pos
      while p.peek != '}' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      p.expect('}')
    elif p.atEnd or p.peek notin PropertyLetters:
      return Node(kind: nkEscapedLiteral, escapedRune: Rune(ord('p')))
    else:
      name.add(p.peek)
      p.advance()
    # \p{^Prop} = negated property
    if name.len > 0 and name[0] == '^':
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[
          CcAtom(kind: ccNegUnicodeProp, prop: p.propertyNamed(name[1 ..^ 1], at + 1))
        ],
      )
    else:
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[CcAtom(kind: ccUnicodeProp, prop: p.propertyNamed(name, at))],
      )
  of 'P':
    p.advance()
    var name = ""
    var at = p.pos
    if p.peek == '{':
      p.advance()
      at = p.pos
      while p.peek != '}' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      p.expect('}')
    elif p.atEnd or p.peek notin PropertyLetters:
      return Node(kind: nkEscapedLiteral, escapedRune: Rune(ord('P')))
    else:
      name.add(p.peek)
      p.advance()
    # \P{^Prop} = double negation = positive
    if name.len > 0 and name[0] == '^':
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms:
          @[CcAtom(kind: ccUnicodeProp, prop: p.propertyNamed(name[1 ..^ 1], at + 1))],
      )
    else:
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[CcAtom(kind: ccNegUnicodeProp, prop: p.propertyNamed(name, at))],
      )
  of 'k':
    p.advance()
    var name = ""
    if p.peek == '<':
      p.advance()
      while p.peek != '>' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      p.expect('>')
    elif p.peek == '\'':
      p.advance()
      while p.peek != '\'' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      p.expect('\'')
    elif p.peek == '{':
      p.advance()
      while p.peek != '}' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      p.expect('}')
    else:
      p.error("expected '<' or '\\'' after '\\k'")
    if name.len == 0:
      p.error("empty backreference name")
    let r = readGroupRef(name)
    if r.kind == grName:
      result = Node(
        kind: nkNamedBackref,
        backrefName: r.name,
        namedBackrefLevel: r.level,
        namedBackrefLeveled: r.leveled,
        backrefScope: int32(p.namedCaptures.len),
      )
    else:
      # A forward reference is bounds-checked at compile time.
      let idx = p.groupIndex(r)
      if idx < 1 and r.kind == grRelative:
        p.error("invalid relative backref '\\k<" & $r.number & ">'")
      result = Node(
        kind: nkBackreference,
        backrefIndex: idx,
        backrefLevel: r.level,
        backrefLeveled: r.leveled,
      )
    p.sawGroupRead = true
  of 'g':
    p.advance()
    var name = ""
    var closeChar = '\0'
    if p.peek == '<':
      closeChar = '>'
      p.advance()
    elif p.peek == '\'':
      closeChar = '\''
      p.advance()
    elif p.peek == '{':
      closeChar = '}'
      p.advance()
    elif p.peek in {'0' .. '9', '+', '-'}:
      # \g1, \g+1, \g-1 — bare numeric reference
      while not p.atEnd and p.peek in {'0' .. '9', '+', '-'}:
        name.add(p.peek)
        p.advance()
    else:
      p.error("expected '<' or '\\'' after '\\g'")
    if closeChar != '\0':
      while not p.atEnd and p.peek != closeChar:
        name.add(p.peek)
        p.advance()
      p.expect(closeChar)
    # Strip whitespace for \g{ ... } form
    if closeChar == '}':
      var stripped = ""
      for c in name:
        if c != ' ':
          stripped.add c
      name = stripped
    if name.len == 0:
      p.error("empty subexpression call")
    # Parse the reference: number, +n, -n, or name
    var callIndex = -1
    var callName = ""
    if name == "0":
      callIndex = 0 # \g<0> = entire pattern
    elif name[0] in {'0' .. '9'}:
      callIndex = 0
      for c in name:
        if c in {'0' .. '9'}:
          appendDecimal(callIndex, c)
        else:
          break
    elif name[0] == '+':
      var n = 0
      for i in 1 ..< name.len:
        if name[i] in {'0' .. '9'}:
          appendDecimal(n, name[i])
      callIndex = p.relativeForwardIndex(n)
    elif name[0] == '-':
      var n = 0
      for i in 1 ..< name.len:
        if name[i] in {'0' .. '9'}:
          appendDecimal(n, name[i])
      callIndex = p.captureCount - n + 1
      if callIndex < 1:
        p.error("invalid relative subexp call '\\g<-" & $n & ">'")
    else:
      callName = name
    result = p.callNode(callIndex, callName)
  of 'Q':
    p.advance()
    p.inLiteralQuote = true
    # Return the first character inside \Q as a literal
    if p.atEnd:
      p.inLiteralQuote = false
      result = Node(kind: nkConcat, children: @[])
    elif p.peek == '\\' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == 'E':
      p.pos += 2 # empty \Q\E
      p.inLiteralQuote = false
      result = Node(kind: nkConcat, children: @[])
    else:
      let r = p.advanceRune()
      result = Node(kind: nkLiteral, rune: r)
  of 'E':
    # \E outside \Q...\E — ignore (treat as empty)
    p.advance()
    result = Node(kind: nkConcat, children: @[])
  else:
    let r = p.advanceRune()
    result = Node(kind: nkEscapedLiteral, escapedRune: r)

proc parseCalloutVerb(p: var Parser): Node =
  ## Parse a backtracking control verb: (*FAIL), (*MAX{n}), etc.
  ## Called after '(' and '*' have been consumed.
  var verbName = ""
  while not p.atEnd and p.peek notin {')', '{', '[', '}', ']'}:
    verbName.add(p.peek)
    p.advance()
  # Oniguruma matches the names with case: ``(*fail)`` is an undefined callout.
  case verbName
  of "FAIL":
    while not p.atEnd and p.peek != ')':
      p.advance()
    Node(
      kind: nkLookaround,
      lookKind: lkNegAhead,
      lookBody: Node(kind: nkConcat, children: @[]),
      lookFail: true,
    )
  of "MAX":
    var tag = ""
    if p.peek == '[':
      p.advance()
      while not p.atEnd and p.peek != ']':
        tag.add(p.peek)
        p.advance()
      p.expect(']')
    p.expect('{')
    var numStr = ""
    while not p.atEnd and p.peek in {'0' .. '9'}:
      numStr.add(p.peek)
      p.advance()
    p.expect('}')
    var maxN = 0
    for digit in numStr:
      appendDecimal(maxN, digit)
    if tag.len == 0:
      tag = "__max_" & $p.pos
    Node(kind: nkCalloutMax, maxCount: maxN, maxTag: tag)
  of "COUNT":
    var tag = ""
    if p.peek == '[':
      p.advance()
      while not p.atEnd and p.peek != ']':
        tag.add(p.peek)
        p.advance()
      p.expect(']')
    var varName = ""
    if p.peek == '{':
      p.advance()
      while not p.atEnd and p.peek != '}':
        varName.add(p.peek)
        p.advance()
      p.expect('}')
    Node(kind: nkCalloutCount, countTag: tag, countVar: varName)
  of "CMP":
    p.expect('{')
    var left = ""
    while not p.atEnd and p.peek != ',':
      left.add(p.peek)
      p.advance()
    p.expect(',')
    var op = ""
    while not p.atEnd and p.peek notin {',', '}'}:
      op.add(p.peek)
      p.advance()
    p.expect(',')
    var right = ""
    while not p.atEnd and p.peek != '}':
      right.add(p.peek)
      p.advance()
    p.expect('}')
    Node(kind: nkCalloutCmp, cmpLeft: left, cmpOp: op, cmpRight: right)
  else:
    while not p.atEnd and p.peek != ')':
      p.advance()
    # PCRE's ``(*ACCEPT)``, ``(*PRUNE)``, ``(*COMMIT)`` and ``(*THEN)`` are
    # not Oniguruma callouts either.
    const KnownVerbs = ["TOTAL_COUNT", "SKIP", "MISMATCH", "ERROR"]
    if verbName notin KnownVerbs:
      p.error("undefined callout name '" & verbName & "'")
    Node(kind: nkGroup, groupBody: Node(kind: nkConcat, children: @[]))

proc setConditionRef(
    p: Parser,
    r: GroupRef,
    textStart: int,
    condKind: var ConditionalKind,
    condIndex: var int,
    condName: var string,
) =
  ## Make the condition the reference ``r``, read from the text at
  ## ``textStart``, delimited or not.
  # A level tests the group at another depth of recursion, which reni does
  # not follow for a condition, so only level 0, the group itself, is read.
  if r.level != 0:
    p.error(
      "a level in a conditional reference is not supported", textStart + r.levelAt
    )
  if r.kind == grName:
    condKind = ckNamedRef
    condName = r.name
  else:
    condKind = ckBackref
    condIndex = p.groupIndex(r)
    if condIndex < 1 and r.kind == grRelative:
      p.error("invalid relative conditional reference '(?(" & $r.number & "))'")

# Forward declarations
proc parseGroup(p: var Parser): Node
proc parseAlternation(p: var Parser): Node

type
  ShapeLevel = object
    stop: bool ## A possessive or atomic wrapper; a repeat when false.
    lo, hi: int
    greedy: bool

  Shape = object
    ## The node Oniguruma's parser makes of a pattern, as far as
    ## [oneCharRepeat] asks: how many wrappers and repeats it has, the two
    ## outermost of them, outermost first, and whether what they hold is one
    ## character.  A repeat reduces with the outermost level alone, and no
    ## shape of three levels is one character's repeat, so no more are kept:
    ## a repeat costs the same however many it stands on.
    levels: array[2, ShapeLevel]
    depth: int
    oneChar: bool

proc wrap(shape: var Shape, level: ShapeLevel) =
  ## Put ``level`` around what ``shape`` holds.
  shape.levels[1] = shape.levels[0]
  shape.levels[0] = level
  inc shape.depth

proc wrapRepeat(shape: var Shape, repeat: ShapeLevel, possessive: bool) =
  ## Oniguruma's ``assign_quantifier_body``, with
  ## ``onig_reduce_nested_quantifier``: put ``repeat`` around what ``shape``
  ## holds.  ``X{1}`` is X, and a repeat of a repeat may become one.
  if repeat.lo == 1 and repeat.hi == 1:
    return
  var outer = repeat
  if shape.depth > 0 and not shape.levels[0].stop:
    let inner = shape.levels[0]
    let outerType = quantTypeNum(outer.lo, outer.hi, outer.greedy)
    let innerType = quantTypeNum(inner.lo, inner.hi, inner.greedy)
    if innerType >= 0 and outerType < 0:
      # ``(?:a*){n,m}`` is ``(?:a*){n,n}``.
      if innerType in 1 .. 2 and outer.hi > 1 and outer.greedy:
        outer.hi = if outer.lo == 0: 1 else: outer.lo
      shape.wrap(outer)
    elif outerType < 0 or innerType < 0:
      if outer.lo == outer.hi and inner.lo == inner.hi and
          (inner.lo == 0 or outer.lo < int(high(int32)) div inner.lo):
        # Two exact counts multiply while Oniguruma's ``int`` holds the
        # product (``onig_positive_int_multiply``).  Past that it refuses
        # the pattern; here the pair stays as written, as
        # ``reduceNestedQuantifier`` leaves one past ``MaxRepeat``.
        let n = outer.lo * inner.lo
        shape.levels[0] = ShapeLevel(lo: n, hi: n, greedy: outer.greedy)
      else:
        shape.wrap(outer)
    else:
      case ReduceTable[innerType][outerType]
      of raAsIs:
        shape.wrap(outer)
      of raDel:
        discard
      of raStar:
        shape.levels[0] = ShapeLevel(lo: 0, hi: -1, greedy: true)
      of raPlus:
        shape.levels[0] = ShapeLevel(lo: 1, hi: -1, greedy: true)
      of raLazyStar:
        shape.levels[0] = ShapeLevel(lo: 0, hi: -1, greedy: false)
      of raLazyOpt:
        shape.levels[0] = ShapeLevel(lo: 0, hi: 1, greedy: false)
      of raPlusLazyOpt:
        shape.levels[0] = ShapeLevel(lo: 1, hi: -1, greedy: true)
        shape.wrap(ShapeLevel(lo: 0, hi: 1, greedy: false))
  else:
    shape.wrap(outer)
  if possessive:
    shape.wrap(ShapeLevel(stop: true))

proc shapeOf(node: Node, flags: RegexFlags): Shape =
  ## ``flags`` are those in force at ``node``: no flag group lies on the way
  ## to a node whose shape can be a loop's.
  if node == nil:
    return
  case node.kind
  of nkGroup:
    # Oniguruma's parser drops a ``(?:...)``.
    result = shapeOf(node.groupBody, flags)
  of nkAtomicGroup:
    result = shapeOf(node.atomicBody, flags)
    result.wrap(ShapeLevel(stop: true))
  of nkQuantifier:
    # An inverted interval is a possessive one there, as here.
    let (lo, hi) = effectiveQuantBounds(node.quantMin, node.quantMax)
    let possessive =
      node.quantKind == qkPossessive or isInvertedRange(node.quantMin, node.quantMax)
    result = shapeOf(node.quantBody, flags)
    result.wrapRepeat(
      ShapeLevel(lo: lo, hi: hi, greedy: node.quantKind != qkLazy), possessive
    )
  of nkLiteral, nkEscapedLiteral:
    result.oneChar = true
  of nkCharClass:
    # Unless Oniguruma's parser made it an alternation of the class and the
    # strings its characters fold to, or a type: a ``\p{Word}`` outside
    # ``[...]``, in either sense, is the node of ``\w`` there.
    let wordType =
      not node.bracketClass and node.atoms.len == 1 and
      node.atoms[0].kind in {ccUnicodeProp, ccNegUnicodeProp} and
      node.atoms[0].prop.kind == upWord
    result.oneChar = not wordType and not classHoldsFoldSource(node, flags)
  of nkString:
    result.oneChar = node.runes.len == 1
  of nkCharType:
    # Oniguruma makes these classes, and ``\w``, ``.`` and the rest a type.
    result.oneChar =
      node.charType in
      {ctDigit, ctNotDigit, ctSpace, ctNotSpace, ctHexDigit, ctNotHexDigit}
  else:
    discard

proc oneCharRepeat(expr: Node, flags: RegexFlags): tuple[found: bool, lo, hi: int32] =
  ## The bounds of ``expr`` when it is a greedy repeat of one character,
  ## alone, possessive or in an atomic group: what Oniguruma's
  ## ``is_simple_one_char_repeat`` looks for in the expression of
  ## ``(?~|X|E)``, in the node its parser makes of E under ``flags``.  That
  ## node drops each ``(?:...)`` and ``{1}``, and reduces a repeat of a repeat
  ## where it can: ``(?:a{0}){5}`` is ``a{0}``.  One character is a literal,
  ## a ``[...]``, a ``\p{...}``, ``\d``, ``\s`` or ``\h``, not a ``\w``,
  ## ``\p{Word}`` or ``.``, and not a ``[...]`` holding a character with a
  ## multi-character fold under ``(?i)``: ``(?i)[ß]`` is ``[ß]|ss`` there.
  ## Every bound fits an ``int32``: a product past it is no reduction.
  let shape = shapeOf(expr, flags)
  let at = if shape.depth > 0 and shape.levels[0].stop: 1 else: 0
  if shape.oneChar and shape.depth == at + 1 and not shape.levels[at].stop and
      shape.levels[at].greedy:
    result = (true, int32(shape.levels[at].lo), int32(shape.levels[at].hi))

proc recordStart(p: Parser, node: Node, start: int) =
  ## Write ``start``, where ``node`` starts in the pattern, into [patternPos],
  ## for the error ``validateLookbehinds`` raises.  An offset past
  ## ``high(int32)`` stays unrecorded, and the error there has no position.
  if start <= high(int32):
    node.patternPos = int32(start)

proc parseAtom(p: var Parser): Node =
  if p.atEnd:
    p.error("unexpected end of pattern")

  if p.inLiteralQuote:
    # Inside \Q...\E: check for \E terminator
    if p.peek == '\\' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == 'E':
      p.pos += 2 # skip \E
      p.inLiteralQuote = false
      # Return empty — parseConcat will continue with normal parsing
      return Node(kind: nkConcat, children: @[])
    # Everything is literal (including \, |, ), etc.)
    let r = p.advanceRune()
    return Node(kind: nkLiteral, rune: r)

  let ch = p.peek
  let start = p.pos
  case ch
  of '\\':
    result = p.parseEscape()
    p.recordStart(result, start)
  of '(':
    result = p.parseGroup()
    p.recordStart(result, start)
  of '.':
    p.advance()
    result = Node(kind: nkCharType, charType: ctDot)
  of '^':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akLineBegin)
  of '$':
    p.advance()
    result = Node(kind: nkAnchor, anchor: akLineEnd)
  of '[':
    let (newPos, node) = parseCharClass(p.src, p.pos, p.flags, p.stackBase)
    p.pos = newPos
    result = node
  of ')', '|':
    p.error("unexpected '" & ch & "'")
  of '*', '+', '?':
    p.error("nothing to repeat")
  else:
    # Literal rune
    let r = p.advanceRune()
    result = Node(kind: nkLiteral, rune: r)

proc repeatApplies(p: var Parser, body: Node): bool =
  ## Whether the repeat operator at ``p.pos`` applies to ``body``.  A ``{``
  ## that opens no interval does not: it is a literal after anything, and
  ## Oniguruma matches ``\G{a`` (the sassdoc grammar) and ``(?i){a`` against
  ## ``{a``.  Any other repeat of an anchor or an isolated option group is an
  ## error, whether it follows at once or after a ``(?#...)`` comment.
  if isQuantifiable(body):
    return true
  if p.peek == '{':
    let bracePos = p.pos
    discard p.parseQuantifier(body)
    if p.pos == bracePos:
      return false
    p.pos = bracePos
  if body.kind == nkFlagGroup and body.flagBody == nil:
    p.error("target of repeat operator not specified")
  p.error("target of repeat operator is not repeatable")

proc parseQuantified(p: var Parser): Node =
  var body = p.parseAtom()
  if p.inLiteralQuote:
    return body # no quantifiers inside \Q...\E
  # Empty node from \E — return as-is so parseConcat can attach quantifier to prev atom
  if body.kind == nkConcat and body.children.len == 0:
    return body
  # Support quantifier chaining: a?{2}, a*{0}, a+?{2}
  var first = true
  while true:
    p.skipWhitespaceAndComments()
    if p.atEnd or p.peek notin {'*', '+', '?', '{'}:
      break
    if first:
      first = false
      if not p.repeatApplies(body):
        break
    let posBefore = p.pos
    body = p.parseQuantifier(body)
    if p.pos == posBefore:
      break # '{' was literal, not a quantifier
  body

proc parseConcat(p: var Parser): Node =
  var nodes: seq[Node]
  let savedConcatCount = p.concatNodeCount
  p.concatNodeCount = 0
  while not p.atEnd:
    if not p.inLiteralQuote:
      p.skipWhitespaceAndComments()
    if p.atEnd:
      break
    let ch = p.peek
    if ch == '|' or ch == ')':
      if not p.inLiteralQuote:
        break
    # Skip comments (?#...), allowing trailing quantifiers to attach to previous atom
    if ch == '(' and p.pos + 2 < p.src.len and p.src[p.pos + 1] == '?' and
        p.src[p.pos + 2] == '#':
      p.advance()
      p.advance()
      p.advance()
      while not p.atEnd and p.peek != ')':
        p.advance()
      if not p.atEnd:
        p.advance() # skip ')'
      # If a quantifier follows and there's a previous atom, re-quantify it
      if not p.inLiteralQuote:
        p.skipWhitespaceAndComments()
      if nodes.len > 0 and not p.atEnd and p.peek in {'*', '+', '?', '{'} and
          p.repeatApplies(nodes[^1]):
        var lastNode = nodes.pop()
        p.concatNodeCount = nodes.len
        lastNode = p.parseQuantifier(lastNode)
        nodes.add(lastNode)
        p.concatNodeCount = nodes.len
      continue
    let node = p.parseQuantified()
    # Isolated flag group (?i) applies to the rest of the enclosing group,
    # including across alternation branches. Restructure the AST so the flag
    # wraps the remaining regex as a scoped flag group.
    if node.kind == nkFlagGroup and node.flagBody == nil:
      # An isolated flag group still counts as a sibling of what precedes it,
      # even though it wraps the rest: Oniguruma rejects ``(?I:a)(?i)`` just
      # like ``(?I:a)b``. The add-and-break below bypasses the exclusive check
      # at the end of the loop, so check here before wrapping the rest.
      if p.requiresExclusive:
        p.error("invalid combination of options")
      # The rest is wrapped by this group, but it no longer opens the pattern:
      # Oniguruma rejects ``(?i)(?I)a`` for exactly this reason.
      p.atOptionPrefix = false
      # An isolated [LeadingOnlyFlags] group spans the rest of its own group,
      # but the wrappers around it may hold nothing else: Oniguruma takes
      # ``(?:(?I)a)`` and rejects ``(?:(?I)a)b``, ``b(?:(?I)a)`` and
      # ``(?:(?I)a)|b`` alike.  Raise the flag only after the body is parsed,
      # so the body's own nodes -- the ``ab`` of ``(?I)ab`` -- are not counted.
      let isolatedNeedsExclusive = (node.flagsOn * LeadingOnlyFlags).card > 0
      let rest = p.parseAlternation()
      nodes.add(
        Node(
          kind: nkFlagGroup,
          flagsOn: node.flagsOn,
          flagsOff: node.flagsOff,
          flagBody: rest,
          graphemeMode: node.graphemeMode,
        )
      )
      if isolatedNeedsExclusive:
        p.requiresExclusive = true
      break
    # Skip empty nodes from \E; if a quantifier follows, attach to previous atom
    if node.kind == nkConcat and node.children.len == 0:
      if not p.inLiteralQuote and nodes.len > 0 and not p.atEnd and
          p.peek in {'*', '+', '?', '{'}:
        var lastNode = nodes.pop()
        p.concatNodeCount = nodes.len
        lastNode = p.parseQuantifier(lastNode)
        nodes.add(lastNode)
        p.concatNodeCount = nodes.len
      continue
    nodes.add(node)
    p.concatNodeCount = nodes.len
    # (?Ii:...) requires being the sole node in the pattern
    if p.requiresExclusive and nodes.len > 1:
      p.error("invalid combination of options")
  # Check requiresExclusive at end: if set and there are trailing tokens after
  # this concat.  ``)`` is the close of a transparent wrapper and is fine --
  # ``(?:(?I:a))`` is accepted -- but an alternation is not: Oniguruma rejects
  # ``(?I:a)|b`` while taking ``(?I:a|b)``, where the bar is inside the body.
  if p.requiresExclusive and nodes.len == 1 and not p.atEnd and p.peek != ')':
    p.error("invalid combination of options")
  p.concatNodeCount = savedConcatCount
  case nodes.len
  of 0:
    Node(kind: nkConcat, children: @[])
  of 1:
    nodes[0]
  else:
    Node(kind: nkConcat, children: nodes)

proc parseAlternation(p: var Parser): Node =
  var first = p.parseConcat()
  if p.peek != '|':
    return first
  var alts = @[first]
  let savedBranch = p.inNonFirstBranch
  p.inNonFirstBranch = true
  while p.peek == '|':
    p.advance() # skip '|'
    alts.add(p.parseConcat())
  p.inNonFirstBranch = savedBranch
  Node(kind: nkAlternation, alternatives: alts)

proc parseRegex*(p: var Parser): Node =
  parseAlternation(p)

proc validateLeadingOnlyPosition*(p: Parser, root: Node) =
  ## Reject a quantified [LeadingOnlyFlags] group at the top of the pattern.
  ## Sibling cases are already caught while parsing; only a lone quantified
  ## node slips through since ``requiresExclusive`` sees a single node at the
  ## end. Oniguruma rejects ``(?I:a)+`` and ``(?:(?I:a))+`` the same way.
  ## A quantified group nested inside ``(?flags:...)`` stays valid --
  ## Oniguruma takes ``(?i:(?I:a)+)`` -- so ``nkFlagGroup`` masks the inside
  ## and only transparent ``(?:...)`` wrappers are unwrapped here.
  if not p.sawLeadingOnlyOption:
    return
  var node = root
  while node != nil:
    case node.kind
    of nkGroup:
      node = node.groupBody
    of nkConcat:
      if node.children.len == 1:
        node = node.children[0]
      else:
        return
    else:
      break
  if node != nil and node.kind == nkQuantifier:
    p.error("invalid combination of options")

proc parseNamedCapture(p: var Parser, closeChar: char): Node =
  ## Parse a named capture group. `closeChar` is '>' for (?<name>...) and
  ## '\'' for (?'name'...) and '>' for (?P<name>...).
  ##
  ## As in Oniguruma, a name starts with a word character other than an ASCII
  ## digit, so a reference to it is never taken for a group number.
  var name = ""
  while p.peek != closeChar and not p.atEnd:
    name.add(p.peek)
    p.advance()
  if name.len == 0:
    p.error("empty group name")
  p.expect(closeChar)
  if name[0] in {'0' .. '9', '-', '+'}:
    p.error("invalid group name <" & name & ">")
  if not isWordChar(name.runeAt(0), asciiOnly = false):
    p.error("invalid char in group name <" & name & ">")
  let idx = p.captureCount
  inc p.captureCount
  inc p.captureDepth
  p.namedCaptures.add((name, idx))
  let body = p.parseRegex()
  dec p.captureDepth
  Node(
    kind: nkNamedCapture,
    captureName: name,
    namedCaptureIndex: idx,
    namedCaptureBody: body,
  )

proc parseConditional(p: var Parser): Node =
  ## Parse a conditional group: (?(condition)yes|no).
  ## Called after '(', '?', '(' have been consumed.
  let condStart = p.pos - 1 # the '(' a look-around condition starts with
  # An isolated ``(?i)`` in the condition ends with it, as in any group.
  let outerFlags = p.flags
  var condKind: ConditionalKind
  var condIndex: int
  var condName: string
  var condBodyNode: Node = nil
  var lookaroundSpelled = false # ``(?(?=a)``, reni's own spelling
  var bareRef: GroupRef
  # A name in ``<>`` or ``''`` reads the groups opened before it, as a
  # ``\k<name>`` does; a bare one, not Oniguruma's spelling, every group.
  var condScope = EveryNamedGroup

  if p.peek == ')':
    condKind = ckAlwaysTrue
    condIndex = -1
    p.advance()
  elif p.peek == '?':
    p.advance()
    if p.peek == '{':
      p.advance()
      var depth2 = 1
      while not p.atEnd and depth2 > 0:
        if p.peek == '{':
          inc depth2
        elif p.peek == '}':
          dec depth2
        p.advance()
      condKind = ckAlwaysTrue
      condIndex = -1
      p.expect(')')
    elif p.peek in {'=', '!'}:
      let lookKind = if p.peek == '=': lkAhead else: lkNegAhead
      p.advance()
      let lookBody = p.parseRegex()
      p.expect(')')
      condKind = ckRegexCond
      condIndex = -1
      condBodyNode = Node(kind: nkLookaround, lookKind: lookKind, lookBody: lookBody)
      p.recordStart(condBodyNode, condStart)
      lookaroundSpelled = true
    elif p.peek == '<' and p.pos + 1 < p.src.len and p.src[p.pos + 1] in {'=', '!'}:
      p.advance()
      let lookKind = if p.peek == '=': lkBehind else: lkNegBehind
      p.advance()
      let lookBody = p.parseRegex()
      p.expect(')')
      condKind = ckRegexCond
      condIndex = -1
      condBodyNode = Node(kind: nkLookaround, lookKind: lookKind, lookBody: lookBody)
      p.recordStart(condBodyNode, condStart)
      lookaroundSpelled = true
    else:
      # Oniguruma reads this ``?`` as a repeat with nothing before it, as it
      # does the ``(?(?=`` and ``(?(?<=`` reni keeps above.
      p.error("target of repeat operator not specified")
  elif p.peek == '*':
    # The callout is the condition: ``(?(*FAIL)b|c)`` takes ``c``, and
    # ``(?(*MAX{1})b|c)`` takes ``b`` once.
    p.advance()
    let verb = p.parseCalloutVerb()
    p.expect(')')
    condIndex = -1
    if verb.kind == nkLookaround: # (*FAIL)
      condKind = ckAlwaysFalse
    else:
      condKind = ckRegexCond
      condBodyNode = verb
      p.recordStart(condBodyNode, condStart)
  elif p.peek == '{':
    p.advance()
    var depth = 1
    while not p.atEnd and depth > 0:
      if p.peek == '{':
        inc depth
      elif p.peek == '}':
        dec depth
      p.advance()
    condKind = ckAlwaysTrue
    condIndex = -1
    p.expect(')')
  elif p.peek in {'<', '\''}:
    let close = if p.peek == '<': '>' else: '\''
    p.advance()
    let textStart = p.pos
    while not p.atEnd and p.peek != close:
      p.advance()
    let text = p.src[textStart ..< p.pos]
    p.expect(close)
    p.expect(')')
    p.setConditionRef(readGroupRef(text), textStart, condKind, condIndex, condName)
    condScope = int32(p.namedCaptures.len)
  elif p.readBareGroupRef(bareRef):
    p.setConditionRef(bareRef, condStart + 1, condKind, condIndex, condName)
  else:
    # Any other condition is a pattern, up to the ``)`` that closes it, as in
    # Oniguruma: ``(?((a)x)b|c)`` matches ``axb`` and sets group 1.
    let textStart = p.pos
    condKind = ckRegexCond
    condIndex = -1
    condBodyNode = p.parseRegex()
    p.expect(')')
    # A look-around alone is still a pattern here, not reni's own ``(?(?!X)``
    # spelling, whose captures ``condHolds`` keeps the PCRE2 way.
    if condBodyNode.kind == nkLookaround:
      condBodyNode = Node(kind: nkGroup, groupBody: condBodyNode)
    # Text with no ``)`` of its own may be a group's name, which is reni's own
    # spelling of a reference to that group, before or after it.
    # ``resolveBareNameConditions`` decides once every group is known.
    if p.src.find(')', textStart) == p.pos - 1:
      condName = p.src[textStart ..< p.pos - 1]
  p.flags = outerFlags

  # Only a reference may go without a branch, and then it tests its group
  # alone (``(?(1))``).  A bare name may still be one.  The look-around
  # spelling follows PCRE2, which lets it go without.
  if p.peek == ')' and condKind notin {ckBackref, ckNamedRef} and not lookaroundSpelled:
    if condName.len == 0:
      p.error("invalid if-else syntax") # Oniguruma's -224
    p.branchlessNames.add((condName, p.pos))

  let yesStart = p.pos
  var yes = p.parseConcat()
  if p.pos != yesStart and yes.kind == nkConcat and yes.children.len == 0:
    # ``(?#...)``, ``\Q\E`` and extended-mode whitespace/comments are erased
    # while parsing, so an AST-empty yes-branch can still have been non-empty in
    # the source.  Consuming any input means the author wrote something, so wrap
    # it like ``(?:)`` for the engine's emptiness test: /(a)?(?(1)(?#x))b/
    # matches "b" but /(a)?(?(1))b/ does not.  Deciding on source position
    # rather than the AST is Oniguruma's own rule.
    yes = Node(kind: nkGroup, groupBody: yes)
  var no: Node = nil
  if p.peek == '|':
    p.advance()
    no = p.parseRegex()
  # A bare name may name a group, which ``resolveBareNameConditions`` turns
  # into a ``ckNamedRef``, saying then that it reads one.  Every other
  # condition reads no group of its own.
  if condKind in {ckBackref, ckNamedRef}:
    p.sawGroupRead = true
  elif condKind == ckRegexCond and condName.len > 0:
    p.sawBareNameCondition = true
  if condIndex > high(int32):
    # No group has that number; said here, as the node keeps 32 bits of it.
    p.error("invalid conditional group reference '(" & $condIndex & ")'")
  Node(
    kind: nkConditional,
    condKind: condKind,
    condRefIndex: int32(condIndex),
    condScope: condScope,
    condRefName: condName,
    condYes: yes,
    condNo: no,
    condBody: condBodyNode,
  )

proc parseGroup(p: var Parser): Node =
  p.expect('(')
  inc p.depth
  if p.depth > MaxNestingDepth:
    p.error("nesting too deep")
  # Level cap is a complexity limit; this is the resource guard.
  # Parser levels are cheap, so check every level.
  if stackUsedFrom(p.stackBase) > MaxStackBytes:
    raise
      newException(RegexLimitError, "parse stack budget exceeded at position " & $p.pos)

  let savedFlags = p.flags
  # Only ``(?:...)`` and ``(?flags:...)`` wrap without ending the run of
  # wrappers a [LeadingOnlyFlags] group may sit in; those two put it back.
  let outerAtOptionPrefix = p.atOptionPrefix
  p.atOptionPrefix = false

  if p.peek == '*':
    p.advance() # skip '*'
    result = p.parseCalloutVerb()
  elif p.peek == '?':
    p.advance() # skip '?'
    case p.peek
    of ')':
      # (?) empty group — treat as empty non-capturing group
      result = Node(kind: nkConcat, children: @[])
    of ':':
      # (?:...) non-capturing group
      p.advance()
      p.atOptionPrefix = outerAtOptionPrefix
      let body = p.parseRegex()
      p.sawPlainGroup = true
      result = Node(kind: nkGroup, groupBody: body)
    of '~':
      # (?~...) absent operator
      p.advance() # skip '~'
      p.sawAbsent = true
      if p.peek == '|':
        # (?~|...) forms. All three are rejected in a look-behind, unlike the
        # absent function below -- by ``validateLookbehinds``, after the
        # references are checked, as Oniguruma orders its errors.
        p.advance() # skip '|'
        if p.peek == ')':
          # (?~|) - range clear
          result = Node(kind: nkAbsent, absentKind: abClear)
        else:
          # Parse absent pattern (up to '|' or ')')
          let absentBody = p.parseConcat()
          if p.peek == '|':
            # (?~|absent|expr) - absent expression
            p.advance() # skip '|'
            let exprFlags = p.flags
            let expr = p.parseRegex()
            let loop = oneCharRepeat(expr, exprFlags)
            result = Node(
              kind: nkAbsent,
              absentKind: abExpression,
              absentLoopsOnExpr: loop.found,
              absentLoopLo: loop.lo,
              absentLoopHi: loop.hi,
              absentBody: absentBody,
              absentExpr: expr,
            )
          else:
            # (?~|absent) - range marker
            result = Node(kind: nkAbsent, absentKind: abRange, absentBody: absentBody)
      else:
        # (?~pattern) - absent function. ``(?~)`` is one with an empty
        # pattern, as in Oniguruma: it matches empty and leaves the range
        # alone. The range clear is ``(?~|)``.
        let body = p.parseRegex()
        result = Node(kind: nkAbsent, absentKind: abFunction, absentBody: body)
    of '<':
      # (?<name>...) named capture  OR  (?<=...) lookbehind  OR  (?<!...) neg lookbehind
      p.advance() # skip '<'
      if p.peek == '=':
        p.advance()
        let body = p.parseRegex()
        result = Node(kind: nkLookaround, lookKind: lkBehind, lookBody: body)
      elif p.peek == '!':
        p.advance()
        let body = p.parseRegex()
        result = Node(kind: nkLookaround, lookKind: lkNegBehind, lookBody: body)
      else:
        result = p.parseNamedCapture('>')
    of '\'':
      p.advance() # skip opening quote
      result = p.parseNamedCapture('\'')
    of '=':
      # (?=...) positive lookahead
      p.advance()
      let body = p.parseRegex()
      result = Node(kind: nkLookaround, lookKind: lkAhead, lookBody: body)
    of '!':
      # (?!...) negative lookahead
      p.advance()
      let body = p.parseRegex()
      result = Node(kind: nkLookaround, lookKind: lkNegAhead, lookBody: body)
    of '>':
      # (?>...) atomic group
      p.advance()
      let body = p.parseRegex()
      result = Node(kind: nkAtomicGroup, atomicBody: body)
    of '#':
      # (?#...) comment group
      p.advance() # skip '#'
      while not p.atEnd and p.peek != ')':
        p.advance()
      result = Node(kind: nkGroup, groupBody: Node(kind: nkConcat, children: @[]))
    of 'y':
      # (?y{g}) or (?y{w}) — grapheme mode flag
      p.advance() # skip 'y'
      p.expect('{')
      var mode = ""
      while not p.atEnd and p.peek != '}':
        mode.add(p.peek)
        p.advance()
      p.expect('}')
      let gm =
        case mode
        of "g":
          gmGrapheme
        of "w":
          gmWord
        else:
          p.error("invalid grapheme mode (?y{" & mode & "})")
      if p.peek == ')':
        # Isolated (?y{g})
        result = Node(
          kind: nkFlagGroup, flagsOn: {}, flagsOff: {}, flagBody: nil, graphemeMode: gm
        )
      elif p.peek == ':':
        # Scoped (?y{g}:...)
        p.advance()
        let body = p.parseRegex()
        result = Node(
          kind: nkFlagGroup, flagsOn: {}, flagsOff: {}, flagBody: body, graphemeMode: gm
        )
      else:
        p.error("expected ')' or ':' after (?y{" & mode & "}")
    else:
      if p.peek == '(':
        p.advance() # skip '('
        result = p.parseConditional()
      elif p.peek == 'R':
        # (?R) — whole pattern recursion (= \g<0>)
        p.advance()
        result = p.callNode(0, "")
      elif p.peek in {'0' .. '9'}:
        # (?1), (?2), etc. — numeric subroutine call (= \g<n>)
        var n = 0
        while not p.atEnd and p.peek in {'0' .. '9'}:
          appendDecimal(n, p.peek)
          p.advance()
        result = p.callNode(n, "")
      elif p.peek == '+':
        # (?+1) — relative forward subroutine call
        p.advance()
        var n = 0
        while not p.atEnd and p.peek in {'0' .. '9'}:
          appendDecimal(n, p.peek)
          p.advance()
        result = p.callNode(p.relativeForwardIndex(n), "")
      elif p.peek == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] in {'0' .. '9'}:
        # (?-1) — relative backward subroutine call
        p.advance()
        var n = 0
        while not p.atEnd and p.peek in {'0' .. '9'}:
          appendDecimal(n, p.peek)
          p.advance()
        let ci = p.captureCount - n + 1
        if ci < 1:
          p.error("invalid relative subexp call '(?-" & $n & ")'")
        result = p.callNode(ci, "")
      elif p.peek == '&':
        # (?&name) — named subroutine call (= \g<name>)
        p.advance()
        var name = ""
        while not p.atEnd and p.peek != ')':
          name.add(p.peek)
          p.advance()
        if name.len == 0:
          p.error("empty subroutine name")
        result = p.callNode(-1, name)
      elif p.peek == 'P' and p.pos + 1 < p.src.len and
          p.src[p.pos + 1] in {'<', '=', '>'}:
        p.advance() # skip 'P'
        if p.peek == '<':
          # (?P<name>...) — Python named capture
          p.advance()
          result = p.parseNamedCapture('>')
        elif p.peek == '=':
          # (?P=name) — Python named backreference
          p.advance()
          var name = ""
          while not p.atEnd and p.peek != ')':
            name.add(p.peek)
            p.advance()
          if name.len == 0:
            p.error("empty backreference name")
          result = Node(
            kind: nkNamedBackref,
            backrefName: name,
            namedBackrefLevel: 0,
            backrefScope: int32(p.namedCaptures.len),
          )
          p.sawGroupRead = true
        else:
          # (?P>name) — Python named subroutine call
          p.advance()
          var name = ""
          while not p.atEnd and p.peek != ')':
            name.add(p.peek)
            p.advance()
          if name.len == 0:
            p.error("empty subroutine name")
          result = p.callNode(-1, name)
      # Try to parse inline flags: (?imx-imx:...) or (?imx)
      elif p.peek in FlagChars or p.peek == '-':
        var flagsOn: RegexFlags = {}
        var flagsOff: RegexFlags = {}
        var parsingOff = false
        while not p.atEnd and (p.peek in FlagChars or p.peek == '-'):
          if p.peek == '-':
            parsingOff = true
            p.advance()
          else:
            let flag = charToFlag(p.peek)
            if parsingOff:
              flagsOff.incl(flag)
            else:
              flagsOn.incl(flag)
            p.advance()

        # [LeadingOnlyFlags] can only be switched on, and only by a group that
        # opens the pattern: the wrappers before it must all be ``(?:`` or
        # ``(?flags:``, nothing may have been parsed yet, and one such group is
        # the most a pattern gets.  A capture, a lookaround, an atomic group or
        # an isolated ``(?flags)`` all end that run -- which is why Oniguruma
        # takes ``(?I)a`` and ``(?:(?I)a)`` but rejects ``(?i)(?I)a``.
        if (flagsOff * LeadingOnlyFlags).card > 0:
          p.error("invalid combination of options")
        let leadingOnly = (flagsOn * LeadingOnlyFlags).card > 0
        if leadingOnly:
          if p.sawLeadingOnlyOption or not outerAtOptionPrefix or p.concatNodeCount > 0 or
              p.captureDepth > 0 or p.inNonFirstBranch:
            p.error("invalid combination of options")
          p.sawLeadingOnlyOption = true

        if p.peek == ':':
          # Scoped: (?imx:...)
          # Error conditions for I/i in scoped form:
          # - I before i in on set: (?Ii:...)
          # - i on, I off: (?i-I:...)
          # - both off: (?-Ii:...) or (?-iI:...)
          let iAndIBothPresent =
            (rfIgnoreCase in flagsOn or rfIgnoreCase in flagsOff) and
            (rfIgnoreCaseAscii in flagsOn or rfIgnoreCaseAscii in flagsOff)
          if iAndIBothPresent:
            let ok = rfIgnoreCaseAscii in flagsOn and rfIgnoreCase in flagsOff
              # (?I-i:...) OK
            let ok2 = rfIgnoreCase in flagsOn and rfIgnoreCaseAscii in flagsOn
              # (?iI:...) or (?Ii:...) OK
            if not ok and not ok2:
              p.error("invalid combination of options")
          p.advance()
          p.flags = (p.flags + flagsOn) - flagsOff
          # The scoped form has to span the pattern: Oniguruma rejects
          # ``(?I:a)b`` and ``(?I:a)|b`` though it takes ``(?I:a)``.
          let scopedNeedsExclusive = leadingOnly
          p.atOptionPrefix = outerAtOptionPrefix
          let body = p.parseRegex()
          result = Node(
            kind: nkFlagGroup, flagsOn: flagsOn, flagsOff: flagsOff, flagBody: body
          )
          if scopedNeedsExclusive:
            p.requiresExclusive = true
        elif p.peek == ')':
          # Isolated: (?imx) — affects rest of enclosing group
          p.flags = (p.flags + flagsOn) - flagsOff
          result =
            Node(kind: nkFlagGroup, flagsOn: flagsOn, flagsOff: flagsOff, flagBody: nil)
        else:
          p.error("expected ':' or ')' after flags")
      else:
        p.error("unsupported group type '(?" & p.peek & "'")
  else:
    # Plain capturing group
    let idx = p.captureCount
    inc p.captureCount
    inc p.captureDepth
    let body = p.parseRegex()
    dec p.captureDepth
    result = Node(kind: nkCapture, captureIndex: idx, captureBody: body)

  p.expect(')')
  dec p.depth
  # Restore flags for all groups EXCEPT isolated flag groups (?i),
  # which intentionally modify the enclosing scope's flags
  if not (result.kind == nkFlagGroup and result.flagBody == nil):
    p.flags = savedFlags
