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

import std/[hashes, tables, unicode]

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
    ## How a ``\p{...}`` property, resolved at compile time, is evaluated.
    upNever ## unknown name: matches nothing
    upAlways ## \p{Any}
    upCategory ## ``unicodeCategory(r)`` intersects ``catBits``
    upTypeMask ## ``unicodeTypes(r)`` shares *any* bit with ``typeBits``
    upPosix ## ``matchPosixClass(r, posixCls, false)``
    upWord ## bare ``\w`` / ``\p{Word}``: ``isWordChar(r, false)``
    upAscii ## code point <= U+007F
    upEmoji
    upExtPict
    upBlock ## code point inside ``blockRanges[blockIdx]``
    upScript ## ``unicodeScript(r)`` equals ``scriptId``

  UniAsciiRestrict* = enum
    ## Which flag downgrades a property to its ASCII-only POSIX equivalent
    ## (``restrictCls``).  ``rfAsciiPosix`` implies all of them.
    uarNone
    uarWord ## (?W) or (?P)
    uarDigit ## (?D) or (?P)
    uarSpace ## (?S) or (?P)
    uarPosix ## (?P) only

  UniProp* = object
    ## A ``\p{...}`` property resolved to a flag-independent matcher plus an
    ## optional ASCII restriction.  ``catBits``, ``typeBits`` and ``scriptId``
    ## hold ``unicodedb`` values as plain integers to keep it out of this module.
    kind*: UniPropKind
    catBits*: int32
    typeBits*: int32 ## OR, not AND: matches a rune having *any* of these bits.
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
      prop*: UniProp ## ``\p{...}`` name resolved at compile time
    of ccNestedClass:
      nestedAtoms*: seq[CcAtom]
      nestedNegated*: bool
    of ccIntersection:
      interLeft*: seq[CcAtom]
      interLeftNeg*: bool
      interRight*: seq[CcAtom]
      interRightNeg*: bool

  LenBounds* = object
    ## How much subject one AST node can consume, in bytes.  Both answers come
    ## from one walk of [lengthBounds] so they cannot disagree about the same
    ## facts — a case fold spanning two pattern characters, above all.
    maxLen*: int ## Upper bound on the bytes consumed; -1 when unbounded or unknown.
    fixedLen*: int ## The single length every match consumes; -1 when it varies.

  NodeKind* = enum
    ## **Internal API.** Exposed only so this repository's tests can inspect
    ## parsed trees; node kinds may change at any time without notice.
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
    ## **Internal API.** Fields are exported only so `compiler` and `engine`
    ## can walk the tree. The shape may change without notice, and mutating
    ## a Node on a compiled `Regex` corrupts the matcher state.
    ##
    ## ``{.acyclic.}``: trees are built strictly top-down and never spliced
    ## into themselves; ``nkSubexpCall`` resolves by index/name at match time.
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
        ## Per-alternative first-byte hint, filled in by the compiler, so the
        ## matcher can pass over a branch whose first byte is not the one in
        ## front of it.  Computed as if ``(?i)`` were on: ``rfIgnoreCase`` is
        ## the only flag the analysis reads, and switching it on only ever
        ## widens a hint or gives up, so the entry stays a superset whatever
        ## flags are live at match time.  Empty means "no hints" and every
        ## alternative is tried.
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
      quantBodyPure*: bool
        ## Raised by ``markQuantBodyPure``: true when ``quantBody`` provably
        ## writes none of the state a rollback snapshot restores (captures,
        ## ``\K``, flags/grapheme mode, ``subjectEnd``), so a possessive
        ## quantifier needs no per-iteration capture snapshot.  The default
        ## ``false`` is the safe value, so a node the pass never visits
        ## degrades to "always snapshot", never to "never".
    of nkCharClass:
      # The widest branch in the variant, so its layout alone decides
      # ``sizeof(Node[])`` -- see the check under the type.  Keep the bools
      # together at the end: split up by the seq and the set, each one takes a
      # padding slot of its own and the node grows past 64 bytes.
      atoms*: seq[CcAtom]
      asciiSet*: set[uint8]
        ## The ASCII bytes the class's atoms match, *before* negation — what
        ## ``classHasByte`` answers below 0x80, with ``negated`` left to the
        ## caller in the same way.  Nothing above 0x7F is ever set, so it says
        ## nothing about a range written across the ASCII boundary:
        ## ``[a-\u00FF]`` accepts a stray ``0xFF`` that is not in here.  Filled
        ## in by the compiler when ``asciiSetOk``; the matcher then answers
        ## ASCII input with one bit test instead of walking the atoms.  Every
        ## reader must ask [classBitmapAnswers] first, which is where the
        ## ``b < 0x80`` gate lives.
      negated*: bool
      bracketClass*: bool ## true when from [...] syntax (enables case-fold matching)
      asciiSetOk*: bool
        ## ``asciiSet`` is exact.  Only true for classes whose atoms all read
        ## the same below U+0080 whatever the ASCII-restriction flags say --
        ## which [exactAsciiClassSet] establishes by asking the atoms, so a
        ## ``\p{...}``, a nested class and an intersection are all in reach;
        ## under (?i) the matcher still falls back to the atoms.
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
      lookBounds*: LenBounds
        ## [lengthBounds] of ``lookBody`` (and of each alternative, in
        ## ``lookAltBounds``), so a lookbehind need not rewalk the body's tree
        ## at every position.  Filled in by ``annotateLookaroundBounds``; only
        ## usable while ``lookBoundsFlags`` matches the flags in force, since a
        ## subexpression call can reach the same lookaround under others.
      lookAltBounds*: seq[LenBounds]
      lookBoundsFlags*: RegexFlags
      lookBoundsGm*: GraphemeMode
      lookBoundsValid*: bool
      lookBodyPure*: bool
        ## ``quantBodyPure``'s rule applied to ``lookBody``.  An impure body
        ## has to leave a rollback behind for the captures a positive
        ## lookaround keeps -- see ``keepLookCaptures``.
    of nkAtomicGroup:
      atomicBody*: Node
    of nkConditional:
      condKind*: ConditionalKind
      condBodyPure*: bool
        ## Same rule, covering ``condBody`` alone -- see ``condHolds``.  Kept
        ## next to ``condKind`` so the two small fields share one padding slot;
        ## on its own the node grows past 64 bytes.
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
      bytes*: string
        ## ``runes`` encoded as UTF-8, for the case-sensitive compare. Built
        ## only by ``newStringNode``, which keeps it in step with ``runes``.
      foldedBytes*: string
        ## ``bytes`` under ``asciiFoldByte``, for the ignore-case compare of an
        ## ASCII run. Built alongside ``bytes`` so the compare loop tests a
        ## folded subject byte against a constant.

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

