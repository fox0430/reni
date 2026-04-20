import std/unicode

import types

type CcParser* = object
  src: string
  pos: int
  flags: RegexFlags
  pendingAtoms*: seq[CcAtom]

const HexDigits* = {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc parseHexInt*(s: string): int =
  for ch in s:
    result = result * 16
    if ch in {'0' .. '9'}:
      result += ord(ch) - ord('0')
    elif ch in {'a' .. 'f'}:
      result += ord(ch) - ord('a') + 10
    elif ch in {'A' .. 'F'}:
      result += ord(ch) - ord('A') + 10
    if result > 0xFFFFFFFF'i64:
      raise newException(RegexError, "hex escape value too large")

proc parseOctInt*(s: string): int =
  for ch in s:
    result = result * 8 + (ord(ch) - ord('0'))
    if result > 0x10FFFF:
      raise newException(RegexError, "octal escape value too large")

proc initCcParser*(src: string, pos: int, flags: RegexFlags): CcParser =
  CcParser(src: src, pos: pos, flags: flags)

proc position*(p: CcParser): int =
  p.pos

proc atEnd(p: CcParser): bool =
  p.pos >= p.src.len

proc peek(p: CcParser): char =
  if p.atEnd:
    '\0'
  else:
    p.src[p.pos]

proc peekAt(p: CcParser, offset: int): char =
  let i = p.pos + offset
  if i >= p.src.len:
    '\0'
  else:
    p.src[i]

proc advance(p: var CcParser) =
  if not p.atEnd:
    inc p.pos

proc error(p: CcParser, msg: string) {.noreturn.} =
  raise newException(RegexError, msg & " at position " & $p.pos)

proc expect(p: var CcParser, ch: char) =
  if p.peek != ch:
    raise newException(RegexError, "expected '" & ch & "' at position " & $p.pos)
  p.advance()

proc advanceRune(p: var CcParser): Rune =
  var r: Rune
  fastRuneAt(p.src, p.pos, r, true)
  r

proc parseCcEscape(p: var CcParser): CcAtom =
  ## Parse escape sequence inside character class.
  ## Note: \b = backspace (0x08) inside character class, not word boundary.
  p.advance() # skip '\'
  if p.atEnd:
    p.error("unexpected end after '\\'")

  let ch = p.peek
  case ch
  of 'w':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctWord)
  of 'W':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctNotWord)
  of 'd':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctDigit)
  of 'D':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctNotDigit)
  of 's':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctSpace)
  of 'S':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctNotSpace)
  of 'h':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctHexDigit)
  of 'H':
    p.advance()
    CcAtom(kind: ccCharType, charType: ctNotHexDigit)
  of 'b':
    # \b inside character class = backspace
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x08))
  of 'n':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x0A))
  of 't':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x09))
  of 'r':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x0D))
  of 'f':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x0C))
  of 'a':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x07))
  of 'e':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x1B))
  of 'v':
    p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(0x0B))
  of 'x':
    p.advance()
    if p.peek == '{':
      p.advance()
      # Multi-codepoint with optional ranges: \x{000A 002f}, \x{0030-0039}
      var atoms: seq[CcAtom]
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
          # non-hex, non-} after whitespace (e.g., trailing space or bare dash)
          p.error("invalid code point value")
        if hexStr.len > 8:
          p.error("hex escape value too large")
        let cpVal = parseHexInt(hexStr)
        let cp = Rune(cpVal)
        var hadWhitespace = false
        while p.peek in {' ', '\t', '\n', '\r'}:
          p.advance()
          hadWhitespace = true
        if hadWhitespace and p.peek == '}':
          p.error("invalid code point value")
        if p.peek == '-':
          # Could be a range: \x{0030-0039} or \x{0030 - 0039}
          p.advance()
          while p.peek in {' ', '\t', '\n', '\r'}:
            p.advance()
          var hexStr2 = ""
          while p.peek in HexDigits:
            hexStr2.add(p.peek)
            p.advance()
          if hexStr2.len == 0:
            # Dash without range endpoint (e.g., \x{0030 - })
            p.error("invalid code point value")
          if hexStr2.len > 8:
            p.error("hex escape value too large")
          let cpVal2 = parseHexInt(hexStr2)
          if cpVal > cpVal2:
            p.error("invalid code point value")
          atoms.add(CcAtom(kind: ccRange, rangeFrom: cp, rangeTo: Rune(cpVal2)))
          while p.peek in {' ', '\t', '\n', '\r'}:
            p.advance()
        else:
          atoms.add(CcAtom(kind: ccLiteral, rune: cp))
      if atoms.len == 0:
        p.error("empty hex escape")
      p.expect('}')
      let first = atoms[0]
      for i in 1 ..< atoms.len:
        p.pendingAtoms.add(atoms[i])
      first
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
        CcAtom(kind: ccLiteral, rune: Rune(val))
      elif val >= 0xF5:
        p.error("invalid code point value")
      elif val >= 0x80 and val <= 0xBF:
        p.error("invalid code point value")
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
          CcAtom(kind: ccLiteral, rune: Rune(cp))
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
    CcAtom(kind: ccLiteral, rune: Rune(parseHexInt(hexStr)))
  of 'o':
    p.advance()
    p.expect('{')
    # Multi-codepoint: \o{102 103}
    var atoms: seq[CcAtom]
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
      atoms.add(CcAtom(kind: ccLiteral, rune: Rune(parseOctInt(octStr))))
      while p.peek in {' ', '\t', '\n', '\r'}:
        p.advance()
    if atoms.len == 0:
      p.error("empty octal escape")
    p.expect('}')
    let first = atoms[0]
    for i in 1 ..< atoms.len:
      p.pendingAtoms.add(atoms[i])
    first
  of '0' .. '7':
    # Octal escape: \0, \00, \000, \1, \10, \177, etc.
    # In character classes, all \digit sequences are octal (no backreferences)
    p.advance()
    var octStr = $ch
    for _ in 0 ..< 2:
      if p.peek in {'0' .. '7'}:
        octStr.add(p.peek)
        p.advance()
      else:
        break
    CcAtom(kind: ccLiteral, rune: Rune(parseOctInt(octStr)))
  of 'c':
    p.advance()
    if p.atEnd:
      p.error("unexpected end after '\\c'")
    var ctrlCh: char
    if p.peek == '\\':
      p.advance() # skip first '\'
      if p.atEnd:
        p.error("unexpected end after '\\c\\'")
      ctrlCh = p.peek
      p.advance()
    else:
      ctrlCh = p.peek
      p.advance()
    CcAtom(kind: ccLiteral, rune: Rune(ord(ctrlCh) and 0x1F))
  of 'C':
    p.advance()
    if p.peek == '-':
      p.advance()
      if p.atEnd:
        p.error("unexpected end after '\\C-'")
      let ctrlCh = p.peek
      p.advance()
      CcAtom(kind: ccLiteral, rune: Rune(ord(ctrlCh) and 0x1F))
    else:
      p.error("expected '-' after '\\C'")
  of 'p':
    p.advance()
    if p.peek == '{':
      p.advance()
      var name = ""
      while p.peek != '}' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      if name.len == 0:
        p.error("empty Unicode property name")
      p.expect('}')
      # \p{^Prop} = negated property
      if name.len > 1 and name[0] == '^':
        CcAtom(kind: ccNegUnicodeProp, propName: name[1 ..^ 1])
      else:
        CcAtom(kind: ccUnicodeProp, propName: name)
    else:
      if p.atEnd or p.peek notin {'A' .. 'Z', 'a' .. 'z'}:
        p.error("invalid Unicode property name")
      var name = ""
      name.add(p.peek)
      p.advance()
      if name[0] notin {'L', 'M', 'N', 'P', 'S', 'Z', 'C'}:
        p.error("invalid Unicode property '" & name & "'")
      CcAtom(kind: ccUnicodeProp, propName: name)
  of 'P':
    p.advance()
    if p.peek == '{':
      p.advance()
      var name = ""
      while p.peek != '}' and not p.atEnd:
        name.add(p.peek)
        p.advance()
      if name.len == 0:
        p.error("empty Unicode property name")
      p.expect('}')
      # \P{^Prop} = double negation = positive
      if name.len > 1 and name[0] == '^':
        CcAtom(kind: ccUnicodeProp, propName: name[1 ..^ 1])
      else:
        CcAtom(kind: ccNegUnicodeProp, propName: name)
    else:
      if p.atEnd or p.peek notin {'A' .. 'Z', 'a' .. 'z'}:
        p.error("invalid Unicode property name")
      var name = ""
      name.add(p.peek)
      p.advance()
      if name[0] notin {'L', 'M', 'N', 'P', 'S', 'Z', 'C'}:
        p.error("invalid Unicode property '" & name & "'")
      CcAtom(kind: ccNegUnicodeProp, propName: name)
  else:
    # Literal escape: \], \-, \\, \[, etc.
    let r = p.advanceRune()
    CcAtom(kind: ccLiteral, rune: r)

