import std/unicode

type
  RegexError* = object of CatchableError
  RegexLimitError* = object of RegexError

  RegexFlag* = enum
    rfIgnoreCase ## (?i)
    rfMultiLine ## (?m) - dot matches newline (Oniguruma semantics)
    rfExtended ## (?x) - free-spacing mode
    rfAsciiWord ## (?W)
    rfAsciiDigit ## (?D)
    rfAsciiSpace ## (?S)
    rfAsciiPosix ## (?P)
    rfIgnoreCaseAscii ## (?I) - case-insensitive matching for ASCII only
    rfFindLongest ## (?L) - find longest match

  RegexFlags* = set[RegexFlag]

  QuantKind* = enum
    qkGreedy
    qkLazy ## *?, +?, ??
    qkPossessive ## *+, ++, ?+

  AnchorKind* = enum
    akLineBegin ## ^
    akLineEnd ## $
    akStringBegin ## \A
    akStringEnd ## \z
    akStringEndOrNewline ## \Z
    akWordBoundary ## \b
    akNotWordBoundary ## \B
    akSearchBegin ## \G
    akKeep ## \K
    akGraphemeBoundary ## \y
    akNotGraphemeBoundary ## \Y

  CharTypeKind* = enum
    ctWord ## \w
    ctNotWord ## \W
    ctDigit ## \d
    ctNotDigit ## \D
    ctSpace ## \s
    ctNotSpace ## \S
    ctDot ## .
    ctHexDigit ## \h (Oniguruma extension)
    ctNotHexDigit ## \H
    ctAnyChar ## \O (true any char, incl. newline)
    ctNewlineSeq ## \R (any newline sequence)
    ctNotNewline ## \N (not a newline)
    ctGraphemeCluster ## \X (extended grapheme cluster)

  GraphemeMode* = enum
    gmNone ## default (no grapheme mode)
    gmGrapheme ## (?y{g}) - grapheme cluster mode
    gmWord ## (?y{w}) - word mode

  AbsentKind* = enum
    abClear ## (?~) - matches empty
    abFunction ## (?~pattern) - longest match not containing pattern
    abExpression ## (?~|absent|expr) - match expr without absent
    abRange ## (?~|absent) - range marker (zero-width, sets constraint)

  LookaroundKind* = enum
    lkAhead ## (?=...)
    lkNegAhead ## (?!...)
    lkBehind ## (?<=...)
    lkNegBehind ## (?<!...)

  PosixClassName* = enum
    pcAlnum
    pcAlpha
    pcAscii
    pcBlank
    pcCntrl
    pcDigit
    pcGraph
    pcLower
    pcPrint
    pcPunct
    pcSpace
    pcUpper
    pcXdigit
    pcWord

  CcAtomKind* = enum
    ccLiteral ## single code point
    ccRange ## a-z
    ccPosix ## [:alpha:]
    ccNegPosix ## [:^alpha:]
    ccCharType ## \w, \d, \s inside class
    ccUnicodeProp ## \p{Print}
    ccNegUnicodeProp ## \P{Print}
    ccNestedClass ## [...] inside [...]
    ccIntersection ## && inside [...]

  CcAtom* = object
    case kind*: CcAtomKind
    of ccLiteral:
      rune*: Rune
    of ccRange:
      rangeFrom*, rangeTo*: Rune
    of ccPosix, ccNegPosix:
      posixClass*: PosixClassName
    of ccCharType:
      charType*: CharTypeKind
    of ccUnicodeProp, ccNegUnicodeProp:
      propName*: string
    of ccNestedClass:
      nestedAtoms*: seq[CcAtom]
      nestedNegated*: bool
    of ccIntersection:
      interLeft*: seq[CcAtom]
      interLeftNeg*: bool
      interRight*: seq[CcAtom]
      interRightNeg*: bool

  NodeKind* = enum
    ## **Internal API.** The AST node tag set is an implementation detail
    ## exposed only so tests inside this repository can inspect parsed trees.
    ## User code MUST NOT depend on individual node kinds — they may be
    ## renamed, merged, or removed at any time without notice.
    nkLiteral ## single rune
    nkEscapedLiteral ## \n, \t, \x{HHHH}, etc.
    nkConcat ## sequence of nodes
    nkAlternation ## a|b
    nkCapture ## (...) capturing group
    nkNamedCapture ## (?<name>...)
    nkGroup ## (?:...) non-capturing
    nkFlagGroup ## (?imx:...) or isolated (?imx)
    nkQuantifier ## *, +, ?, {n,m}
    nkCharClass ## [...]
    nkAnchor ## ^, $, \b, \A, \G, etc.
    nkCharType ## \w, \d, \s, .
    nkBackreference ## \1-\9
    nkNamedBackref ## \k<name>
    nkLookaround ## (?=), (?!), (?<=), (?<!)
    nkAtomicGroup ## (?>...)
    nkConditional ## (?(cond)yes|no)
    nkSubexpCall ## \g<name>, \g<n>, \g'name', \g'0'
    nkAbsent ## (?~...) absent operator
    nkCalloutMax ## (*MAX{n}) - limit branch repetitions
    nkCalloutCount ## (*COUNT[tag]{var}) - count branch executions
    nkCalloutCmp ## (*CMP{var1,op,var2}) - compare counters
    nkString ## optimized run of consecutive literals

  ConditionalKind* = enum
    ckBackref ## (?(n)...) - numeric backref condition
    ckNamedRef ## (?(<name>)...) or (?('name')...) - named ref condition
    ckAlwaysFalse ## (?(*FAIL)...) etc.
    ckAlwaysTrue ## (?()...) empty condition, (?({...})...) code condition
    ckRegexCond ## (?(regex)...) - bare name that's not a capture group

  Node* = ref object
    ## **Internal API.** The parsed / compiled AST is not part of the public
    ## contract. Fields are exported only so that `compiler` and `engine`
    ## (which live in separate modules) can walk the tree. User code MUST
    ## NOT read or mutate Node fields; the shape is subject to change
    ## without notice, and mutating a Node on a compiled `Regex` will
    ## corrupt the matcher state.
    case kind*: NodeKind
    of nkLiteral:
      rune*: Rune
    of nkEscapedLiteral:
      escapedRune*: Rune
    of nkConcat:
      children*: seq[Node]
    of nkAlternation:
      alternatives*: seq[Node]
    of nkCapture:
      captureIndex*: int
      captureBody*: Node
    of nkNamedCapture:
      captureName*: string
      namedCaptureIndex*: int
      namedCaptureBody*: Node
    of nkGroup:
      groupBody*: Node
    of nkFlagGroup:
      flagsOn*: RegexFlags
      flagsOff*: RegexFlags
      flagBody*: Node ## nil for isolated (?imx) form
      graphemeMode*: GraphemeMode ## (?y{g}) or (?y{w})
    of nkQuantifier:
      quantMin*: int
      quantMax*: int ## -1 = unbounded
      quantKind*: QuantKind
      quantBody*: Node
    of nkCharClass:
      negated*: bool
      atoms*: seq[CcAtom]
      bracketClass*: bool ## true when from [...] syntax (enables case-fold matching)
    of nkAnchor:
      anchor*: AnchorKind
    of nkCharType:
      charType*: CharTypeKind
    of nkBackreference:
      backrefIndex*: int
      backrefLevel*: int ## recursion-level offset for \k<n+level> (0 = normal)
    of nkNamedBackref:
      backrefName*: string
      namedBackrefLevel*: int ## recursion-level offset for \k<name+level> (0 = normal)
    of nkLookaround:
      lookKind*: LookaroundKind
      lookBody*: Node
    of nkAtomicGroup:
      atomicBody*: Node
    of nkConditional:
      condKind*: ConditionalKind
      condRefIndex*: int ## capture index for ckBackref
      condRefName*: string ## capture name for ckNamedRef
      condYes*: Node ## yes branch
      condNo*: Node ## no branch (nil if absent)
      condBody*: Node ## regex body for ckRegexCond
    of nkSubexpCall:
      callIndex*: int ## capture group index to call (-1 for named)
      callName*: string ## capture group name (empty for numeric)
    of nkAbsent:
      absentKind*: AbsentKind
      absentBody*: Node ## absent pattern (nil for abClear)
      absentExpr*: Node ## expression to match (for abExpression only)
    of nkCalloutMax:
      maxCount*: int ## max repetition count
      maxTag*: string ## tag name (empty for default)
    of nkCalloutCount:
      countTag*: string ## counter tag (e.g., "AB")
      countVar*: string ## variable name (e.g., "X")
    of nkCalloutCmp:
      cmpLeft*: string ## left variable tag
      cmpOp*: string ## comparison operator (<, >, ==, !=, <=, >=)
      cmpRight*: string ## right variable tag
    of nkString:
      runes*: seq[Rune] ## consecutive literal runes

  FirstCharKind* = enum
    fcNone ## no optimization possible
    fcByte ## pattern must start with this exact byte (ASCII, case-sensitive)
    fcByteSet ## pattern must start with one of these bytes
    fcAnchorStart ## pattern is anchored with \A — only try pos 0

  FirstCharInfo* = object
    case kind*: FirstCharKind
    of fcByte:
      byte*: uint8
    of fcByteSet:
      bytes*: set[uint8]
    of fcNone, fcAnchorStart:
      discard

  RequiredByteInfo* = object
    valid*: bool
    byte*: uint8

  Regex* = object
    pattern: string
    ast: Node
    flags*: RegexFlags
    captureCount: int
    namedCaptures: seq[(string, int)]
    groupBodies: seq[Node]
    groupFlags*: seq[RegexFlags] ## flags active when each group was defined
    firstCharInfo: FirstCharInfo
    requiredByte: RequiredByteInfo

  Span* = object
    ## Half-open byte range [a, b). `a` is the start (inclusive), `b` is
    ## the end (exclusive).  A negative `a` means the span is unset.
    a*: int
    b*: int

  Match* = object
    found*: bool
    boundaries*: seq[Span]

