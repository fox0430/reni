## Core type definitions shared across the reni regex engine.
##
## This module defines the AST node tags, character-class atoms, flag and
## anchor enums, the compiled ``Regex`` object, and the ``Match`` / ``Span``
## result types used by the parser, compiler, and engine.  It also hosts the
## first-character and required-byte optimization analyses that the compiler
## runs on the parsed AST.
##
## Most of the surface exposed here (``Node``, ``NodeKind``, ``CcAtom``,
## ``ast``, etc.) is **internal API** — exported only so sibling modules in
## this package can cooperate — and is not part of the stable public
## contract.  User code should consume the documented API re-exported from
## ``reni`` instead.

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

  UniPropKind* = enum
    ## How a resolved ``\p{...}`` property is evaluated at match time.
    ## The name is looked up once when the pattern is compiled so that the
    ## matcher never touches strings.
    upNever ## unknown name: matches nothing
    upAlways ## \p{Any}
    upCategory ## ``unicodeCategory(r)`` intersects ``catBits``
    upPosix ## ``matchPosixClass(r, posixCls, false)``
    upAscii ## code point <= U+007F
    upBlank ## space or tab
    upEmoji
    upExtPict
    upBlock ## code point inside ``blockRanges[blockIdx]``
    upScript ## ``unicodeScript(r)`` equals ``scriptId``

  UniAsciiRestrict* = enum
    ## Which flag, if any, downgrades a property to its ASCII-only POSIX
    ## equivalent (``restrictCls``).  ``rfAsciiPosix`` implies all of them.
    uarNone
    uarWord ## (?W) or (?P)
    uarDigit ## (?D) or (?P)
    uarSpace ## (?S) or (?P)
    uarPosix ## (?P) only

  UniProp* = object
    ## A ``\p{...}`` property resolved to a flag-independent matcher plus an
    ## optional ASCII restriction applied when the matching flags ask for it.
    ## ``catBits`` and ``scriptId`` hold ``UnicodeCategorySet`` / ``UnicodeScript``
    ## values as plain integers so this module stays free of ``unicodedb``.
    kind*: UniPropKind
    catBits*: int32
    posixCls*: PosixClassName
    blockIdx*: int32
    scriptId*: int32
    restrict*: UniAsciiRestrict
    restrictCls*: PosixClassName

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
      prop*: UniProp ## ``propName`` resolved at compile time
    of ccNestedClass:
      nestedAtoms*: seq[CcAtom]
      nestedNegated*: bool
    of ccIntersection:
      interLeft*: seq[CcAtom]
      interLeftNeg*: bool
      interRight*: seq[CcAtom]
      interRightNeg*: bool

  FirstCharKind* = enum
    fcNone ## no optimization possible
    fcByte ## pattern must start with this exact byte (ASCII, case-sensitive)
    fcByteSet ## pattern must start with one of these bytes
    fcAnchorStart ## pattern is anchored with \A — only try pos 0
    fcLineStart ## pattern starts with ^ — only try line beginnings

  FirstCharInfo* = object
    case kind*: FirstCharKind
    of fcByte:
      byte*: uint8
    of fcByteSet:
      bytes*: set[uint8]
    of fcNone, fcAnchorStart, fcLineStart:
      discard

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

  Node* {.acyclic.} = ref object
    ## **Internal API.** The parsed / compiled AST is not part of the public
    ## contract. Fields are exported only so that `compiler` and `engine`
    ## (which live in separate modules) can walk the tree. User code MUST
    ## NOT read or mutate Node fields; the shape is subject to change
    ## without notice, and mutating a Node on a compiled `Regex` will
    ## corrupt the matcher state.
    ##
    ## ``{.acyclic.}``: the parser constructs trees strictly top-down and
    ## the compiler never splices a node back into its own subtree.
    ## ``nkSubexpCall`` resolves by index/name at match time, never by
    ## pointer back-edge.
    case kind*: NodeKind
    of nkLiteral:
      rune*: Rune
    of nkEscapedLiteral:
      escapedRune*: Rune
    of nkConcat:
      children*: seq[Node]
    of nkAlternation:
      alternatives*: seq[Node]
      altFirst*: seq[FirstCharInfo]
        ## Per-alternative first-byte hint, filled in by the compiler after
        ## the AST is final.  Computed as if ``(?i)`` were on, so it stays a
        ## superset whatever flags are active when the matcher reaches here.
        ## Empty means "no hints": every alternative is tried.
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
      asciiSet*: set[uint8]
        ## Membership of every ASCII code point, negation already applied.
        ## Filled in by the compiler when ``asciiSetOk``; the matcher then
        ## answers ASCII input with one bit test instead of walking the atoms.
      asciiSetOk*: bool
        ## ``asciiSet`` is exact.  Only true for classes whose atoms all read
        ## the same below U+0080 whatever the ASCII-restriction flags say;
        ## the matcher still falls back to the atoms under (?i), which brings
        ## case-fold variants into play.
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

