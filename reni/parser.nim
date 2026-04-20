import std/unicode
from std/strutils import toUpperAscii, find, parseInt

import types, charclass

type Parser* = object
  src: string
  pos: int
  flags: RegexFlags
  captureCount*: int
  namedCaptures*: seq[(string, int)]
  depth: int
  captureDepth: int ## nesting depth inside capture groups
  concatNodeCount: int ## number of nodes already parsed at current concat level
  inNonFirstBranch: bool ## true when parsing non-first alternation branch
  requiresExclusive: bool ## true when (?Ii:...) requires being the only node
  inLookbehind: bool ## true when inside lookbehind assertion
  inLiteralQuote: bool ## true when inside \Q...\E

const
  MaxNestingDepth = 256
  MaxRepeat = 100_000
  FlagChars = {'i', 'm', 's', 'x', 'W', 'D', 'S', 'P', 'I', 'L'}

proc initParser*(pattern: string, flags: RegexFlags = {}): Parser =
  Parser(src: pattern, pos: 0, flags: flags)

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

proc expect(p: var Parser, ch: char) =
  if p.peek != ch:
    raise newException(RegexError, "expected '" & ch & "' at position " & $p.pos)
  p.advance()

proc error(p: Parser, msg: string) {.noreturn.} =
  raise newException(RegexError, msg & " at position " & $p.pos)

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
        n = n * 10 + (ord(p.peek) - ord('0'))
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
          m = m * 10 + (ord(p.peek) - ord('0'))
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
    true
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
      idx = idx * 10 + (ord(c) - ord('0'))
    if idxStr.len == 1 or idx <= p.captureCount:
      # Single digit (\1-\9) or valid multi-digit backref
      result = Node(kind: nkBackreference, backrefIndex: idx)
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
    if p.peek == '{':
      p.advance()
      while p.peek != '}' and not p.atEnd:
        if p.peek != ' ':
          name.add(p.peek)
        p.advance()
      if name.len == 0:
        p.error("empty Unicode property name")
      p.expect('}')
    else:
      if p.atEnd or p.peek notin {'A' .. 'Z', 'a' .. 'z'}:
        p.error("invalid Unicode property name")
      name.add(p.peek)
      p.advance()
      # Single-char \pX: only valid for major Unicode category letters
      if name[0] notin {'L', 'M', 'N', 'P', 'S', 'Z', 'C'}:
        p.error("invalid Unicode property '" & name & "'")
    # \p{^Prop} = negated property
    if name.len > 1 and name[0] == '^':
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[CcAtom(kind: ccNegUnicodeProp, propName: name[1 ..^ 1])],
      )
    else:
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[CcAtom(kind: ccUnicodeProp, propName: name)],
      )
  of 'P':
    p.advance()
    var name = ""
    if p.peek == '{':
      p.advance()
      while p.peek != '}' and not p.atEnd:
        if p.peek != ' ':
          name.add(p.peek)
        p.advance()
      if name.len == 0:
        p.error("empty Unicode property name")
      p.expect('}')
    else:
      if p.atEnd or p.peek notin {'A' .. 'Z', 'a' .. 'z'}:
        p.error("invalid Unicode property name")
      name.add(p.peek)
      p.advance()
      if name[0] notin {'L', 'M', 'N', 'P', 'S', 'Z', 'C'}:
        p.error("invalid Unicode property '" & name & "'")
    # \P{^Prop} = double negation = positive
    if name.len > 1 and name[0] == '^':
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[CcAtom(kind: ccUnicodeProp, propName: name[1 ..^ 1])],
      )
    else:
      result = Node(
        kind: nkCharClass,
        negated: false,
        atoms: @[CcAtom(kind: ccNegUnicodeProp, propName: name)],
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
    # Handle numeric, relative, and level-suffix backrefs
    # Parse +level or -level suffix (e.g., \k<1+3> → index=1, level=3)
    var baseName = name
    var level = 0
    let plusPos = name.find('+', start = 1)
      # skip first char (could be +/- for relative ref)
    let minusPos = name.find('-', start = 1)
    var levelPos = -1
    if plusPos > 0 and (minusPos < 0 or plusPos < minusPos):
      levelPos = plusPos
    elif minusPos > 0:
      levelPos = minusPos
    if levelPos > 0:
      let levelStr = name[levelPos + 1 .. ^1]
      var isLevelNum = levelStr.len > 0
      for c in levelStr:
        if c notin {'0' .. '9'}:
          isLevelNum = false
          break
      if isLevelNum:
        for c in levelStr:
          level = level * 10 + (ord(c) - ord('0'))
        if name[levelPos] == '-':
          level = -level
        baseName = name[0 ..< levelPos]
    # Check if it's a numeric or relative reference
    if baseName.len > 0 and (baseName[0] in {'0' .. '9'} or baseName[0] in {'+', '-'}):
      var neg = false
      var startIdx = 0
      if baseName[0] == '+':
        startIdx = 1
      elif baseName[0] == '-':
        neg = true
        startIdx = 1
      var isNum = true
      for i in startIdx ..< baseName.len:
        if baseName[i] notin {'0' .. '9'}:
          isNum = false
          break
      if isNum and baseName.len > startIdx:
        var idx = 0
        for i in startIdx ..< baseName.len:
          idx = idx * 10 + (ord(baseName[i]) - ord('0'))
        if neg:
          let origN = idx
          idx = p.captureCount - idx + 1
          if idx < 1:
            p.error("invalid relative backref '\\k<-" & $origN & ">'")
        elif baseName[0] == '+':
          idx = p.captureCount + idx
          # Forward reference — bounds checked at compile time.
        result = Node(kind: nkBackreference, backrefIndex: idx, backrefLevel: level)
      else:
        result =
          Node(kind: nkNamedBackref, backrefName: baseName, namedBackrefLevel: level)
    else:
      result =
        Node(kind: nkNamedBackref, backrefName: baseName, namedBackrefLevel: level)
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
          callIndex = callIndex * 10 + (ord(c) - ord('0'))
        else:
          break
    elif name[0] == '+':
      var n = 0
      for i in 1 ..< name.len:
        if name[i] in {'0' .. '9'}:
          n = n * 10 + (ord(name[i]) - ord('0'))
      callIndex = p.captureCount + n
    elif name[0] == '-':
      var n = 0
      for i in 1 ..< name.len:
        if name[i] in {'0' .. '9'}:
          n = n * 10 + (ord(name[i]) - ord('0'))
      callIndex = p.captureCount - n + 1
      if callIndex < 1:
        p.error("invalid relative subexp call '\\g<-" & $n & ">'")
    else:
      callName = name
    result = Node(kind: nkSubexpCall, callIndex: callIndex, callName: callName)
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
  let upperVerb = verbName.toUpperAscii()
  case upperVerb
  of "FAIL":
    while not p.atEnd and p.peek != ')':
      p.advance()
    Node(
      kind: nkLookaround,
      lookKind: lkNegAhead,
      lookBody: Node(kind: nkConcat, children: @[]),
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
    let maxN =
      if numStr.len > 0:
        parseInt(numStr)
      else:
        0
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
    const KnownVerbs = [
      "FAIL", "MAX", "COUNT", "CMP", "TOTAL_COUNT", "SKIP", "MISMATCH", "ACCEPT",
      "PRUNE", "COMMIT", "THEN", "ERROR",
    ]
    if upperVerb notin KnownVerbs:
      p.error("undefined callout name '" & verbName & "'")
    Node(kind: nkGroup, groupBody: Node(kind: nkConcat, children: @[]))

proc resolveCondRef(
    name: string,
    condKind: var ConditionalKind,
    condIndex: var int,
    condName: var string,
) =
  ## Parse a conditional reference name as either a numeric backref or named ref.
  var isNum = true
  for c in name:
    if c notin {'0' .. '9'}:
      isNum = false
      break
  if isNum and name.len > 0:
    condKind = ckBackref
    condIndex = 0
    for c in name:
      condIndex = condIndex * 10 + (ord(c) - ord('0'))
  else:
    condKind = ckNamedRef
    condName = name

# Forward declarations
proc parseGroup(p: var Parser): Node
proc parseAlternation(p: var Parser): Node

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
  case ch
  of '\\':
    result = p.parseEscape()
  of '(':
    result = p.parseGroup()
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
    let (newPos, node) = parseCharClass(p.src, p.pos, p.flags)
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
      if not isQuantifiable(body):
        if body.kind == nkFlagGroup and body.flagBody == nil:
          p.error("target of repeat operator not specified")
        elif body.kind == nkAnchor:
          p.error("target of repeat operator is not repeatable")
        elif body.kind == nkLookaround:
          discard # lookarounds can be quantified (e.g., (?=abc){0}, (?=(a))?)
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
      if nodes.len > 0 and not p.atEnd and p.peek in {'*', '+', '?', '{'}:
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
  # Check requiresExclusive at end: if set and there are trailing tokens after this concat
  if p.requiresExclusive and nodes.len == 1 and not p.atEnd and p.peek notin {')', '|'}:
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

proc parseNamedCapture(p: var Parser, closeChar: char): Node =
  ## Parse a named capture group. `closeChar` is '>' for (?<name>...) and
  ## '\'' for (?'name'...) and '>' for (?P<name>...).
  var name = ""
  while p.peek != closeChar and not p.atEnd:
    name.add(p.peek)
    p.advance()
  if name.len == 0:
    p.error("empty group name")
  p.expect(closeChar)
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
  var condKind: ConditionalKind
  var condIndex: int
  var condName: string
  var condBodyNode: Node = nil

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
    elif p.peek == '<' and p.pos + 1 < p.src.len and p.src[p.pos + 1] in {'=', '!'}:
      p.advance()
      let lookKind = if p.peek == '=': lkBehind else: lkNegBehind
      p.advance()
      let lookBody = p.parseRegex()
      p.expect(')')
      condKind = ckRegexCond
      condIndex = -1
      condBodyNode = Node(kind: nkLookaround, lookKind: lookKind, lookBody: lookBody)
    else:
      while not p.atEnd and p.peek != ')':
        p.advance()
      condKind = ckAlwaysTrue
      condIndex = -1
      p.expect(')')
  elif p.peek == '*':
    p.advance()
    while not p.atEnd and p.peek != ')':
      p.advance()
    condKind = ckAlwaysFalse
    condIndex = -1
    p.expect(')')
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
  elif p.peek == '<':
    p.advance()
    var name = ""
    while not p.atEnd and p.peek != '>':
      name.add(p.peek)
      p.advance()
    p.expect('>')
    p.expect(')')
    resolveCondRef(name, condKind, condIndex, condName)
  elif p.peek == '\'':
    p.advance()
    var name = ""
    while not p.atEnd and p.peek != '\'':
      name.add(p.peek)
      p.advance()
    p.expect('\'')
    p.expect(')')
    resolveCondRef(name, condKind, condIndex, condName)
  elif p.peek in {'0' .. '9'} or p.peek == '-':
    var neg = false
    if p.peek == '-':
      neg = true
      p.advance()
    var numStr = ""
    while p.peek in {'0' .. '9'}:
      numStr.add(p.peek)
      p.advance()
    if p.peek == '+':
      p.advance()
      while p.peek in {'0' .. '9'}:
        p.advance()
    p.expect(')')
    condKind = ckBackref
    condIndex = 0
    for c in numStr:
      condIndex = condIndex * 10 + (ord(c) - ord('0'))
    if neg:
      let origN = condIndex
      condIndex = p.captureCount - condIndex + 1
      if condIndex < 1:
        p.error("invalid relative conditional reference '(?(-" & $origN & "))'")
  else:
    var name = ""
    while not p.atEnd and p.peek != ')':
      name.add(p.peek)
      p.advance()
    p.expect(')')
    if name.len == 0:
      condKind = ckAlwaysTrue
      condIndex = -1
    else:
      var isNamedCapture = false
      for (cn, _) in p.namedCaptures:
        if cn == name:
          isNamedCapture = true
          break
      if isNamedCapture:
        condKind = ckNamedRef
        condName = name
      else:
        condKind = ckRegexCond
        condName = name

  if condKind == ckRegexCond and condBodyNode == nil:
    var condParser = initParser(condName, p.flags)
    condBodyNode = condParser.parseRegex()

  let yes = p.parseConcat()
  var no: Node = nil
  if p.peek == '|':
    p.advance()
    no = p.parseRegex()
  Node(
    kind: nkConditional,
    condKind: condKind,
    condRefIndex: condIndex,
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

  let savedFlags = p.flags

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
      let body = p.parseRegex()
      result = Node(kind: nkGroup, groupBody: body)
    of '~':
      # (?~...) absent operator
      p.advance() # skip '~'
      if p.peek == ')':
        # (?~) - range clear / empty match
        result = Node(kind: nkAbsent, absentKind: abClear)
      elif p.peek == '|':
        # (?~|...) forms
        if p.inLookbehind:
          p.error("invalid pattern in look-behind")
        p.advance() # skip '|'
        if p.peek == ')':
          # (?~|) - range clear
          result = Node(kind: nkAbsent, absentKind: abClear)
        else:
          # Parse absent pattern (up to '|' or ')')
          let absentBody = p.parseConcat()
          if p.peek == '|':
            # (?~|absent|expr) - absent expression
            if p.inLookbehind:
              p.error("invalid pattern in look-behind")
            p.advance() # skip '|'
            let expr = p.parseRegex()
            result = Node(
              kind: nkAbsent,
              absentKind: abExpression,
              absentBody: absentBody,
              absentExpr: expr,
            )
          else:
            # (?~|absent) - range marker
            if p.inLookbehind:
              p.error("invalid pattern in look-behind")
            result = Node(kind: nkAbsent, absentKind: abRange, absentBody: absentBody)
      else:
        # (?~pattern) - absent function
        let body = p.parseRegex()
        result = Node(kind: nkAbsent, absentKind: abFunction, absentBody: body)
    of '<':
      # (?<name>...) named capture  OR  (?<=...) lookbehind  OR  (?<!...) neg lookbehind
      p.advance() # skip '<'
      if p.peek == '=':
        p.advance()
        let savedLB = p.inLookbehind
        p.inLookbehind = true
        let body = p.parseRegex()
        p.inLookbehind = savedLB
        result = Node(kind: nkLookaround, lookKind: lkBehind, lookBody: body)
      elif p.peek == '!':
        p.advance()
        let savedLB = p.inLookbehind
        p.inLookbehind = true
        let body = p.parseRegex()
        p.inLookbehind = savedLB
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
        result = Node(kind: nkSubexpCall, callIndex: 0, callName: "")
      elif p.peek in {'0' .. '9'}:
        # (?1), (?2), etc. — numeric subroutine call (= \g<n>)
        var n = 0
        while not p.atEnd and p.peek in {'0' .. '9'}:
          n = n * 10 + (ord(p.peek) - ord('0'))
          p.advance()
        result = Node(kind: nkSubexpCall, callIndex: n, callName: "")
      elif p.peek == '+':
        # (?+1) — relative forward subroutine call
        p.advance()
        var n = 0
        while not p.atEnd and p.peek in {'0' .. '9'}:
          n = n * 10 + (ord(p.peek) - ord('0'))
          p.advance()
        result = Node(kind: nkSubexpCall, callIndex: p.captureCount + n, callName: "")
      elif p.peek == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] in {'0' .. '9'}:
        # (?-1) — relative backward subroutine call
        p.advance()
        var n = 0
        while not p.atEnd and p.peek in {'0' .. '9'}:
          n = n * 10 + (ord(p.peek) - ord('0'))
          p.advance()
        let ci = p.captureCount - n + 1
        if ci < 1:
          p.error("invalid relative subexp call '(?-" & $n & ")'")
        result = Node(kind: nkSubexpCall, callIndex: ci, callName: "")
      elif p.peek == '&':
        # (?&name) — named subroutine call (= \g<name>)
        p.advance()
        var name = ""
        while not p.atEnd and p.peek != ')':
          name.add(p.peek)
          p.advance()
        if name.len == 0:
          p.error("empty subroutine name")
        result = Node(kind: nkSubexpCall, callIndex: -1, callName: name)
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
          result = Node(kind: nkNamedBackref, backrefName: name, namedBackrefLevel: 0)
        else:
          # (?P>name) — Python named subroutine call
          p.advance()
          var name = ""
          while not p.atEnd and p.peek != ')':
            name.add(p.peek)
            p.advance()
          if name.len == 0:
            p.error("empty subroutine name")
          result = Node(kind: nkSubexpCall, callIndex: -1, callName: name)
      # Try to parse inline flags: (?imx-imx:...) or (?imx)
      elif p.peek in FlagChars or p.peek == '-':
        var flagsOn: RegexFlags = {}
        var flagsOff: RegexFlags = {}
        var parsingOff = false
        # Track order: did I appear before i in the on set?
        var iOnSeen = false
        var bigIBeforeLittleI = false
        while not p.atEnd and (p.peek in FlagChars or p.peek == '-'):
          if p.peek == '-':
            parsingOff = true
            p.advance()
          else:
            let flag = charToFlag(p.peek)
            if not parsingOff:
              if flag == rfIgnoreCase:
                iOnSeen = true
              elif flag == rfIgnoreCaseAscii and not iOnSeen:
                bigIBeforeLittleI = true
            if parsingOff:
              flagsOff.incl(flag)
            else:
              flagsOn.incl(flag)
            p.advance()

        # Validate flag combinations
        # (?-L) is not allowed
        if rfFindLongest in flagsOff:
          p.error("invalid combination of options")

        if p.peek == ':':
          # Scoped: (?imx:...)
          # Error conditions for I/i in scoped form:
          # - I before i in on set: (?Ii:...)
          # - i on, I off: (?i-I:...)
          # - both off: (?-Ii:...) or (?-iI:...)
          let iAndIBothPresent =
            (rfIgnoreCase in flagsOn or rfIgnoreCase in flagsOff) and
            (rfIgnoreCaseAscii in flagsOn or rfIgnoreCaseAscii in flagsOff)
          var scopedNeedsExclusive = false
          if iAndIBothPresent:
            let ok = rfIgnoreCaseAscii in flagsOn and rfIgnoreCase in flagsOff
              # (?I-i:...) OK
            let ok2 = rfIgnoreCase in flagsOn and rfIgnoreCaseAscii in flagsOn
              # (?iI:...) or (?Ii:...) OK
            if not ok and not ok2:
              p.error("invalid combination of options")
            if ok2:
              # (?Ii:...) / (?iI:...) must be at top level, sole node
              if p.concatNodeCount > 0 or p.captureDepth > 0 or p.inNonFirstBranch:
                p.error("invalid combination of options")
              scopedNeedsExclusive = true
          p.advance()
          p.flags = (p.flags + flagsOn) - flagsOff
          let body = p.parseRegex()
          result = Node(
            kind: nkFlagGroup, flagsOn: flagsOn, flagsOff: flagsOff, flagBody: body
          )
          if scopedNeedsExclusive:
            p.requiresExclusive = true
        elif p.peek == ')':
          # Isolated: (?imx) — affects rest of enclosing group
          # (?Ii) and (?L) only allowed at pattern start position
          let iAndIBothOn = rfIgnoreCase in flagsOn and rfIgnoreCaseAscii in flagsOn
          let hasSpecialFlags = iAndIBothOn or rfFindLongest in flagsOn
          if hasSpecialFlags:
            if p.concatNodeCount > 0 or p.captureDepth > 0 or p.inNonFirstBranch:
              p.error("invalid combination of options")
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