when sizeof(pointer) == 8 and not defined(nimdoc):
  # One AST node, one cache line.  The matcher walks these, so the size is not
  # free -- and it is easy to grow by accident, since a variant is as wide as
  # its widest branch and a field landing between a seq and a set can cost a
  # padding slot rather than its own size.  Pinning it means growing the node
  # has to be a decision someone makes, not a side effect they never see.
  #
  # The number is the 64-bit layout; other word sizes are not pinned rather
  # than pinned wrongly.  If a new field genuinely needs the room, measure the
  # cost and move this line -- do not delete it.
  #
  # ``nimdoc`` is excluded because doc generation never reaches the backend,
  # and Nim 2.0.x's compile-time layout for this variant disagrees with the
  # one it emits (56 vs 64); the check belongs to the build that lays the
  # node out for real.
  static:
    doAssert sizeof(typeof(default(Node)[])) == 64,
      "Node grew to " & $sizeof(typeof(default(Node)[])) & " bytes; see the note here"

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
  ## Membership bits per ASCII code point: below U+0080 the Unicode and
  ## ASCII-only readings of every class agree, so one table answers both.
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
    ## Every byte a character above U+007F can start with.  A byte that
    ## begins no well-formed sequence still stands for a character of its
    ## own (``encLen`` gives it length 1), so none of these may be skipped.
  WordAsciiBytes* = asciiBytes(acWord, true)
  NotWordAsciiBytes* = asciiBytes(acWord, false)
  DigitAsciiBytes* = asciiBytes(acDigit, true)
  NotDigitAsciiBytes* = asciiBytes(acDigit, false)
  SpaceAsciiBytes* = asciiBytes(acSpace, true)
  NotSpaceAsciiBytes* = asciiBytes(acSpace, false)
  ClassLeadBytes* = {0xC2'u8 .. 0xF4'u8}
    ## Lead bytes of a character that can match a *positive* class member.
    ## Such a member is either below U+0080, and then only a one-byte
    ## character reaches it, or above, and then only a multi-byte one does
    ## (``codeIsClassifiable``).  ``0xC0``/``0xC1`` are excluded because the
    ## most they can decode to is U+007F, and ``0xF5`` and up are one-byte
    ## characters above U+007F, which reach neither container.
  XdigitAsciiBytes* = asciiBytes(acXdigit, true)
  NotXdigitAsciiBytes* = asciiBytes(acXdigit, false)