const DefaultStepLimit* = 1_000_000
const DefaultMaxRecursionDepth* = 50

const UnsetSpan* = Span(a: -1, b: -1)
  ## Sentinel span returned by API accessors when a span is unset or out of
  ## range (e.g. a non-participating capture group, or `matchSpan` on a
  ## `Match` where `found` is false).

proc pattern*(r: Regex): string {.inline.} =
  r.pattern

proc ast*(r: Regex): Node {.inline.} =
  ## **Internal API.** Returns the compiled AST root. Exposed only for
  ## parser/engine tests inside this repository. User code MUST NOT depend
  ## on this accessor or on ``Node`` — both are implementation details
  ## and WILL be removed or restricted in a future release. Use the
  ## documented API (``captureText``, ``captureSpan``, ``captureIndex``,
  ## ``captureCount``, ``namedCaptures``, ``pattern``) instead.
  r.ast

proc captureCount*(r: Regex): int {.inline.} =
  r.captureCount

proc namedCaptures*(r: Regex): seq[(string, int)] {.inline.} =
  r.namedCaptures

proc groupBodies*(r: Regex): seq[Node] {.inline.} =
  r.groupBodies

proc firstCharInfo*(r: Regex): FirstCharInfo {.inline.} =
  r.firstCharInfo