proc parsePosixClass(p: var CcParser): CcAtom =
  ## Parse [:alpha:] or [:^alpha:] POSIX bracket expression.
  ## Assumes we're at the '[' of '[:'.
  p.advance() # skip '['
  p.advance() # skip ':'

  var negated = false
  if p.peek == '^':
    negated = true
    p.advance()

  var name = ""
  while p.peek != ':' and p.peek != ']' and not p.atEnd:
    name.add(p.peek)
    p.advance()

  if p.peek != ':' or p.peekAt(1) != ']':
    p.error("unterminated POSIX class '[:'" & name)

  p.advance() # skip ':'
  p.advance() # skip ']'

  let cls =
    case name
    of "alnum":
      pcAlnum
    of "alpha":
      pcAlpha
    of "ascii":
      pcAscii
    of "blank":
      pcBlank
    of "cntrl":
      pcCntrl
    of "digit":
      pcDigit
    of "graph":
      pcGraph
    of "lower":
      pcLower
    of "print":
      pcPrint
    of "punct":
      pcPunct
    of "space":
      pcSpace
    of "upper":
      pcUpper
    of "xdigit":
      pcXdigit
    of "word":
      pcWord
    else:
      p.error("unknown POSIX class '" & name & "'")

  if negated:
    CcAtom(kind: ccNegPosix, posixClass: cls)
  else:
    CcAtom(kind: ccPosix, posixClass: cls)