proc buildAsciiCharTypeSets(): array[CharTypeKind, set[uint8]] =
  ## The ASCII bytes each character type matches.  No flag changes the answer
  ## below U+0080: ``isWordChar`` and its neighbours read [AsciiClassTable]
  ## before they look at their ASCII-only argument.
  ##
  ## ``ctDot`` is entered in its single-line reading, the only one that
  ## excludes anything.  ``ctNewlineSeq`` (``"\r\n"`` is two bytes for one
  ## match) and ``ctGraphemeCluster`` keep an empty set; both are handled
  ## before the fast path.
  for ct in CharTypeKind:
    result[ct] =
      case ct
      of ctWord:
        WordAsciiBytes
      of ctNotWord:
        NotWordAsciiBytes
      of ctDigit:
        DigitAsciiBytes
      of ctNotDigit:
        NotDigitAsciiBytes
      of ctSpace:
        SpaceAsciiBytes
      of ctNotSpace:
        NotSpaceAsciiBytes
      of ctDot:
        AllAsciiBytes - {0x0A'u8}
      of ctHexDigit:
        XdigitAsciiBytes
      of ctNotHexDigit:
        NotXdigitAsciiBytes
      of ctAnyChar:
        AllAsciiBytes
      of ctNotNewline:
        AllAsciiBytes - {0x0A'u8}
      of ctNewlineSeq, ctGraphemeCluster:
        {}

const AsciiCharTypeSets* = buildAsciiCharTypeSets()

## Character decoding, following Oniguruma's UTF-8 encoding module.
##
## Oniguruma reads the length of a character straight out of a table indexed
## by the lead byte and never checks that the bytes after it are continuation
## bytes.  A subject is therefore never rejected as malformed; it is simply
## cut into characters at the offsets that table dictates, and the code point
## is the naive OR of the low bits.  Everything downstream — the matcher, the
## scan loops, the first-byte hints — is defined in terms of these two procs
## so the definitions cannot drift apart.

const EncLenTable: array[256, uint8] = block:
  var t: array[256, uint8]
  for b in 0 .. 255:
    t[b] =
      if b < 0xC0:
        1'u8 # ASCII, and every byte that leads nothing
      elif b < 0xE0:
        2'u8
      elif b < 0xF0:
        3'u8
      elif b < 0xF5:
        4'u8
      else:
        1'u8 # 0xF5..0xFF lead nothing
  # 0xF4 still leads four bytes, and the naive OR below carries a continuation
  # byte of 0x90 or more past U+10FFFF; every table lookup is guarded for it.
  t

const MaxCharByteLen* = 4 ## The longest character ``encLen`` yields.

proc encLen*(b: uint8): int {.inline.} =
  ## Bytes the character starting with lead byte ``b`` occupies.  A byte that
  ## begins no well-formed sequence — a stray continuation byte, ``0xF5`` and
  ## up — is a one-byte character of its own.
  int(EncLenTable[b])

proc decodeAt*(
    s: openArray[char], p: int, code: var int32, next: var int
): bool {.inline.} =
  ## Decode the character at ``p``.  Returns false — and leaves ``code`` and
  ## ``next`` untouched — when the length the lead byte declares runs past the
  ## end of ``s``: a truncated sequence is not a character at all, and every
  ## operation that consumes one fails there.
  let n = encLen(s[p].uint8)
  if p + n > s.len:
    return false
  next = p + n
  case n
  of 1:
    code = int32(s[p].uint8)
  of 2:
    code = (int32(s[p].uint8 and 0x1F'u8) shl 6) or int32(s[p + 1].uint8 and 0x3F'u8)
  of 3:
    code =
      (int32(s[p].uint8 and 0x0F'u8) shl 12) or (
        int32(s[p + 1].uint8 and 0x3F'u8) shl 6
      ) or int32(s[p + 2].uint8 and 0x3F'u8)
  else:
    code =
      (int32(s[p].uint8 and 0x07'u8) shl 18) or
      (int32(s[p + 1].uint8 and 0x3F'u8) shl 12) or
      (int32(s[p + 2].uint8 and 0x3F'u8) shl 6) or int32(s[p + 3].uint8 and 0x3F'u8)
  true

proc utf8Encode*(code: int32, buf: var array[4, char]): int {.inline.} =
  ## Encode a pattern code point into ``buf``, returning its length.  Used to
  ## compare a literal against the subject byte for byte, the way Oniguruma
  ## does: a literal carries the bytes it was written with, so an overlong
  ## encoding of the same code point is a different string and does not match.
  if code < 0x80:
    buf[0] = char(code)
    1
  elif code < 0x800:
    buf[0] = char(0xC0 or (code shr 6))
    buf[1] = char(0x80 or (code and 0x3F))
    2
  elif code < 0x10000:
    buf[0] = char(0xE0 or (code shr 12))
    buf[1] = char(0x80 or ((code shr 6) and 0x3F))
    buf[2] = char(0x80 or (code and 0x3F))
    3
  else:
    buf[0] = char(0xF0 or (code shr 18))
    buf[1] = char(0x80 or ((code shr 12) and 0x3F))
    buf[2] = char(0x80 or ((code shr 6) and 0x3F))
    buf[3] = char(0x80 or (code and 0x3F))
    4

proc prevCharStart*(s: openArray[char], pos: int): int {.inline.} =
  ## The start of the character ending just before ``pos``.  ``pos`` must be
  ## in ``1 .. s.len``.
  ##
  ## The place the engine steps back over a character: word boundaries,
  ## lookbehind start candidates and the absent operator all go through it,
  ## so they answer the same question the same way.  It walks back over
  ## continuation bytes and then checks that the character found there
  ## really does end at ``pos``; when it does not, the byte before ``pos``
  ## is covered by nothing and stands for itself.
  ##
  ## This is Oniguruma's ``left_adjust_char_head``, and like it the result
  ## is *not* guaranteed to lie on the forward ``encLen`` chain from offset
  ## 0.  Only the one candidate the continuation-byte walk lands on is
  ## checked, so on malformed input a byte that the forward walk would have
  ## swallowed as part of an earlier character can be validated instead: in
  ## ``"\xC0\xC3\xA9"`` the forward chain runs 0 -> 2 -> 3, yet
  ## ``prevCharStart(s, 3)`` answers 1, because ``1 + encLen(0xC3) == 3``.
  ## Callers get Oniguruma's answer, not the chain predecessor; nothing here
  ## may be relied on to agree with a forward scan over invalid bytes.
  var q = pos - 1
  let lo = max(0, pos - MaxCharByteLen)
  while q > lo and (s[q].uint8 and 0xC0'u8) == 0x80'u8:
    dec q
  if q + encLen(s[q].uint8) == pos:
    q
  else:
    pos - 1

proc prevCharAt*(s: openArray[char], pos: int, start: var int): int32 {.inline.} =
  ## The code point of the character ending just before ``pos``, with its
  ## start offset left in ``start``.  ``pos`` must be in ``1 .. s.len``.
  ##
  ## The read-back companion to `prevCharStart`, and the single place a
  ## backward step turns bytes into a character: word boundaries, the
  ## segmentation algorithms and the absent operator all go through it.  The
  ## decoded character is accepted only when it ends exactly at ``pos``; a
  ## lead byte whose sequence would run past ``pos`` is one of the bytes
  ## `prevCharStart` reports as covered by nothing, and stands for itself.
  start = prevCharStart(s, pos)
  var code: int32
  var next: int
  if decodeAt(s, start, code, next) and next == pos:
    return code
  int32(s[start].uint8)

proc codeIsClassifiable*(code: int32, byteLen: int): bool {.inline.} =
  ## Whether a character reaches the container a class would look it up in.
  ##
  ## A compiled class keeps its members below U+0080 in a byte set and the
  ## rest in a code-point range list, and picks the container by the
  ## character's *encoded length*, not by its value.  A one-byte character is
  ## looked up in the byte set, where nothing above 0x7F is ever recorded; a
  ## longer one is looked up in the range list, which holds nothing below
  ## U+0080.  So a stray ``0x80`` byte and an overlong ``"\xC0\xB1"`` both
  ## land in a container that cannot hold them and match no class member —
  ## before negation, which still applies.
  (byteLen == 1) == (code < 0x80)

proc asciiHas*(c: int32, bits: uint16): bool {.inline.} =
  ## Range-checked table lookup.  The guard lives here rather than at the call
  ## sites so a caller that forgets it cannot read out of bounds under
  ## ``-d:danger``; hot callers already branch on ``c < 128``, so the compiler
  ## folds the duplicate test away.
  c >= 0 and c < 128 and (AsciiClassTable[c] and bits) != 0

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
    literalScan: bool
    requiredByte: RequiredByteInfo
    semiEndAnchored: bool
      ## Every match ends at ``\Z``, so the scan may jump straight to it.
    semiEndDMax: int
      ## Upper bound on the bytes a match consumes, or -1 when unbounded.
      ## Oniguruma's ``anchor_dmax``: how far left of the anchor a match may
      ## still start.
    levelBackrefs: bool
      ## The pattern uses a recursion-level backreference, so the matcher has
      ## to maintain the per-group capture history.
    leadRun: Node
      ## Leading greedy unbounded repeat over a one-way leaf, or nil. A failed
      ## run rules out starts inside it, so the scan jumps to its end.

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
  ## **Internal API.** Returns the compiled AST root, for this repository's
  ## parser/engine tests only — it WILL be removed or restricted. Use the
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

proc literalScan*(r: Regex): bool {.inline.} =
  r.literalScan

proc semiEndAnchored*(r: Regex): bool {.inline.} =
  r.semiEndAnchored

proc semiEndDMax*(r: Regex): int {.inline.} =
  r.semiEndDMax

proc levelBackrefs*(r: Regex): bool {.inline.} =
  ## Whether the pattern uses a recursion-level backreference
  ## (``\k<name+1>``).  Only then does the matcher maintain the per-group
  ## capture history, which costs a write on every capture.
  r.levelBackrefs

proc leadRun*(r: Regex): Node {.inline.} =
  ## Leading repeat whose run a failed attempt may skip, or nil.
  r.leadRun

proc initRegex*(
    pattern: string,
    ast: Node,
    flags: RegexFlags,
    captureCount: int,
    namedCaptures: seq[(string, int)],
    groupBodies: seq[Node],
    groupFlags: seq[RegexFlags],
    firstCharInfo: FirstCharInfo,
    literalScan: bool = false,
    requiredByte: RequiredByteInfo = RequiredByteInfo(valid: false),
    semiEndAnchored: bool = false,
    semiEndDMax: int = -1,
    levelBackrefs: bool = true,
    leadRun: Node = nil,
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
    literalScan: literalScan,
    requiredByte: requiredByte,
    semiEndAnchored: semiEndAnchored,
    semiEndDMax: semiEndDMax,
    levelBackrefs: levelBackrefs,
    leadRun: leadRun,
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

func asciiFoldByte*(b: uint8): uint8 {.inline.} =
  ## ASCII letters folded to lower case, every other byte unchanged.
  if b >= uint8('A') and b <= uint8('Z'):
    b + 32
  else:
    b

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

const MultiCharFolds*:
  array[21, tuple[source: int32, expansion: array[3, int32], len: int]] = [
  ## Every character whose case fold is more than one character, and what it
  ## folds to.  Single source of truth: the fold lookups and the length
  ## analysis below are all derived from it, so none of them can drift.
  (0x00DF'i32, [0x0073'i32, 0x0073'i32, 0'i32], 2), # ß → ss
  (0x0130'i32, [0x0069'i32, 0x0307'i32, 0'i32], 2), # İ → i + combining dot above
  (0x0149'i32, [0x02BC'i32, 0x006E'i32, 0'i32], 2), # ŉ → ʼn
  (0x01F0'i32, [0x006A'i32, 0x030C'i32, 0'i32], 2), # ǰ → j + combining caron
  (0x0390'i32, [0x03B9'i32, 0x0308'i32, 0x0301'i32], 3), # ΐ → ι + ̈ + ́
  (0x03B0'i32, [0x03C5'i32, 0x0308'i32, 0x0301'i32], 3), # ΰ → υ + ̈ + ́
  (0x0587'i32, [0x0565'i32, 0x0582'i32, 0'i32], 2), # և → եւ
  (0x1E96'i32, [0x0068'i32, 0x0331'i32, 0'i32], 2), # ẖ → h + macron below
  (0x1E97'i32, [0x0074'i32, 0x0308'i32, 0'i32], 2), # ẗ → t + diaeresis
  (0x1E98'i32, [0x0077'i32, 0x030A'i32, 0'i32], 2), # ẘ → w + ring above
  (0x1E99'i32, [0x0079'i32, 0x030A'i32, 0'i32], 2), # ẙ → y + ring above
  (0x1E9A'i32, [0x0061'i32, 0x02BE'i32, 0'i32], 2), # ẚ → a + right half ring
  (0x1E9E'i32, [0x0073'i32, 0x0073'i32, 0'i32], 2), # ẞ → ss
  (0x1F50'i32, [0x03C5'i32, 0x0313'i32, 0'i32], 2), # ὐ → υ + comma above
  (0xFB00'i32, [0x0066'i32, 0x0066'i32, 0'i32], 2), # ﬀ → ff
  (0xFB01'i32, [0x0066'i32, 0x0069'i32, 0'i32], 2), # ﬁ → fi
  (0xFB02'i32, [0x0066'i32, 0x006C'i32, 0'i32], 2), # ﬂ → fl
  (0xFB03'i32, [0x0066'i32, 0x0066'i32, 0x0069'i32], 3), # ﬃ → ffi
  (0xFB04'i32, [0x0066'i32, 0x0066'i32, 0x006C'i32], 3), # ﬄ → ffl
  (0xFB05'i32, [0x0073'i32, 0x0074'i32, 0'i32], 2), # ﬅ → st
  (0xFB06'i32, [0x0073'i32, 0x0074'i32, 0'i32], 2), # ﬆ → st
]