proc requiredByte*(r: Regex): RequiredByteInfo {.inline.} =
  r.requiredByte

proc initRegex*(
    pattern: string,
    ast: Node,
    flags: RegexFlags,
    captureCount: int,
    namedCaptures: seq[(string, int)],
    groupBodies: seq[Node],
    groupFlags: seq[RegexFlags],
    firstCharInfo: FirstCharInfo,
    requiredByte: RequiredByteInfo = RequiredByteInfo(valid: false),
): Regex =
  Regex(
    pattern: pattern,
    ast: ast,
    flags: flags,
    captureCount: captureCount,
    namedCaptures: namedCaptures,
    groupBodies: groupBodies,
    groupFlags: groupFlags,
    firstCharInfo: firstCharInfo,
    requiredByte: requiredByte,
  )

proc span*(a, b: int): Span {.inline.} =
  Span(a: a, b: b)

proc `==`*(s: Span, sl: Slice[int]): bool {.inline.} =
  ## Convenience: allow ``check m.boundaries[0] == 0 .. 3``.
  s.a == sl.a and s.b == sl.b

proc `==`*(sl: Slice[int], s: Span): bool {.inline.} =
  s == sl

proc `$`*(s: Span): string =
  $s.a & " .. " & $s.b

iterator childNodes*(node: Node): Node =
  ## Yield all direct child nodes (skips nil).
  case node.kind
  of nkConcat:
    for c in node.children:
      yield c
  of nkAlternation:
    for a in node.alternatives:
      yield a
  of nkCapture:
    yield node.captureBody
  of nkNamedCapture:
    yield node.namedCaptureBody
  of nkGroup:
    yield node.groupBody
  of nkFlagGroup:
    if node.flagBody != nil:
      yield node.flagBody
  of nkQuantifier:
    yield node.quantBody
  of nkLookaround:
    yield node.lookBody
  of nkAtomicGroup:
    yield node.atomicBody
  of nkConditional:
    if node.condBody != nil:
      yield node.condBody
    if node.condYes != nil:
      yield node.condYes
    if node.condNo != nil:
      yield node.condNo
  of nkAbsent:
    if node.absentBody != nil:
      yield node.absentBody
    if node.absentExpr != nil:
      yield node.absentExpr
  else:
    discard