proc parseCharClassBody(p: var CcParser): (bool, seq[CcAtom])

proc isPosixClass(p: CcParser): bool =
  ## Check if current position starts a valid POSIX class [:name:]
  ## by scanning ahead for the ':' ']' terminator.
  ## Rejects empty names ([::]]) — these are treated as nested classes.
  if p.peekAt(1) != ':':
    return false
  var i = p.pos + 2
  if i < p.src.len and p.src[i] == '^':
    inc i
  let nameStart = i
  while i < p.src.len and p.src[i] != ':' and p.src[i] != ']' and p.src[i] != '[':
    inc i
  if not (i + 1 < p.src.len and p.src[i] == ':' and p.src[i + 1] == ']'):
    return false
  i > nameStart # reject empty name

proc parseCcAtom(p: var CcParser): CcAtom =
  ## Parse a single atom inside a character class.
  # Skip stray \E (end of literal quote or standalone)
  while not p.atEnd and p.peek == '\\' and p.peekAt(1) == 'E':
    p.advance()
    p.advance()
  if p.peek == '[':
    # Could be POSIX class [:alpha:] or nested character class
    if p.isPosixClass():
      return p.parsePosixClass()
    elif p.peekAt(1) in {'=', '.', ','}:
      # Failed POSIX-like attempt ([=, [., [,) — treat '[' as literal
      let r = p.advanceRune()
      return CcAtom(kind: ccLiteral, rune: r)
    else:
      # Nested character class (Oniguruma supports [a-z&&[^aeiou]])
      p.advance() # skip '['
      let (neg, atoms) = p.parseCharClassBody()
      if p.peek != ']':
        p.error("unterminated nested character class")
      p.advance() # skip ']'
      return CcAtom(kind: ccNestedClass, nestedAtoms: atoms, nestedNegated: neg)
  elif p.peek == '\\':
    if p.peekAt(1) == 'Q':
      # \Q...\E literal quoting inside char class atom
      p.advance() # skip '\'
      p.advance() # skip 'Q'
      var qAtoms: seq[CcAtom]
      while not p.atEnd:
        if p.peek == '\\' and p.peekAt(1) == 'E':
          p.advance()
          p.advance()
          break
        qAtoms.add(CcAtom(kind: ccLiteral, rune: p.advanceRune()))
      if qAtoms.len == 0:
        # Empty \Q\E — skip, recurse to get next atom
        return p.parseCcAtom()
      elif qAtoms.len == 1:
        return qAtoms[0]
      else:
        for i in 1 ..< qAtoms.len:
          p.pendingAtoms.add(qAtoms[i])
        return qAtoms[0]
    return p.parseCcEscape()
  else:
    let r = p.advanceRune()
    return CcAtom(kind: ccLiteral, rune: r)

proc isCharTypeAtom(a: CcAtom): bool =
  a.kind in
    {ccCharType, ccPosix, ccNegPosix, ccUnicodeProp, ccNegUnicodeProp, ccNestedClass}