const MultiCharFoldStarts* = block:
  ## The code points a fold expansion can begin with.  Hot-path lookups reject
  ## through this first: one set test instead of a walk of the table.
  var cps: set[uint16]
  for f in MultiCharFolds:
    cps.incl(uint16(f.expansion[0]))
  cps

const MultiCharFoldSources* = block:
  ## The characters that have a multi-character fold at all.  Same purpose as
  ## [MultiCharFoldStarts], for the forward direction.
  var cps: set[uint16]
  for f in MultiCharFolds:
    cps.incl(uint16(f.source))
  cps

proc hasMultiCharFold*(r: Rune): bool {.inline.} =
  ## Whether ``r`` folds to more than one character.
  let cp = int32(r)
  cp >= 0 and cp <= 0xFFFF and uint16(cp) in MultiCharFoldSources

proc canStartFoldExpansion*(r: Rune): bool {.inline.} =
  ## Whether a multi-character fold expansion can begin with ``r``.
  let cp = int32(r)
  cp >= 0 and cp <= 0xFFFF and uint16(cp) in MultiCharFoldStarts

func asciiLowerCp(cp: int32): int32 {.inline.} =
  if cp >= ord('A') and cp <= ord('Z'):
    cp + 32
  else:
    cp

proc isMultiCharFoldPairStart*(r1, r2: Rune): bool =
  ## Whether ``r1`` and ``r2``, in that order, start some multi-character fold
  ## expansion — so one subject character can match them both (``ss`` ← ß).
  let c1 = asciiLowerCp(int32(r1))
  let c2 = asciiLowerCp(int32(r2))
  # Reject the common character with one set test instead of a table walk.
  if not canStartFoldExpansion(Rune(c1)):
    return false
  for f in MultiCharFolds:
    if f.expansion[0] == c1 and f.expansion[1] == c2:
      return true
  false