const
  acWord* = 0x0001'u16
  acDigit* = 0x0002'u16
  acSpace* = 0x0004'u16
  acAlpha* = 0x0008'u16
  acLower* = 0x0010'u16
  acUpper* = 0x0020'u16
  acPunct* = 0x0040'u16
  acCntrl* = 0x0080'u16
  acXdigit* = 0x0100'u16
  acBlank* = 0x0200'u16
  acGraph* = 0x0400'u16
  acPrint* = 0x0800'u16
  acAlnum* = 0x1000'u16

proc buildAsciiClassTable(): array[128, uint16] =
  ## Membership bits for every ASCII code point.  Below U+0080 the Unicode
  ## and ASCII-only readings of ``\w``, ``\d``, ``\s`` and every POSIX class
  ## coincide, so one table answers both and the matcher never has to consult
  ## the Unicode category database for ASCII input.
  for c in 0 .. 127:
    var f = 0'u16
    if c >= ord('a') and c <= ord('z'):
      f = f or acLower or acAlpha
    if c >= ord('A') and c <= ord('Z'):
      f = f or acUpper or acAlpha
    if c >= ord('0') and c <= ord('9'):
      f = f or acDigit
    if (c >= ord('0') and c <= ord('9')) or (c >= ord('a') and c <= ord('f')) or
        (c >= ord('A') and c <= ord('F')):
      f = f or acXdigit
    if (f and (acAlpha or acDigit)) != 0:
      f = f or acAlnum
    if (f and acAlnum) != 0 or c == ord('_'):
      f = f or acWord
    if c == 0x20 or (c >= 0x09 and c <= 0x0D):
      f = f or acSpace
    if c == 0x20 or c == 0x09:
      f = f or acBlank
    if c < 0x20 or c == 0x7F:
      f = f or acCntrl
    if c > 0x20 and c < 0x7F:
      f = f or acGraph
    if c >= 0x20 and c < 0x7F:
      f = f or acPrint
    if (f and acGraph) != 0 and (f and acAlnum) == 0:
      f = f or acPunct
    result[c] = f

const AsciiClassTable* = buildAsciiClassTable()

proc asciiBytes(bits: uint16, present: bool): set[uint8] =
  ## The ASCII bytes whose class bits do (or do not) intersect ``bits``.
  for c in 0 .. 127:
    if ((AsciiClassTable[c] and bits) != 0) == present:
      result.incl(uint8(c))

const
  AllAsciiBytes* = {0'u8 .. 127'u8}
  NonAsciiBytes* = {0x80'u8 .. 0xFF'u8}
    ## Every byte a non-ASCII code point can start with.  That is all of them:
    ## the subject is never validated, and ``fastRuneAt`` decodes a byte that
    ## begins no well-formed sequence as a lone code point anyway (0x80..0xBF
    ## and 0xFE..0xFF as themselves, 0xF8..0xFD as U+FFFD).  Skipping such a
    ## byte would miss matches the engine accepts, so none is ever skipped.
  WordAsciiBytes* = asciiBytes(acWord, true)
  NotWordAsciiBytes* = asciiBytes(acWord, false)
  DigitAsciiBytes* = asciiBytes(acDigit, true)
  NotDigitAsciiBytes* = asciiBytes(acDigit, false)
  SpaceAsciiBytes* = asciiBytes(acSpace, true)
  NotSpaceAsciiBytes* = asciiBytes(acSpace, false)
  XdigitAsciiBytes* = asciiBytes(acXdigit, true)
  NotXdigitAsciiBytes* = asciiBytes(acXdigit, false)

template asciiHas*(c: int32, bits: uint16): bool =
  (AsciiClassTable[c] and bits) != 0

type
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
    levelBackrefs: bool

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

proc levelBackrefs*(r: Regex): bool {.inline.} =
  ## Whether the pattern uses a recursion-level backreference
  ## (``\k<name+1>``).  Only then does the matcher have to maintain the
  ## per-group capture history, which costs a write on every capture.
  r.levelBackrefs

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
    levelBackrefs: bool = false,
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
    levelBackrefs: levelBackrefs,
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