proc asciiFoldBytes(b: uint8): set[uint8] =
  ## Return {lower, upper} for ASCII letters, {b} otherwise.
  if b >= uint8('a') and b <= uint8('z'):
    {b, b - 32}
  elif b >= uint8('A') and b <= uint8('Z'):
    {b, b + 32}
  else:
    {b}

proc toByteSet(info: FirstCharInfo): set[uint8] =
  ## Convert a FirstCharInfo to a byte set (for merging).
  case info.kind
  of fcByte:
    {info.byte}
  of fcByteSet:
    info.bytes
  else:
    {}

proc mergeFirstChar(a, b: FirstCharInfo): FirstCharInfo =
  ## Merge two FirstCharInfo for alternation (union of acceptable bytes).
  if a.kind == fcNone or b.kind == fcNone:
    return FirstCharInfo(kind: fcNone)
  if a.kind == fcAnchorStart and b.kind == fcAnchorStart:
    return FirstCharInfo(kind: fcAnchorStart)
  if a.kind == fcAnchorStart or b.kind == fcAnchorStart:
    return FirstCharInfo(kind: fcNone)
  # Both are fcByte or fcByteSet
  let merged = a.toByteSet + b.toByteSet
  if merged.card == 1:
    for v in merged:
      return FirstCharInfo(kind: fcByte, byte: v)
  FirstCharInfo(kind: fcByteSet, bytes: merged)

proc utf8LeadByte(cp: int32): uint8 =
  ## Return the UTF-8 lead byte for a code point.
  if cp < 0x80:
    uint8(cp)
  elif cp < 0x800:
    uint8(0xC0 or (cp shr 6))
  elif cp < 0x10000:
    uint8(0xE0 or (cp shr 12))
  else:
    uint8(0xF0 or (cp shr 18))

proc hasNonAsciiFoldEquiv(cp: int32): bool =
  ## Check if an ASCII code point has non-ASCII characters that fold to it.
  ## Only 's' and 'k' have this property in Unicode case folding.
  let lower =
    if cp >= ord('A') and cp <= ord('Z'):
      cp + 32
    else:
      cp
  lower == ord('s') or lower == ord('k') # ſ (U+017F) ↔ s, K (U+212A) ↔ k