const WidestUsefulHint = 200
  ## Above this many bytes a hint skips too little to pay for the test it
  ## costs at every position, so the scan is better off with no prefilter.

proc byteSetInfo(bs: set[uint8]): FirstCharInfo =
  if bs.card == 0:
    FirstCharInfo(kind: fcNone)
  elif bs.card > WidestUsefulHint:
    FirstCharInfo(kind: fcNone)
  elif bs.card == 1:
    var b: uint8
    for v in bs:
      b = v
    FirstCharInfo(kind: fcByte, byte: b)
  else:
    FirstCharInfo(kind: fcByteSet, bytes: bs)

proc firstCharFromRune(cp: int32, flags: RegexFlags): FirstCharInfo =
  ## Build a FirstCharInfo from a code point, handling both ASCII and non-ASCII.
  if cp < 128:
    let b = uint8(cp)
    if rfIgnoreCase in flags:
      if hasNonAsciiFoldEquiv(cp):
        return FirstCharInfo(kind: fcNone)
      byteSetInfo(asciiFoldBytes(b))
    else:
      byteSetInfo({b})
  elif rfIgnoreCase in flags:
    # Case-insensitive non-ASCII: skip optimization (fold targets may differ)
    FirstCharInfo(kind: fcNone)
  else:
    # Non-ASCII case-sensitive: use the UTF-8 lead byte for fast skip
    byteSetInfo({utf8LeadByte(cp)})

proc charTypeBytes(ct: CharTypeKind): set[uint8] =
  ## Bytes a character type can start with, or ``{}`` when it can start
  ## with anything.  Always the widest (Unicode) reading: the ASCII-only
  ## flags can be switched on at match time and only ever shrink the set, so
  ## a superset stays sound.
  case ct
  of ctWord:
    # ``\w`` and ``\W`` test the decoded code point directly instead of
    # going through a class's containers, so a one-byte character above
    # U+007F reaches them: U+00FE is a letter, and the byte 0xFE is it.
    WordAsciiBytes + NonAsciiBytes
  of ctNotWord:
    NotWordAsciiBytes + NonAsciiBytes
  of ctDigit:
    DigitAsciiBytes + ClassLeadBytes
  of ctNotDigit:
    NotDigitAsciiBytes + NonAsciiBytes
  of ctSpace:
    SpaceAsciiBytes + ClassLeadBytes
  of ctNotSpace:
    NotSpaceAsciiBytes + NonAsciiBytes
  of ctHexDigit:
    # Every hex digit is below U+0080, and only a one-byte character is
    # looked up against those, so no lead byte can start one.
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
  MultiCharFoldLeadBytes = block:
    ## First letters of the multi-character case-fold expansions (ß → "ss",
    ## ﬁ → "fi", ẘ → "w"+ring, …), derived from [MultiCharFolds].  Under (?i) a
    ## bracket class holding the source rune matches the expansion, so the
    ## subject can start with any of these.
    var bs: set[uint8]
    for f in MultiCharFolds:
      let cp = f.expansion[0]
      if cp < 0x80:
        bs.incl(uint8(cp))
        if cp >= ord('a') and cp <= ord('z'):
          bs.incl(uint8(cp - 32))
    bs

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
      # A range written across the ASCII boundary fills the byte container up
      # to 0xFF, not to 0x7F, so ``[a-ÿ]`` accepts a stray ``0xFF`` byte.
      let top =
        if lo < 128:
          min(hi, 255)
        else:
          min(hi, 127)
      for c in max(lo, 0) .. top:
        ascii.incl(uint8(c))
    of ccCharType:
      predicate = true
      case atom.charType
      of ctDot, ctAnyChar, ctGraphemeCluster:
        # These accept anything, so no byte set describes them.  Returning
        # false is the only safe answer: ``ascii`` is an *under*-approximation
        # that the negated branch complements, and widening it here would make
        # ``[^.]`` claim it cannot start with an ASCII byte.
        return false
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
    # Every byte above 0x7F stays in: a one-byte character above U+007F
    # reaches no container, so it misses every member and the negation lets
    # it through.
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
    # ſ and K are the only characters above U+007F that fold onto an ASCII
    # member, and both are multi-byte.
    return byteSetInfo(ascii + ClassLeadBytes)
  if nonAscii:
    ascii = ascii + ClassLeadBytes
  # Every member is ASCII, and only a one-byte character is looked up against
  # them (``codeIsClassifiable``), so the ASCII set is the whole hint.
  byteSetInfo(ascii)