proc usesLevelBackrefs*(node: Node): bool =
  ## Walk the AST looking for a backreference that reads the capture history.
  if node == nil:
    return false
  case node.kind
  of nkBackreference:
    if node.backrefLevel != 0:
      return true
  of nkNamedBackref:
    if node.namedBackrefLevel != 0:
      return true
  else:
    discard
  for child in node.childNodes:
    if usesLevelBackrefs(child):
      return true
  false

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
  if a.kind in {fcAnchorStart, fcLineStart} or b.kind in {fcAnchorStart, fcLineStart}:
    return
      if a.kind == b.kind:
        FirstCharInfo(kind: a.kind)
      else:
        FirstCharInfo(kind: fcNone)
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

proc byteSetInfo(bs: set[uint8]): FirstCharInfo =
  if bs.card == 0:
    FirstCharInfo(kind: fcNone)
  elif bs.card == 1:
    var b: uint8
    for v in bs:
      b = v
    FirstCharInfo(kind: fcByte, byte: b)
  else:
    FirstCharInfo(kind: fcByteSet, bytes: bs)

proc charTypeBytes(ct: CharTypeKind): set[uint8] =
  ## Bytes a character type can start with, or ``{}`` when it can start
  ## with anything.  Always the widest (Unicode) reading: the ASCII-only
  ## flags can be switched on at match time and only ever shrink the set, so
  ## a superset stays sound.
  case ct
  of ctWord:
    WordAsciiBytes + NonAsciiBytes
  of ctNotWord:
    NotWordAsciiBytes + NonAsciiBytes
  of ctDigit:
    DigitAsciiBytes + NonAsciiBytes
  of ctNotDigit:
    NotDigitAsciiBytes + NonAsciiBytes
  of ctSpace:
    SpaceAsciiBytes + NonAsciiBytes
  of ctNotSpace:
    NotSpaceAsciiBytes + NonAsciiBytes
  of ctHexDigit:
    # Only ASCII code points are hex digits, so no non-ASCII byte can start
    # one.  (An overlong sequence still decodes to ASCII, but the same is
    # true of every ASCII-only byte set here.)
    XdigitAsciiBytes
  of ctNotHexDigit:
    NotXdigitAsciiBytes + NonAsciiBytes
  of ctNotNewline:
    (AllAsciiBytes - {0x0A'u8}) + NonAsciiBytes
  of ctNewlineSeq:
    # U+0085 and U+2028/U+2029 are also line separators, and a malformed byte
    # can decode straight to one of them.
    {0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8} + NonAsciiBytes
  of ctDot, ctAnyChar, ctGraphemeCluster:
    {} # `.` follows (?m) at match time, the other two match anything

proc posixBytes(cls: PosixClassName): set[uint8] =
  ## ASCII members of a POSIX class.  ``matchPosixClass`` agrees with the
  ## table below U+0080 whatever the ASCII-restriction flags say.
  case cls
  of pcAlnum:
    asciiBytes(acAlnum, true)
  of pcAlpha:
    asciiBytes(acAlpha, true)
  of pcAscii:
    AllAsciiBytes
  of pcBlank:
    asciiBytes(acBlank, true)
  of pcCntrl:
    asciiBytes(acCntrl, true)
  of pcDigit:
    DigitAsciiBytes
  of pcGraph:
    asciiBytes(acGraph, true)
  of pcLower:
    asciiBytes(acLower, true)
  of pcPrint:
    asciiBytes(acPrint, true)
  of pcPunct:
    asciiBytes(acPunct, true)
  of pcSpace:
    SpaceAsciiBytes
  of pcUpper:
    asciiBytes(acUpper, true)
  of pcXdigit:
    XdigitAsciiBytes
  of pcWord:
    WordAsciiBytes

const
  SKFoldBytes = {uint8('s'), uint8('S'), uint8('k'), uint8('K')}
    ## The only ASCII letters a non-ASCII rune folds to: ſ (U+017F) → s and
    ## K (U+212A) → k.
  MultiCharFoldLeadBytes = {
    uint8('a'),
    uint8('A'),
    uint8('f'),
    uint8('F'),
    uint8('h'),
    uint8('H'),
    uint8('i'),
    uint8('I'),
    uint8('j'),
    uint8('J'),
    uint8('s'),
    uint8('S'),
    uint8('t'),
    uint8('T'),
    uint8('w'),
    uint8('W'),
    uint8('y'),
    uint8('Y'),
  }
    ## First letters of the multi-character case-fold expansions (ß → "ss",
    ## ﬁ → "fi", ẘ → "w"+ring, …).  Under (?i) a bracket class holding the
    ## source rune matches the expansion, so the subject can start with any
    ## of these.

proc classAsciiMatches*(
    node: Node, ascii: var set[uint8], nonAscii, predicate: var bool
): bool =
  ## Compute the ASCII bytes the class's atoms match *without* case folding,
  ## whether it can reach beyond ASCII, and whether it uses a predicate atom
  ## (``\w`` / POSIX).  Below U+0080 the atoms read the same whatever the
  ## ASCII-restriction flags say, so the byte set is exact — which is what
  ## lets a negated class complement it and the matcher use it directly.
  ## Returns false when an atom is out of reach (``\p{...}``, nesting,
  ## intersection).
  ascii = {}
  nonAscii = false
  predicate = false
  for atom in node.atoms:
    case atom.kind
    of ccLiteral:
      let cp = int32(atom.rune)
      if cp < 128:
        ascii.incl(uint8(cp))
      else:
        nonAscii = true
    of ccRange:
      let lo = int32(atom.rangeFrom)
      let hi = int32(atom.rangeTo)
      if hi >= 128:
        nonAscii = true
      for c in max(lo, 0) .. min(hi, 127):
        ascii.incl(uint8(c))
    of ccCharType:
      predicate = true
      case atom.charType
      of ctDot, ctAnyChar, ctGraphemeCluster:
        # Inside a class these accept anything.
        ascii = AllAsciiBytes
        nonAscii = true
      else:
        let bs = charTypeBytes(atom.charType)
        ascii = ascii + (bs * AllAsciiBytes)
        if (bs - AllAsciiBytes).card > 0:
          nonAscii = true
    of ccPosix:
      ascii = ascii + posixBytes(atom.posixClass)
      nonAscii = true # POSIX classes are Unicode-aware outside ASCII
      predicate = true
    of ccNegPosix:
      ascii = ascii + (AllAsciiBytes - posixBytes(atom.posixClass))
      nonAscii = true
      predicate = true
    else:
      return false
  true

proc classFirstChar(node: Node, flags: RegexFlags): FirstCharInfo =
  ## Lead bytes a character class can start with — always a superset of the
  ## truth, so the scan never skips a position the class could match.
  var matched: set[uint8]
  var nonAscii, predicate: bool
  if not classAsciiMatches(node, matched, nonAscii, predicate):
    return FirstCharInfo(kind: fcNone)
  if node.negated:
    # ``matched`` is exact below U+0080 and case folding only ever adds to
    # it, so its complement is a superset of what the negated class accepts.
    return byteSetInfo((AllAsciiBytes - matched) + NonAsciiBytes)
  var ascii = matched
  if rfIgnoreCase in flags:
    if predicate or nonAscii:
      # A fold variant of an ASCII byte can satisfy a predicate the byte
      # itself does not ((?iW:[[:^word:]]) matching "s" through ſ), and a
      # non-ASCII member can expand to arbitrary ASCII.  Give up.
      return FirstCharInfo(kind: fcNone)
    for b in matched:
      ascii = ascii + asciiFoldBytes(b)
    ascii = ascii + SKFoldBytes
    if node.bracketClass:
      ascii = ascii + MultiCharFoldLeadBytes
    return byteSetInfo(ascii + NonAsciiBytes)
  if nonAscii:
    ascii = ascii + NonAsciiBytes
  byteSetInfo(ascii)

proc extractFirstChar*(node: Node, flags: RegexFlags): FirstCharInfo =
  ## Extract optimization hint about the first character/anchor of a pattern.
  if node == nil:
    return FirstCharInfo(kind: fcNone)
  case node.kind
  of nkAnchor:
    case node.anchor
    of akStringBegin:
      FirstCharInfo(kind: fcAnchorStart)
    of akLineBegin:
      FirstCharInfo(kind: fcLineStart)
    else:
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
    var lineStart = false
    for child in node.children:
      # Accumulate flags from bare flag groups (e.g., (?i) sets case-insensitive)
      if child.kind == nkFlagGroup and child.flagBody == nil:
        currentFlags = currentFlags + child.flagsOn - child.flagsOff
        continue
      let info = extractFirstChar(child, currentFlags)
      if info.kind == fcLineStart:
        # ``^`` is zero-width: remember it, but keep looking for a byte hint,
        # which skips over more of the subject than jumping line to line.
        # Only a bare anchor is safe to look past.  A subtree such as
        # ``(^a*)`` also reports ``fcLineStart`` yet can consume input, so the
        # next child's byte is not the pattern's first byte and using it as a
        # scan hint would skip valid start positions.
        lineStart = true
        if child.kind == nkAnchor:
          continue
        break
      if info.kind != fcNone:
        return info
      # Zero-width nodes: skip and try the next child
      if child.kind in
          {nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp}:
        continue
      break # Non-zero-width node that returned fcNone: give up
    if lineStart:
      FirstCharInfo(kind: fcLineStart)
    else:
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
  of nkCharType:
    byteSetInfo(charTypeBytes(node.charType))
  of nkCharClass:
    classFirstChar(node, flags)
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