proc isMultiCharFoldPairStart(r1, r2: Rune): bool =
  ## Check if two consecutive runes form a pair that is the expansion of
  ## a multi-character case fold source (e.g., ss ← ß, st ← ﬆ).
  let c1 = int32(r1)
  let c2 = int32(r2)
  let lc1 =
    if c1 >= ord('A') and c1 <= ord('Z'):
      c1 + 32
    else:
      c1
  let lc2 =
    if c2 >= ord('A') and c2 <= ord('Z'):
      c2 + 32
    else:
      c2
  (lc1 == 0x73 and lc2 == 0x73) or # ss → ß, ẞ
  (lc1 == 0x73 and lc2 == 0x74) or # st → ﬅ, ﬆ
  (lc1 == 0x66 and lc2 == 0x66) or # ff → ﬀ
  (lc1 == 0x66 and lc2 == 0x69) or # fi → ﬁ
  (lc1 == 0x66 and lc2 == 0x6C) or # fl → ﬂ
  (lc1 == 0x6A and c2 == 0x030C) or # j+caron → ǰ
  (lc1 == 0x68 and c2 == 0x0331) or # h+macron → ẖ
  (lc1 == 0x74 and c2 == 0x0308) or # t+diaeresis → ẗ
  (lc1 == 0x77 and c2 == 0x030A) or # w+ring → ẘ
  (lc1 == 0x79 and c2 == 0x030A) # y+ring → ẙ

proc firstCharFromRune(cp: int32, flags: RegexFlags): FirstCharInfo =
  ## Build a FirstCharInfo from a code point, handling both ASCII and non-ASCII.
  if cp < 128:
    let b = uint8(cp)
    if rfIgnoreCase in flags:
      if hasNonAsciiFoldEquiv(cp):
        return FirstCharInfo(kind: fcNone)
      let bs = asciiFoldBytes(b)
      if bs.card == 1:
        FirstCharInfo(kind: fcByte, byte: b)
      else:
        FirstCharInfo(kind: fcByteSet, bytes: bs)
    else:
      FirstCharInfo(kind: fcByte, byte: b)
  elif rfIgnoreCase in flags:
    # Case-insensitive non-ASCII: skip optimization (fold targets may differ)
    FirstCharInfo(kind: fcNone)
  else:
    # Non-ASCII case-sensitive: use the UTF-8 lead byte for fast skip
    FirstCharInfo(kind: fcByte, byte: utf8LeadByte(cp))

proc extractFirstChar*(node: Node, flags: RegexFlags): FirstCharInfo =
  ## Extract optimization hint about the first character/anchor of a pattern.
  if node == nil:
    return FirstCharInfo(kind: fcNone)
  case node.kind
  of nkAnchor:
    if node.anchor == akStringBegin:
      return FirstCharInfo(kind: fcAnchorStart)
    FirstCharInfo(kind: fcNone)
  of nkLiteral:
    firstCharFromRune(int32(node.rune), flags)
  of nkEscapedLiteral:
    firstCharFromRune(int32(node.escapedRune), flags)
  of nkString:
    if node.runes.len > 0:
      let info = firstCharFromRune(int32(node.runes[0]), flags)
      if info.kind != fcNone and rfIgnoreCase in flags and node.runes.len >= 2:
        if isMultiCharFoldPairStart(node.runes[0], node.runes[1]):
          return FirstCharInfo(kind: fcNone)
      info
    else:
      FirstCharInfo(kind: fcNone)
  of nkConcat:
    var currentFlags = flags
    for child in node.children:
      # Accumulate flags from bare flag groups (e.g., (?i) sets case-insensitive)
      if child.kind == nkFlagGroup and child.flagBody == nil:
        currentFlags = currentFlags + child.flagsOn - child.flagsOff
        continue
      let info = extractFirstChar(child, currentFlags)
      if info.kind != fcNone:
        return info
      # Zero-width nodes: skip and try the next child
      if child.kind in
          {nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp}:
        continue
      break # Non-zero-width node that returned fcNone: give up
    FirstCharInfo(kind: fcNone)
  of nkCapture:
    extractFirstChar(node.captureBody, flags)
  of nkNamedCapture:
    extractFirstChar(node.namedCaptureBody, flags)
  of nkGroup:
    extractFirstChar(node.groupBody, flags)
  of nkFlagGroup:
    if node.flagBody != nil:
      extractFirstChar(node.flagBody, flags + node.flagsOn - node.flagsOff)
    else:
      FirstCharInfo(kind: fcNone)
  of nkQuantifier:
    if node.quantMin >= 1 and (node.quantMax < 0 or node.quantMax >= node.quantMin):
      extractFirstChar(node.quantBody, flags)
    else:
      FirstCharInfo(kind: fcNone)
  of nkAlternation:
    if node.alternatives.len == 0:
      return FirstCharInfo(kind: fcNone)
    var merged = extractFirstChar(node.alternatives[0], flags)
    if merged.kind == fcNone:
      return merged
    for i in 1 ..< node.alternatives.len:
      merged = mergeFirstChar(merged, extractFirstChar(node.alternatives[i], flags))
      if merged.kind == fcNone:
        return merged
    merged
  of nkAtomicGroup:
    extractFirstChar(node.atomicBody, flags)
  of nkCharClass:
    if node.negated or not node.bracketClass:
      return FirstCharInfo(kind: fcNone)
    # Try to extract a byte set from simple ASCII-only character classes
    var bs: set[uint8]
    for atom in node.atoms:
      case atom.kind
      of ccLiteral:
        let cp = int32(atom.rune)
        if cp >= 128:
          return FirstCharInfo(kind: fcNone)
        if rfIgnoreCase in flags:
          bs = bs + asciiFoldBytes(uint8(cp))
        else:
          bs.incl(uint8(cp))
      of ccRange:
        let lo = int32(atom.rangeFrom)
        let hi = int32(atom.rangeTo)
        if lo >= 128 or hi >= 128 or (hi - lo) > 64:
          return FirstCharInfo(kind: fcNone)
        for c in lo .. hi:
          if rfIgnoreCase in flags:
            bs = bs + asciiFoldBytes(uint8(c))
          else:
            bs.incl(uint8(c))
      else:
        return FirstCharInfo(kind: fcNone)
    if bs.card == 0:
      FirstCharInfo(kind: fcNone)
    elif bs.card == 1:
      var b: uint8
      for v in bs:
        b = v
      FirstCharInfo(kind: fcByte, byte: b)
    else:
      FirstCharInfo(kind: fcByteSet, bytes: bs)
  else:
    FirstCharInfo(kind: fcNone)