type FirstCharCache* = TableRef[(uint, RegexFlags), FirstCharInfo]
  ## Memo for ``extractFirstChar``, keyed by node identity and the flags it
  ## was asked under.  The analysis is a pure function of those two, and one
  ## caller -- the compiler annotating every alternative of every alternation
  ## -- asks about overlapping subtrees: without the memo a chain of nested
  ## alternations re-walks everything below it once per level.

proc extractFirstCharUncached(
  node: Node, flags: RegexFlags, cache: FirstCharCache
): FirstCharInfo

proc extractFirstChar*(
    node: Node, flags: RegexFlags, cache: FirstCharCache = nil
): FirstCharInfo =
  ## Extract optimization hint about the first character/anchor of a pattern.
  ## ``cache``, when given, is consulted and filled as the walk descends.
  if node == nil:
    return FirstCharInfo(kind: fcNone)
  if cache.isNil:
    return extractFirstCharUncached(node, flags, nil)
  # ``hasKey`` then ``[]`` rather than ``getOrDefault``: the latter compares
  # the hit against the default, and ``FirstCharInfo`` is a case object, for
  # which Nim generates no ``==``.
  let key = (cast[uint](node), flags)
  if cache.hasKey(key):
    return cache[key]
  result = extractFirstCharUncached(node, flags, cache)
  cache[key] = result

proc extractFirstCharUncached(
    node: Node, flags: RegexFlags, cache: FirstCharCache
): FirstCharInfo =
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
      let info = extractFirstChar(child, currentFlags, cache)
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
    extractFirstChar(node.captureBody, flags, cache)
  of nkNamedCapture:
    extractFirstChar(node.namedCaptureBody, flags, cache)
  of nkGroup:
    extractFirstChar(node.groupBody, flags, cache)
  of nkFlagGroup:
    if node.flagBody != nil:
      extractFirstChar(node.flagBody, flags + node.flagsOn - node.flagsOff, cache)
    else:
      FirstCharInfo(kind: fcNone)
  of nkQuantifier:
    if node.quantMin >= 1 and (node.quantMax < 0 or node.quantMax >= node.quantMin):
      extractFirstChar(node.quantBody, flags, cache)
    else:
      FirstCharInfo(kind: fcNone)
  of nkAlternation:
    if node.alternatives.len == 0:
      return FirstCharInfo(kind: fcNone)
    var merged = extractFirstChar(node.alternatives[0], flags, cache)
    if merged.kind == fcNone:
      return merged
    for i in 1 ..< node.alternatives.len:
      merged =
        mergeFirstChar(merged, extractFirstChar(node.alternatives[i], flags, cache))
      if merged.kind == fcNone:
        return merged
    merged
  of nkAtomicGroup:
    extractFirstChar(node.atomicBody, flags, cache)
  of nkCharType:
    byteSetInfo(charTypeBytes(node.charType))
  of nkCharClass:
    classFirstChar(node, flags)
  else:
    FirstCharInfo(kind: fcNone)

proc hasLiteralPrefix*(node: Node, flags: RegexFlags): bool =
  ## Whether the pattern begins with a case-sensitive literal.
  ##
  ## Oniguruma searches for such a prefix as raw bytes, which means the scan
  ## can start in the middle of a character: ``/1/`` finds the ``0x31`` at
  ## offset 1 of ``"\xC0\x31"``, where ``/[1]/`` — which gets no such
  ## optimization and walks characters — finds nothing.  A literal is
  ## compared byte for byte anyway (``matchBytes``), so a match found this way
  ## is a real one; it is only the set of positions that widens.
  if node == nil:
    return false
  case node.kind
  of nkLiteral, nkEscapedLiteral, nkString:
    rfIgnoreCase notin flags
  of nkCapture:
    hasLiteralPrefix(node.captureBody, flags)
  of nkNamedCapture:
    hasLiteralPrefix(node.namedCaptureBody, flags)
  of nkGroup:
    hasLiteralPrefix(node.groupBody, flags)
  of nkFlagGroup:
    if node.flagBody != nil:
      hasLiteralPrefix(node.flagBody, flags + node.flagsOn - node.flagsOff)
    else:
      false
  of nkQuantifier:
    # An optional prefix leaves the literal no longer first, and Oniguruma
    # does not reach past it either.
    node.quantMin >= 1 and hasLiteralPrefix(node.quantBody, flags)
  of nkConcat:
    var currentFlags = flags
    for child in node.children:
      if child.kind == nkFlagGroup and child.flagBody == nil:
        currentFlags = currentFlags + child.flagsOn - child.flagsOff
        continue
      if child.kind in
          {nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp}:
        continue
      return hasLiteralPrefix(child, currentFlags)
    false
  of nkAlternation:
    # Only when every branch is the same literal, which is what lets
    # Oniguruma reduce the alternation to one exact string.
    if node.alternatives.len == 0:
      return false
    for alt in node.alternatives:
      if not hasLiteralPrefix(alt, flags):
        return false
    let first = extractFirstChar(node.alternatives[0], flags)
    if first.kind != fcByte:
      return false
    for i in 1 ..< node.alternatives.len:
      let info = extractFirstChar(node.alternatives[i], flags)
      if info.kind != fcByte or info.byte != first.byte:
        return false
    true
  else:
    false

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

const MaxRuneBytes* = 4 ## Widest UTF-8 encoding of a single character.

const MaxFoldExpansionRunes = 3
  ## Longest multi-character case fold: ΐ, ΰ, ﬃ and ﬄ each fold to three
  ## characters, and nothing folds to more.

const MaxAsciiFoldEquivBytes = 3
  ## Widest character whose fold reaches an ASCII one, on its own (U+212A →
  ## ``k``) or through an expansion (ẞ, ﬀ…ﬆ, ẖ, ẗ, ẘ, ẙ, ẚ — all three bytes).