proc parseCharClassBody(p: var CcParser): (bool, seq[CcAtom]) =
  ## Parse the body of a character class (after the opening '[').
  ## Returns (negated, atoms).
  var negated = false
  if p.peek == '^':
    negated = true
    p.advance()

  var atoms: seq[CcAtom]

  # ']' as first character (or first after '^') is a literal
  if p.peek == ']':
    atoms.add(CcAtom(kind: ccLiteral, rune: Rune(ord(']'))))
    p.advance()

  while not p.atEnd and p.peek != ']':
    # \Q...\E is handled by parseCcAtom (with pendingAtoms for range support)
    # Check for && intersection
    if p.peek == '&' and p.peekAt(1) == '&':
      p.advance() # skip first '&'
      p.advance() # skip second '&'
      let leftAtoms = atoms
      # Note: 'negated' is the outer class negation (^), applied to the
      # intersection result, NOT to the left operand. Left atoms already
      # contain their own negation (e.g. nested [^abc]).
      # Parse right side: all atoms until ] or another &&
      var rightNeg = false
      var rightAtoms: seq[CcAtom]
      (rightNeg, rightAtoms) = p.parseCharClassBody()
      atoms = @[
        CcAtom(
          kind: ccIntersection,
          interLeft: leftAtoms,
          interLeftNeg: false,
          interRight: rightAtoms,
          interRightNeg: rightNeg,
        )
      ]
      # Keep 'negated' as-is — outer ^ applies to the final result
      continue

    let rawAtom = p.parseCcAtom()

    # Handle multi-codepoint escapes: the last pending atom can participate
    # in range formation, earlier ones are added as literals.
    var atom: CcAtom
    if p.pendingAtoms.len > 0:
      atoms.add(rawAtom)
      for i in 0 ..< p.pendingAtoms.len - 1:
        atoms.add(p.pendingAtoms[i])
      atom = p.pendingAtoms[^1]
      p.pendingAtoms.setLen(0)
    else:
      atom = rawAtom

    # Skip \E before range check (for patterns like [a\E-\Ec])
    while not p.atEnd and p.peek == '\\' and p.peekAt(1) == 'E':
      p.advance()
      p.advance()
    # Check for range: atom '-' atom
    if p.peek == '-' and p.peekAt(1) != ']' and not p.atEnd:
      # Potential range
      if atom.kind == ccLiteral and not isCharTypeAtom(atom):
        let dashPos = p.pos
        p.advance() # skip '-'
        # Skip empty \Q\E after '-'
        while not p.atEnd and p.peek == '\\' and p.peekAt(1) == 'Q' and
            p.pos + 3 < p.src.len and p.src[p.pos + 2] == '\\' and
            p.src[p.pos + 3] == 'E'
        :
          p.pos += 4
        # Also skip stray \E
        while not p.atEnd and p.peek == '\\' and p.peekAt(1) == 'E':
          p.advance()
          p.advance()
        if p.atEnd or p.peek == ']':
          # '-' at end is literal
          atoms.add(atom)
          atoms.add(CcAtom(kind: ccLiteral, rune: Rune(ord('-'))))
          continue
        if p.peek == '[' or (p.peek == '&' and p.peekAt(1) == '&'):
          # '-' before '[' or '&&' is literal
          atoms.add(atom)
          atoms.add(CcAtom(kind: ccLiteral, rune: Rune(ord('-'))))
          continue
        let endAtom = p.parseCcAtom()
        if endAtom.kind == ccLiteral:
          if int32(atom.rune) > int32(endAtom.rune):
            p.error("invalid range in character class")
          atoms.add(CcAtom(kind: ccRange, rangeFrom: atom.rune, rangeTo: endAtom.rune))
          # Drain any pending atoms from multi-hex range end
          if p.pendingAtoms.len > 0:
            atoms.add(p.pendingAtoms)
            p.pendingAtoms.setLen(0)
          continue
        elif endAtom.kind == ccRange:
          # \x{0063-0065} as range endpoint is invalid
          p.error("invalid code point value")
        else:
          # Can't form range with non-literal end, treat '-' as literal
          p.pos = dashPos
          atoms.add(atom)
          continue
      else:
        # Character type or non-literal can't start a range, just add it
        atoms.add(atom)
        continue

    # Standalone literal code point validation
    if atom.kind == ccLiteral and int32(atom.rune) > 0x10FFFF:
      p.error("invalid code point value")
    atoms.add(atom)

  result = (negated, atoms)

proc parseCharClass*(src: string, pos: int, flags: RegexFlags): (int, Node) =
  ## Parse a character class starting at '[' at position pos.
  ## Returns (new position after ']', Node).
  var p = initCcParser(src, pos, flags)
  p.advance() # skip '['

  let (negated, atoms) = p.parseCharClassBody()

  if p.atEnd or p.peek != ']':
    p.error("unterminated character class")
  p.advance() # skip ']'

  result = (
    p.position,
    Node(kind: nkCharClass, negated: negated, atoms: atoms, bracketClass: true),
  )