proc extractRequiredByte*(node: Node, flags: RegexFlags): RequiredByteInfo =
  ## Extract a byte that must appear somewhere in any successful match.
  ## Used to quickly reject subjects that cannot possibly match.
  if node == nil:
    return RequiredByteInfo(valid: false)
  case node.kind
  of nkLiteral:
    let cp = int32(node.rune)
    if cp < 128 and rfIgnoreCase notin flags:
      RequiredByteInfo(valid: true, byte: uint8(cp))
    else:
      RequiredByteInfo(valid: false)
  of nkEscapedLiteral:
    let cp = int32(node.escapedRune)
    if cp < 128 and rfIgnoreCase notin flags:
      RequiredByteInfo(valid: true, byte: uint8(cp))
    else:
      RequiredByteInfo(valid: false)
  of nkString:
    if node.runes.len > 0 and rfIgnoreCase notin flags:
      let cp = int32(node.runes[0])
      if cp < 128:
        return RequiredByteInfo(valid: true, byte: uint8(cp))
    RequiredByteInfo(valid: false)
  of nkConcat:
    for child in node.children:
      if child.kind == nkFlagGroup and child.flagBody == nil:
        continue
      if child.kind in
          {nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp}:
        continue
      let rb = extractRequiredByte(child, flags)
      if rb.valid:
        return rb
    RequiredByteInfo(valid: false)
  of nkCapture:
    extractRequiredByte(node.captureBody, flags)
  of nkNamedCapture:
    extractRequiredByte(node.namedCaptureBody, flags)
  of nkGroup:
    extractRequiredByte(node.groupBody, flags)
  of nkFlagGroup:
    if node.flagBody != nil:
      extractRequiredByte(node.flagBody, flags + node.flagsOn - node.flagsOff)
    else:
      RequiredByteInfo(valid: false)
  of nkQuantifier:
    if node.quantMin >= 1:
      extractRequiredByte(node.quantBody, flags)
    else:
      RequiredByteInfo(valid: false)
  of nkAtomicGroup:
    extractRequiredByte(node.atomicBody, flags)
  of nkConditional:
    # Both branches must require the same byte — too complex, skip
    RequiredByteInfo(valid: false)
  of nkAlternation:
    # All alternatives must require the same byte — too complex, skip
    RequiredByteInfo(valid: false)
  else:
    RequiredByteInfo(valid: false)