proc runeMaxByteLen*(r: Rune, flags: RegexFlags): int =
  ## Upper bound on the subject bytes one pattern character can consume.
  ##
  ## Under ``(?i)`` that is not the character's own width: it also matches a
  ## fold equivalent with a wider encoding (``k`` ↔ U+212A), and a character
  ## with a multi-character fold matches that whole expansion (``ΐ`` ↔
  ## ``ι``+``◌̈``+``◌́``, six bytes), whose elements fold again in turn.
  if rfIgnoreCase notin flags:
    return r.size
  let cp = int32(r)
  if cp < 128:
    # No ASCII character has a multi-character fold, and only ``s`` and ``k``
    # have a non-ASCII fold equivalent.  Standing inside another character's
    # expansion needs a neighbour, which is invisible here: [lengthBounds]
    # adds that allowance where it can see the pair.
    return if hasNonAsciiFoldEquiv(cp): MaxAsciiFoldEquivBytes else: 1
  max(r.size, MaxFoldExpansionRunes * MaxRuneBytes)

proc runeFixedByteLen*(r: Rune, flags: RegexFlags): int =
  ## The exact number of subject bytes one pattern character consumes, or -1
  ## when case folding lets it match text of another width — a fold
  ## equivalent with a wider encoding, or a multi-character fold expansion.
  ## See [runeMaxByteLen] for the bound that replaces it in that case.
  if rfIgnoreCase notin flags:
    return r.size
  let cp = int32(r)
  if cp < 128 and not hasNonAsciiFoldEquiv(cp):
    return 1
  -1

proc runeBounds(r: Rune, flags: RegexFlags): LenBounds {.inline.} =
  LenBounds(maxLen: runeMaxByteLen(r, flags), fixedLen: runeFixedByteLen(r, flags))

proc lengthBounds*(node: Node, flags: RegexFlags, gm = gmNone): LenBounds =
  ## Bound what ``node`` consumes.  See [LenBounds].
  ##
  ## ``flags`` and ``gm`` are the ones in force where ``node`` sits: case
  ## folding and grapheme mode both change how much subject a node eats, and
  ## a flag group anywhere above or beside it can have turned them on.
  ##
  ## Under ``(?i)`` one subject character can stand for two pattern characters
  ## (``ﬀ`` for ``ff``).  The matcher only folds like that inside an
  ## ``nkString``, so that is the only case handled below; ``mergeLiterals``
  ## runs last in the compiler and leaves no two literals adjacent in a
  ## concat, so summing concat children needs no allowance for a fold across
  ## them.
  if node == nil:
    return LenBounds(maxLen: 0, fixedLen: 0)
  case node.kind
  of nkLiteral:
    runeBounds(node.rune, flags)
  of nkEscapedLiteral:
    runeBounds(node.escapedRune, flags)
  of nkString:
    var total = 0
    var fixed = 0
    for i, r in node.runes:
      total += runeMaxByteLen(r, flags)
      if fixed >= 0:
        let rl = runeFixedByteLen(r, flags)
        if rl < 0:
          fixed = -1
        else:
          fixed += rl
      # One subject character can also match this pair (subject "ß" against
      # pattern "ss"), so the length is not fixed.  It is at most
      # ``MaxAsciiFoldEquivBytes`` wide and replaces two pattern characters of
      # at least one byte each, hence at most one extra byte per pair.
      if rfIgnoreCase in flags and i + 1 < node.runes.len and
          isMultiCharFoldPairStart(r, node.runes[i + 1]):
        fixed = -1
        total += MaxAsciiFoldEquivBytes - 2
    LenBounds(maxLen: total, fixedLen: fixed)
  of nkConcat:
    var total = 0
    var fixed = 0
    var currentFlags = flags
    var currentGm = gm
    for child in node.children:
      # A bare flag group — (?i), (?y{g}) — applies to the rest of the concat
      # rather than to a body of its own.
      if child.kind == nkFlagGroup and child.flagBody == nil:
        currentFlags = currentFlags + child.flagsOn - child.flagsOff
        if child.graphemeMode != gmNone:
          currentGm = child.graphemeMode
        continue
      let cb = lengthBounds(child, currentFlags, currentGm)
      if fixed >= 0:
        if cb.fixedLen < 0 or cb.fixedLen > int.high - fixed:
          fixed = -1
        else:
          fixed += cb.fixedLen
      if total >= 0:
        if cb.maxLen < 0 or cb.maxLen > int.high - total:
          total = -1
        else:
          total += cb.maxLen
      if total < 0 and fixed < 0:
        break
    LenBounds(maxLen: total, fixedLen: fixed)
  of nkAlternation:
    if node.alternatives.len == 0:
      return LenBounds(maxLen: 0, fixedLen: 0)
    # ``maxLen`` maximizes over the branches while ``fixedLen`` needs them all
    # to agree, so ``fixed`` is seeded from the first branch during the same
    # walk: a second walk would be exponential in the alternation depth.
    var best = 0
    var fixed = 0
    for i, alt in node.alternatives:
      let ab = lengthBounds(alt, flags, gm)
      if ab.maxLen < 0:
        best = -1
      elif best >= 0:
        best = max(best, ab.maxLen)
      if i == 0:
        fixed = ab.fixedLen
      elif ab.fixedLen != fixed:
        fixed = -1
    LenBounds(maxLen: best, fixedLen: fixed)
  of nkQuantifier:
    let bb = lengthBounds(node.quantBody, flags, gm)
    var total = -1
    if node.quantMax >= 0 and bb.maxLen >= 0:
      if node.quantMax == 0 or bb.maxLen <= int.high div node.quantMax:
        total = bb.maxLen * node.quantMax
    var fixed = -1
    if node.quantMin == node.quantMax and node.quantMin >= 0 and bb.fixedLen >= 0:
      if node.quantMin == 0 or bb.fixedLen <= int.high div node.quantMin:
        fixed = bb.fixedLen * node.quantMin
    LenBounds(maxLen: total, fixedLen: fixed)
  of nkCapture:
    lengthBounds(node.captureBody, flags, gm)
  of nkNamedCapture:
    lengthBounds(node.namedCaptureBody, flags, gm)
  of nkGroup:
    lengthBounds(node.groupBody, flags, gm)
  of nkFlagGroup:
    if node.flagBody != nil:
      lengthBounds(
        node.flagBody,
        flags + node.flagsOn - node.flagsOff,
        if node.graphemeMode != gmNone: node.graphemeMode else: gm,
      )
    else:
      LenBounds(maxLen: 0, fixedLen: 0)
  of nkAtomicGroup:
    lengthBounds(node.atomicBody, flags, gm)
  of nkAnchor, nkLookaround, nkCalloutMax, nkCalloutCount, nkCalloutCmp:
    LenBounds(maxLen: 0, fixedLen: 0)
  of nkCharType:
    # A grapheme cluster — \X, or ``.`` in grapheme/word mode — runs over as
    # many characters as the cluster holds, so it has no bound at all.
    let unbounded =
      node.charType == ctGraphemeCluster or
      (node.charType == ctDot and gm in {gmGrapheme, gmWord})
    LenBounds(maxLen: if unbounded: -1 else: MaxRuneBytes, fixedLen: -1)
  of nkCharClass:
    # Under (?i) a class also matches the multi-character fold of a member.
    LenBounds(
      maxLen:
        if rfIgnoreCase in flags:
          MaxFoldExpansionRunes * MaxRuneBytes
        else:
          MaxRuneBytes,
      fixedLen: -1,
    )
  of nkBackreference, nkNamedBackref, nkSubexpCall:
    LenBounds(maxLen: -1, fixedLen: -1) # can't bound
  of nkConditional:
    let yes = lengthBounds(node.condYes, flags, gm)
    let no =
      if node.condNo != nil:
        lengthBounds(node.condNo, flags, gm)
      else:
        LenBounds(maxLen: 0, fixedLen: 0)
    LenBounds(
      maxLen:
        if yes.maxLen < 0 or no.maxLen < 0:
          -1
        else:
          max(yes.maxLen, no.maxLen),
      fixedLen: -1,
    )
  of nkAbsent:
    LenBounds(maxLen: -1, fixedLen: -1)

proc annotateLookaroundBounds*(node: Node, flags: RegexFlags, gm = gmNone) =
  ## Record [lengthBounds] of every lookaround body on the lookaround node.
  ##
  ## A lookbehind asks for its body's length once per position it is tried at,
  ## which puts a whole recursive walk in the matcher's inner loop.  Computing
  ## it here turns that into a flag check (see ``boundsUsable``).
  ##
  ## Must run on the final AST: a later rewrite would leave the annotation
  ## describing a tree that no longer exists.  Nodes default to
  ## ``lookBoundsValid == false`` and fall back to the walk.
  if node == nil:
    return
  case node.kind
  of nkLookaround:
    node.lookBounds = lengthBounds(node.lookBody, flags, gm)
    node.lookAltBounds = @[]
    if node.lookBody != nil and node.lookBody.kind == nkAlternation:
      for alt in node.lookBody.alternatives:
        node.lookAltBounds.add(lengthBounds(alt, flags, gm))
    node.lookBoundsFlags = flags
    node.lookBoundsGm = gm
    node.lookBoundsValid = true
    annotateLookaroundBounds(node.lookBody, flags, gm)
  of nkConcat:
    var currentFlags = flags
    var currentGm = gm
    for child in node.children:
      # A bare flag group applies to the rest of the concat, as in
      # [lengthBounds].
      if child.kind == nkFlagGroup and child.flagBody == nil:
        currentFlags = currentFlags + child.flagsOn - child.flagsOff
        if child.graphemeMode != gmNone:
          currentGm = child.graphemeMode
        continue
      annotateLookaroundBounds(child, currentFlags, currentGm)
  of nkFlagGroup:
    if node.flagBody != nil:
      annotateLookaroundBounds(
        node.flagBody,
        flags + node.flagsOn - node.flagsOff,
        if node.graphemeMode != gmNone: node.graphemeMode else: gm,
      )
  else:
    for child in node.childNodes:
      annotateLookaroundBounds(child, flags, gm)

proc maxByteLen*(node: Node, flags: RegexFlags, gm = gmNone): int {.inline.} =
  ## Upper bound on the bytes ``node`` consumes, or -1 when unbounded.
  ## See [lengthBounds].
  lengthBounds(node, flags, gm).maxLen

proc fixedByteLen*(node: Node, flags: RegexFlags, gm = gmNone): int {.inline.} =
  ## The one length every match of ``node`` consumes, or -1 when it varies.
  ## See [lengthBounds].
  lengthBounds(node, flags, gm).fixedLen

proc semiEndAnchored*(node: Node): bool =
  ## Whether every match of ``node`` has to end at ``\Z`` — the end of the
  ## subject, or just before a newline that ends it.
  ##
  ## This is Oniguruma's ``ANCHOR_SEMI_END_BUF``, and the scan uses it the way
  ## ``onig_search`` does: it jumps the first start position to the anchor
  ## instead of walking there.  The analysis is deliberately conservative —
  ## it looks only at the last element of every path — because a false
  ## positive would skip start positions that can still match.  ``$`` is not
  ## included: Oniguruma gives it ``ANCHOR_END_LINE``, which gets no jump.
  if node == nil:
    return false
  case node.kind
  of nkAnchor:
    node.anchor == akStringEndOrNewline
  of nkConcat:
    node.children.len > 0 and semiEndAnchored(node.children[^1])
  of nkAlternation:
    if node.alternatives.len == 0:
      return false
    for alt in node.alternatives:
      if not semiEndAnchored(alt):
        return false
    true
  of nkCapture:
    semiEndAnchored(node.captureBody)
  of nkNamedCapture:
    semiEndAnchored(node.namedCaptureBody)
  of nkGroup:
    semiEndAnchored(node.groupBody)
  of nkFlagGroup:
    semiEndAnchored(node.flagBody)
  of nkAtomicGroup:
    semiEndAnchored(node.atomicBody)
  else:
    false
