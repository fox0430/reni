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
    rfCaptureGroup ## Keep numbered captures alongside named ones (compile option).

  RegexFlags* = set[RegexFlag]

  MatchOption* = enum
    moNotBeginString ## Disable ``\A`` for this call (ONIG_OPTION_NOT_BEGIN_STRING).
    moNotBeginPosition ## Disable ``\G`` for this call (ONIG_OPTION_NOT_BEGIN_POSITION).

  MatchOptions* = set[MatchOption]
    ## Per-call options; independent of the immutable compiled pattern.

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
    abClear ## (?~|) - range clear: matches empty, widens the range back out
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
    upNever ## unknown name, which the parsers reject: matches nothing
    upAlways ## \p{Any}
    upCategory ## ``unicodeCategory(r)`` intersects ``catBits``
    upTypeMask ## ``unicodeTypes(r)`` shares *any* bit with ``typeBits``
    upPosix ## ``matchPosixClass(r, posixCls, false)``
    upWord ## bare ``\w`` / ``\p{Word}``: ``isWordChar(r, false)``
    upAscii ## code point <= U+007F
    upRanges
      ## code point inside ``PropertyRanges[rangeFirst ..< rangeLast]`` of
      ## ``unicode_props_data``: a block or a binary property
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
    rangeFirst*, rangeLast*: int32
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
    fixedLen*: int
      ## The single length every match consumes; -1 when it varies.  Also -1
      ## for ``(?~)`` and the other empty absent functions, which consume
      ## nothing: Oniguruma counts them as variable-length, and a look-behind
      ## body holding one runs under a window for that.  See ``nkAbsent`` in
      ## [lengthBounds].

  NodeKind* = enum
    ## **Internal API.** Exposed only so this repository's tests can inspect
    ## parsed trees; node kinds may change at any time without notice.
    nkLiteral ## single rune, written plain or escaped as itself: a, \.
    nkEscapedLiteral ## a rune written as a code: \n, \t, \x{HHHH}, etc.
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
    ckAlwaysFalse ## (?(*FAIL)...)
    ckAlwaysTrue ## (?()...) empty condition, (?({...})...) code condition
    ckRegexCond
      ## (?(regex)...) - bare name that's not a capture group, a look-around,
      ## or a callout other than (*FAIL)

  NameRefs* = distinct int32
    ## **Internal API.** Offset into ``Regex``'s name-reference table of the
    ## capture groups one ``\k<name>``, ``\g<name>`` or ``(?(<name>)...)``
    ## resolves to, in declaration order.  A run and not an index, because a
    ## name may be declared twice.
    ##
    ## The slot at the offset holds the run's length and the indices follow,
    ## so a reference costs one ``int32`` on the node -- ``nkConditional`` has
    ## no room for two.  Read it with [nameRefsOf]; ``NoNameRefs`` is the
    ## reserved empty run.  Filled in by [resolveNameRefs].
    ##
    ## ``distinct``, and so is [NodeId]: the two index different tables at the
    ## same width, so a plain alias would let one be read as the other.

  NodeId* = distinct int32
    ## **Internal API.** Index of a node in ``Regex``'s node table, as handed
    ## out by [numberNodes].  What the matcher's frame and backtrack stacks
    ## hold instead of a ``Node``: a plain integer needs no cursor, no write
    ## barrier and no destructor, whatever the memory management.
    ## ``NoNodeId`` is the table's reserved slot, so a default-initialised
    ## field reads back as "no node".
    ##
    ## ``distinct`` for the reason [NameRefs] gives.

  SeqRunElem* = object
    ## **Internal API.** One element of a sequence-of-leaf-runs body; see
    ## ``Node.quantSeqOk`` and [seqRunShape].  ``elem`` is as written (the
    ## quantifier, or the leaf itself); ``leaf`` is the leaf under it.
    elem*: NodeId
    leaf*: NodeId
    emin*: int32
    emax*: int32 ## -1 = unbounded
    eposs*: bool ## possessive: take the run, never give a byte back

  Node* {.acyclic.} = ref object
    ## **Internal API.** Fields are exported only so `compiler` and `engine`
    ## can walk the tree. The shape may change without notice, and mutating
    ## a Node on a compiled `Regex` corrupts the matcher state.
    ##
    ## ``{.acyclic.}``: trees are built strictly top-down and never spliced
    ## into themselves; ``nkSubexpCall`` resolves by index/name at match time.
    id*: NodeId
      ## This node's slot in the ``Regex``'s node table, or ``NoNodeId`` until
      ## [numberNodes] runs.  Lives before the discriminant, in padding the
      ## variant spends anyway; the size check under the type holds it there.
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
      altTrie*: AltTrie
        ## Set when every branch is a plain literal and the pattern never
        ## switches ``rfIgnoreCase`` on partway through: the matcher then
        ## walks the trie instead of trying the branches, and ``altFirst``
        ## goes unread. ``nil`` is the ordinary hinted path.
    of nkCapture:
      captureIndex*: int
      captureBody*: Node
      captureBodyKeepsFlags*: bool
        ## ``groupBodyKeepsFlags`` for a capturing group: the matcher skips
        ## only the ``chUndoFlags`` push, since the frame carries the span.
      capturePos*: int32 ## See ``lookPos``.
    of nkNamedCapture:
      captureName*: string
      namedCaptureIndex*: int
      namedCaptureBody*: Node
      namedCaptureBodyKeepsFlags*: bool
        ## ``captureBodyKeepsFlags`` for the named spelling.
      namedCapturePos*: int32 ## See ``lookPos``.
    of nkGroup:
      groupBody*: Node
      groupBodyKeepsFlags*: bool
        ## Raised by ``markGroupBodyKeepsFlags``: nothing in ``groupBody`` can
        ## write ``ctx.flags``, so the matcher steps straight into it instead
        ## of saving them, pushing a ``ckGroup`` frame and restoring them on
        ## the way out.  The default ``false`` is the safe value.
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
      quantSeqOk*: bool
        ## Raised by ``buildSeqRuns``: the body is a sequence of leaf runs
        ## that an ASCII byte set decides, so the matcher scans the whole
        ## repeat as one choice.  Derived under ``Regex.flags``; a reader
        ## checks those flags have not moved, as for a [LeafGate].
      quantFollowByte*: int16 = -1
        ## Set by ``annotateContinuations``: the ASCII byte the continuation
        ## must have where a give-back hands it the position, or -1 where it
        ## can begin with more than one character.  A greedy repeat over a one-way
        ## leaf then retreats straight to the positions holding that byte --
        ## see ``retreatToFollowByte``.
        ##
        ## -1 is both the safe value and the declared default, so a node no
        ## pass visits keeps every give-back.  Build an ``nkQuantifier`` with
        ## an object constructor, which honours that default; ``new(Node)``
        ## would zero it into a node claiming byte 0.
      quantNextLeaf*: Node
        ## Lazy repeats only: leaf the continuation must match where the repeat
        ## stops, or nil. Set by ``annotateContinuations``; borrowed, not a
        ## child, so ``childNodes`` skips it.
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
      solePropOk*: bool
        ## ``atoms`` is one ``\p{...}`` or ``\P{...}`` written outside ``[...]``:
        ## nothing to walk, nothing to fold, so the matcher asks
        ## [matchUnicodeProp] directly.  Filled in by the compiler; the default
        ## ``false`` is the general path.
      asciiSetOk*: bool
        ## ``asciiSet`` is exact.  Only true for classes whose atoms all read
        ## the same below U+0080 whatever the ASCII-restriction flags say --
        ## which [exactAsciiClassSet] establishes by asking the atoms, so a
        ## ``\p{...}``, a nested class and an intersection are all in reach;
        ## under (?i) the matcher still falls back to the atoms.
    of nkAnchor:
      anchor*: AnchorKind
      anchorPos*: int32 ## See ``lookPos``.
    of nkCharType:
      charType*: CharTypeKind
    of nkBackreference:
      backrefIndex*: int
      backrefLevel*: int ## recursion-level offset for \k<n+level> (0 = normal)
      backrefLeveled*: bool
        ## Written with a level, ``+0`` too: inside its open group it reads the
        ## span the group last closed (``BACKREF_WITH_LEVEL``), where a plain
        ## reference reads unset (``Regex.opensUnset``).  Oniguruma takes the
        ## span closed at the reference's own call depth, reni the last at any
        ## depth: ``(?<n>a|b\g<n>\k<n+0>)`` on "bbaa" matches 2..3 there and
        ## 1..4 here.
    of nkNamedBackref:
      backrefName*: string
      namedBackrefLevel*: int ## recursion-level offset for \k<name+level> (0 = normal)
      namedBackrefLeveled*: bool ## As ``backrefLeveled``.
      backrefRefs*: NameRefs ## groups ``backrefName`` resolves to
      backrefScope*: int32
        ## How many named groups the parser had opened when it read the
        ## reference; see [namedGroupsRead].
    of nkLookaround:
      lookKind*: LookaroundKind
      lookPos*: int32
        ## The byte offset in the pattern where this look-around starts, which
        ## the error ``validateLookbehinds`` raises gives as its position.
        ## ``anchorPos``, ``capturePos``, ``namedCapturePos``, ``callPos`` and
        ## ``absentPos`` hold the same on the other kinds that check rejects,
        ## and [patternPos] reads and writes whichever one a node has.
        ## ``parseAtom`` sets it (``parseConditional`` for a look-around
        ## condition).  ``demoteUnnamedCaptures``, the one pass before the check
        ## that builds these nodes anew, copies them; nothing reads them after
        ## it.  0 means not recorded, and the error then gives no position: a
        ## node the check rejects is inside a look-behind, so it never starts
        ## at 0.  An offset that does not fit is not recorded either.
      lookBody*: Node
      lookBounds*: LenBounds
        ## [lengthBounds] of ``lookBody`` (and of each alternative, in
        ## ``lookAlts``), so a lookbehind need not rewalk the body's tree
        ## at every position.  Filled in by ``annotateLookaroundBounds``; only
        ## usable while ``lookBoundsFlags`` matches the flags in force, since a
        ## subexpression call can reach the same lookaround under others.
      lookAlts*: seq[LenBounds]
        ## [lengthBounds] of each alternative when ``lookBody`` is an
        ## alternation, empty otherwise. Cached because ``altWindow`` runs per
        ## attempt.
      lookBoundsFlags*: RegexFlags
      lookBoundsGm*: GraphemeMode
      lookBoundsValid*: bool
      lookBodyPure*: bool
        ## ``quantBodyPure``'s rule applied to ``lookBody``.  An impure body
        ## has to leave a rollback behind for the captures a positive
        ## lookaround keeps -- see ``keepLookCaptures``.
      lookDivided*: bool
        ## Positive look-behind only, set by ``tuneLookBehinds``: Oniguruma
        ## reads its body's alternation as one look-behind per branch, so a
        ## matched branch is retried once the continuation fails.  Any other
        ## look-behind commits to its first match.
      lookFail*: bool
        ## Set by the parser on the ``(?!)`` it reads ``(*FAIL)`` as.  In
        ## Oniguruma ``(*FAIL)`` is a node of its own and not a look-ahead, so a
        ## look-behind may hold it where it may not hold a ``(?!)`` the pattern
        ## wrote (``validateLookbehinds``).  Nothing reads it after that check,
        ## so only ``demoteUnnamedCaptures``, the one pass before it that builds
        ## a look-around anew, copies it; ``mergeLiterals`` drops it.
    of nkAtomicGroup:
      atomicBody*: Node
    of nkConditional:
      condKind*: ConditionalKind
      condBodyPure*: bool
        ## Same rule, covering ``condBody`` alone -- see ``condHolds``.  Kept
        ## next to ``condKind`` so the two small fields share one padding slot;
        ## on its own the node grows past 64 bytes.
      condRefs*: NameRefs
        ## Groups ``condRefName`` resolves to; here, in the rest of that same
        ## padding slot, since this branch is the one on the 64-byte line.
      condRefIndex*: int32 ## capture index for ckBackref
      condScope*: int32
        ## ``backrefScope`` for ckNamedRef.  Both 32 bits wide, so the two
        ## share the word ``condRefIndex`` had alone.
      condRefName*: string
        ## Capture name for ckNamedRef.  On a ckRegexCond, the condition's
        ## text when it may still be a group's name (no ``)`` of its own),
        ## which ``resolveBareNameConditions`` reads; anything else, "".

      condYes*: Node ## yes branch
      condNo*: Node ## no branch (nil if absent)
      condBody*: Node ## regex body for ckRegexCond
    of nkSubexpCall:
      callIndex*: int ## capture group index to call (-1 for named)
      callName*: string ## capture group name (empty for numeric)
      callRefs*: NameRefs ## groups ``callName`` resolves to
      callPos*: int32 ## See ``lookPos``.
    of nkAbsent:
      absentKind*: AbsentKind
      absentEmpty*: bool
        ## [isEmptyAbsentFunc]'s answer, filled in by [markAbsents]
        ## on the compiled tree so the matcher need not walk the pattern each
        ## time it enters the function.  False on a node the pass never
        ## reached, which only costs the scan the flag lets the matcher skip.
      absentLoopsOnExpr*: bool
        ## ``(?~|X|E)`` whose E is a greedy repeat of one character
        ## (``oneCharRepeat``), which Oniguruma makes the loop around X
        ## (``make_absent_tree_for_simple_one_char_repeat``): E's bounds,
        ## ``absentLoopLo`` and ``absentLoopHi``, then bound how often X runs.
        ## Set by the parser, which reads E as Oniguruma's does, before
        ## unnamed groups are demoted.
      absentPos*: int32 ## See ``lookPos``.
      absentLoopLo*, absentLoopHi*: int32
        ## E's bounds when ``absentLoopsOnExpr``, ``absentLoopHi`` -1 for no
        ## upper bound.  Recorded with the flag, so no pass after the parser
        ## reads them off E, which demotion and literal merging reshape.
      absentBody*: Node ## absent pattern (nil for abClear)
      absentExpr*: Node ## expression to match (for abExpression only)
      absentLoopLeaf*: Node
        ## The character E repeats when ``absentLoopsOnExpr``, found on the
        ## compiled tree by [markAbsents], else nil.  Borrowed, not a child,
        ## so ``childNodes`` skips it.
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

  AltTrieEdge* = object
    ## One labelled step of an [AltTrie]. The edges leaving a state are
    ## contiguous and ascending in ``label``, so a walk gives up as soon as it
    ## passes the byte it is after.
    label*: uint8
    next*: int32 ## state the edge leads to

  AltTrieState* = object
    ## One [AltTrie] state: where its edges and its terminals live in the
    ## trie's flat arrays, and how many subject bytes reaching it consumed.
    edgeOff*, edgeLen*: int32
    termOff*, termLen*: int32
      ## Run in ``AltTrie.terms`` of the alternatives that end here, ascending.
      ## A run and not a single index because two branches may spell the same
      ## string, and the second is still a branch the matcher must offer.
    depth*: int32 ## bytes from the root, i.e. what a terminal here consumed
    rowOff*: int32
      ## Start of this state's 256-entry row in ``AltTrie.rows``, or -1 when
      ## it has none and the step reads ``edges``. Rows go to the widest and
      ## shallowest states, and only as many as the trie's size pays for (see
      ## ``AltTrieRowMinEdges``, ``AltTrieStatesPerRow``, ``AltTrieMaxRows``).

  AltTrie* = ref object
    ## Byte trie over an alternation whose every branch is a plain literal.
    ## One walk answers what a first-byte hint per branch answers one branch
    ## at a time, and more: a terminal names the branch *and* the offset past
    ## it, so the matcher never re-compares the bytes the walk read.
    ##
    ## Only sound while ``rfIgnoreCase`` is off -- the edges are the literal's
    ## own bytes, and a fold is neither a byte nor, for the multi-character
    ## ones, a fixed number of them. Every reader tests the flag first, and
    ## the compiler refuses to build one for a pattern that can switch the
    ## flag on partway through (see ``altTriesUsable``).
    states*: seq[AltTrieState] ## state 0 is the root
    edges*: seq[AltTrieEdge]
    terms*: seq[int32]
    firstBytes*: set[uint8]
      ## Bytes the root has an edge for. Most positions the alternation is
      ## reached from start no branch at all, so the common answer is one set
      ## test rather than an edge scan.
    rows*: seq[int32]
      ## Transition rows, 256 entries each: ``rows[st.rowOff + b]`` is the
      ## state byte ``b`` leads to from ``st``, or -1 when it leads nowhere.
      ## The state itself and not an edge index, so a step reads one array.

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
      pair*: array[2, uint8]
        ## The two members when ``pairOk``: a set that small is scanned with
        ## one memchr cursor per byte.
      pairOk*: bool ## Whether ``bytes`` has exactly two members.
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
  #
  # The number is also the memory management's: a traced-GC ``seq`` and
  # ``string`` are one pointer each where ``arc``/``orc`` spend a pointer and
  # a length, so the node lays out one word narrower under ``--mm:refc``.
  # Both are pinned, so neither build can grow it unnoticed.
  #
  # ``id`` is free either way -- it fits in the padding the discriminant's
  # alignment already leaves -- which is what these unchanged numbers record.
  const expectedNodeSize = when defined(gcDestructors): 64 else: 56
  static:
    doAssert sizeof(typeof(default(Node)[])) == expectedNodeSize,
      "Node grew to " & $sizeof(typeof(default(Node)[])) & " bytes, expected " &
        $expectedNodeSize & "; see the note here"

# ``reni.nim`` re-exports ``==`` and ``$`` from this module by name, and a
# name carries all of its overloads. An operator declared here for an internal
# type therefore lands in the package's public symbol set; it stays unusable
# from outside only for as long as ``reni.nim`` does not re-export the type it
# takes -- [NameRefs] and [NodeId] are exported here, as their accessors need,
# but not from there. Declare one for a re-exported type only when it is meant
# to be part of that API.

proc `==`*(a, b: NameRefs): bool {.borrow.}
  ## **Internal API.** Two offsets naming the same run.  Only equality is
  ## borrowed: the arithmetic that walks a run belongs to [nameRefsOf].

proc `==`*(a, b: NodeId): bool {.borrow.}
  ## **Internal API.** Two ids naming the same node.  Only equality is
  ## borrowed, so an id cannot be added to or ordered against anything by
  ## accident; indexing the table is [nodes]'s job.

const NoNameRefs* = NameRefs(0)
  ## **Internal API.** The name-reference table's reserved empty run, so a
  ## [NameRefs] field nobody wrote names no group rather than the first one's.

const EveryNamedGroup* = high(int32)
  ## **Internal API.** A scope ([namedGroupsRead]) that every named group is
  ## inside: for ``\g<name>``, and for a bare ``(?(name)...)``.  Oniguruma
  ## reads the bare spelling as a condition on the pattern ``name``; reni
  ## reads it as PCRE2 does, as a test of every group so named.

const NoNodeId* = NodeId(0)
  ## **Internal API.** The node table's reserved slot 0, which holds ``nil``.
  ## Real nodes are numbered from 1, so an unwritten [NodeId] reads as "no
  ## node" rather than as the root, and an optional node needs no flag.

proc patternPos*(node: Node): int32 =
  ## **Internal API.** Where ``node`` starts in the pattern, on the kinds
  ## ``validateLookbehinds`` can reject (see ``lookPos``).  0 when the offset
  ## was not recorded, and on every other kind.
  case node.kind
  of nkAnchor: node.anchorPos
  of nkLookaround: node.lookPos
  of nkCapture: node.capturePos
  of nkNamedCapture: node.namedCapturePos
  of nkSubexpCall: node.callPos
  of nkAbsent: node.absentPos
  else: 0

proc `patternPos=`*(node: Node, pos: int32) =
  ## **Internal API.** Record where ``node`` starts in the pattern, on the
  ## kinds [patternPos] reads; on every other kind, do nothing.
  case node.kind
  of nkAnchor:
    node.anchorPos = pos
  of nkLookaround:
    node.lookPos = pos
  of nkCapture:
    node.capturePos = pos
  of nkNamedCapture:
    node.namedCapturePos = pos
  of nkSubexpCall:
    node.callPos = pos
  of nkAbsent:
    node.absentPos = pos
  else:
    discard

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
    regionOk*: bool
      ## Whether ``prefix`` may bound the scan by an occurrence of ``byte``.
    prefix*: set[uint8]
      ## Bytes consumable before ``byte``; a superset moves the bound left,
      ## a missing byte is unsound.

  RequiredLiteralKind* = enum
    rlNone
    rlString ## ``str`` occurs.
    rlSet ## One of the bytes in ``set`` occurs.

  RequiredLiteral* = object
    ## What every match holds at or after the position its search starts
    ## from, beyond [RequiredByteInfo]'s one byte: a byte string, or failing
    ## that a set of bytes one of which occurs.  Oniguruma's ``exact`` and
    ## ``map`` with an unbounded ``dist_max``: the search tests that it occurs
    ## before it tries a position.
    kind*: RequiredLiteralKind
    str*: string ## Under ``rlString``.
    at*: int
      ## Under ``rlString``: where in ``str`` its least likely byte stands,
      ## which the search looks for first.
    set*: set[uint8] ## Two or more bytes, under ``rlSet``.

  LeadBehindInfo* = object
    ## Leading ``(?<=lit)`` over a case-sensitive ASCII literal: every match
    ## starts ``offset`` bytes past ``byte``, the literal's first byte.
    valid*: bool
    byte*: uint8
    offset*: int ## Byte length of the literal; positive whenever ``valid``.

  LeafGate* = object
    ## What a repeat entry needs to know about its body: whether it matches at
    ## most one way -- which lets a greedy repeat scan forward, one int a
    ## repetition -- and which ASCII bytes a run of it consumes.  Neither asks
    ## about the position, so both are derived once per pattern; a reader whose
    ## flags have left ``Regex.flags`` answers the long way instead.
    accept*: set[uint8] ## Bytes a run consumes, meaningful while ``runnable``.
    singleWay*: bool
    runnable*: bool
    graphemeDep*: bool ## ``.`` alone: the answers hold while grapheme mode is off.

  ClassFold* = object
    ## What a class answers under ``(?i)`` without reading the subject,
    ## derived once under ``flags``.  Without it the matcher walks the atoms,
    ## folding each, for both answers at every test: the plain bitmap
    ## (``asciiSet``) is exact only with folding off.
    ascii*: set[uint8]
      ## The ASCII bytes the atoms accept under ``flags``, before negation:
      ## what ``classHasByte`` answers below 0x80.
    folds*: uint32
      ## Bit ``i`` set when ``MultiCharFolds[i]``'s source is a member, which
      ## ``classWays`` asks before it leaves a fold variant open, and
      ## multi-character folds apply to the class at all
      ## (``leafgate.classFoldsApply``).  0 rules every fold variant out.
    flags*: RegexFlags
      ## The flags in force at the class, as the pattern reads; a reader
      ## under any others answers the long way.
    derived*: bool ## False in a slot no class under ``(?i)`` fills.

  Regex* = object
    pattern: string
    ast: Node
    nodes: seq[Node]
      ## Every node reachable from ``ast``, indexed by its [NodeId]; slot 0 is
      ## ``nil``.  The matcher's stacks name a node by its index here rather
      ## than holding it, which is what keeps those entries plain data.  Built
      ## by ``initRegex``, so a ``Regex`` cannot exist with the two out of step.
    leafGates: seq[LeafGate]
      ## One entry per ``NodeId``, derived under ``flags`` when the pattern
      ## compiled; see [LeafGate].  Empty on a ``Regex`` assembled without it,
      ## which only costs the matcher the derivation it does anyway.
    emptyStatus: seq[uint32]
      ## By the [NodeId] of a repeat's *body*, which its continuation frame
      ## holds: the groups whose change makes an iteration that consumed
      ## nothing count as progress, bit ``n`` for group ``n`` (Oniguruma's
      ## ``empty_status_mem``).  A group is in it when this is the innermost
      ## repeat around it that may match empty, and a reference or a
      ## ``(?(n)...)`` reads it from outside the repeat.  Groups from 32 up
      ## have no bit, as under Oniguruma's ``MEM_STATUS_LIMIT_ON``.
      ##
      ## Filled by ``markGroupReads``.  No rewrite leaves a body under two
      ## repeats, so the key names one (``test_engine_internals`` pins it).
      ## Empty when no repeat in the pattern has a set.
    opensUnset: seq[bool]
      ## By capture index (1-based): whether entering the group clears it, as
      ## Oniguruma's ``MEM_START_PUSH`` does for every group a reference or a
      ## conditional reads.  Until the group closes again, a plain reference
      ## or a ``(?(n)...)`` reads it as unset, on a later iteration too:
      ## ``(b|a\1)+`` stops after the "b" of "bab", where PCRE2 and Perl read
      ## that "b" in the second iteration.  A reference with a level still
      ## reads the span the group last closed with (see ``backrefLeveled``):
      ## the cleared slot encodes it.  Empty when no group is read.
    openedFirst: int32
    openedLast: int32
      ## Once a ``\k<name+0>`` reads a name several groups declare, the
      ## groups ``openedFirst .. openedLast`` keep when their span opened, in
      ## slots past the groups: Oniguruma reads the closed span opened last,
      ## which neither the starts nor the declaration order tells.  The run
      ## spans every group something reads (``opensUnset``), so each group
      ## that takes a stamp has a slot, found by subtraction; a group inside
      ## it that nothing reads takes one nothing writes.  ``openedFirst`` is 0
      ## when no reference asks.  Set by ``markGroupReads``.
    flags: RegexFlags
      ## The flags the pattern was compiled under.  Read through the `flags`
      ## accessor, which carries the reason this is not a public field.
    captureCount: int
    namedCaptures: seq[(string, int)]
    nameRefs: seq[int32]
      ## Every name reference's run of capture-group indices, concatenated,
      ## each run preceded by its length; slot 0 is a zero length.  A node
      ## holds its own run's offset (see [NameRefs]), so resolving
      ## ``\k<name>`` is a load, not a walk of ``namedCaptures``.
    groupBodies: seq[Node]
    groupFlags: seq[RegexFlags] ## flags active when each group was defined
    firstCharInfo: FirstCharInfo
    literalScan: bool
    requiredByte: RequiredByteInfo
    semiEndAnchored: bool
      ## Every match ends at ``\Z``, so the scan may jump straight to it.
    semiEndDMax: int
      ## Upper bound on the bytes a match consumes, as Oniguruma counts them,
      ## or -1 when unbounded.  Oniguruma's ``anchor_dmax``: how far left of
      ## the anchor a match may still start.  See [anchorDMax].
    levelBackrefs: bool
      ## The pattern uses a recursion-level backreference, so the matcher has
      ## to maintain the per-group capture history.
    leadRun: Node
      ## Leading greedy unbounded repeat over a one-way leaf, or nil. A failed
      ## run rules out starts inside it, so the scan jumps to its end.
    leadLeaf: Node
      ## Leaf every match starts with, or nil. Tested before entering the
      ## matcher, so a refusal costs one character test, not a full attempt.
    leadAnchors: set[AnchorKind]
      ## Zero-width assertions every match starts with, as a conjunction.
      ## Tested beside ``leadLeaf`` before entering the matcher; never
      ## contains ``akKeep``.
    leadRepeat: Node
      ## Leaf every match starts with twice running (``(leaf)\1``), or nil.
      ## Replaces ``leadLeaf`` where set.
    leadBehind: LeadBehindInfo ## Leading look-behind literal, or invalid.
    requiredLit: RequiredLiteral
      ## Tested after ``requiredByte``; at the end so the fields the scan
      ## reads keep their offsets.
    classFolds: seq[ClassFold]
      ## One entry per ``NodeId``, filled for each class the pattern reads
      ## under ``(?i)``; see [ClassFold].  Empty when there is none.  Last,
      ## for the reason ``requiredLit`` gives.

  Span* = object
    ## Half-open byte range [a, b). `a` is the start (inclusive), `b` is
    ## the end (exclusive).  A negative `a` means the span is unset.
    a*: int
    b*: int

  Match* = object
    found*: bool
    boundaries*: seq[Span]
    startChar*: int
      ## Subject offset the successful attempt started at; -1 when the engine
      ## reports no match.  ``boundaries[0]`` is what the match *reports*, and
      ## ``\K`` moves that start either way -- inside a lookbehind even behind
      ## the scan position -- so it cannot also serve as scan progress.  This is
      ## what the attempt consumed from, and a scanning loop steps on it
      ## instead: over a forward scan it never moves backwards (a backward
      ## search writes its own decreasing start here, and is not a scan a loop
      ## steps through).  PCRE2 splits the two the same way, as ``ovector[0]``
      ## and ``pcre2_get_startchar``.

const DefaultStepLimit* = 10_000_000
  ## Steps one attempt -- the match tried at one start position -- may take
  ## before it raises ``RegexLimitError``; see ``SearchStepsPerByte`` for the
  ## search as a whole.  The number is Oniguruma's default retry limit
  ## (``onig_get_retry_limit_in_match``), but not the unit: Oniguruma counts
  ## backtracks, and a backtrack costs 1.6 to 10 steps on the three TextMate
  ## grammar patterns that come near the limit.  Over the 6,030 patterns of
  ## 131 grammars, searched on 383 lines of source code, this limit gives up
  ## exactly where Oniguruma does; anything from 6.4 to 22 million would, and
  ## 1,000,000 stopped on lines Oniguruma answers.  Other patterns can still
  ## differ.
  ##
  ## A search that finds the subject lacks what every match holds -- the
  ## ``b`` of ``(a+)+b`` -- answers "no match" without trying a position, so
  ## it does not raise there.  Oniguruma does the same only when that literal
  ## is the one its optimizer picked to search for: over a run of ``a``, it
  ## answers ``(\w+)+z`` at once and gives up on ``(a+)+b``, whose search
  ## hint is the leading ``a``.  Both have no match to give up on here.
const SearchStepsPerByte* = 100
  ## Steps a search earns, on top of the step limit, for every byte its start
  ## position moves, which keeps a search's work linear in the subject.  The
  ## densest pattern measured on the benchmark's code corpus,
  ## ``(\w+)\s+\1\b``, takes about 6.4 steps a byte.
const DefaultMaxRecursionDepth* = 50

const UnsetSpan* = Span(a: -1, b: -1)
  ## Sentinel span returned by API accessors when a span is unset or out of
  ## range (e.g. a non-participating capture group, or `matchSpan` on a
  ## `Match` where `found` is false).

proc pattern*(r: Regex): lent string {.inline.} =
  r.pattern

proc flags*(r: Regex): RegexFlags {.inline.} =
  ## The flags the pattern was compiled under.  Readable but not writable:
  ## ``firstCharInfo``, ``literalScan``, ``requiredByte``, ``semiEndDMax`` and
  ## the lookaround annotations are all derived from these at compile time, so
  ## a ``Regex`` whose flags were changed afterwards would report one thing and
  ## match under another.  Compile a second ``Regex`` instead.
  r.flags

proc nodes*(r: Regex): lent seq[Node] {.inline.} =
  ## **Internal API.** The node table [NodeId]s index; see ``Regex.nodes``.
  r.nodes

proc leafGates*(r: Regex): lent seq[LeafGate] {.inline.} =
  ## **Internal API.** Per-node repeat-entry answers; see ``Regex.leafGates``.
  r.leafGates

proc setLeafGates*(r: var Regex, gates: sink seq[LeafGate]) {.inline.} =
  ## **Internal API.** Fill in [LeafGate]s.  Not ``initRegex``'s business: it
  ## needs the node table that constructor builds, and fold tables it must not
  ## depend on.
  r.leafGates = gates

proc classFoldAt*(
    r: ptr Regex, id: NodeId, flags: RegexFlags
): ptr ClassFold {.inline.} =
  ## **Internal API.** The [ClassFold] of the class ``id`` names when it was
  ## derived under ``flags``, else nil.
  if id.int < r[].classFolds.len:
    result = addr r[].classFolds[id.int]
    if not result.derived or result.flags != flags:
      result = nil

proc setClassFolds*(r: var Regex, folds: sink seq[ClassFold]) {.inline.} =
  ## **Internal API.** Fill in [ClassFold]s, as [setLeafGates] does gates.
  r.classFolds = folds

proc emptyStatus*(r: Regex, body: NodeId): uint32 {.inline.} =
  ## **Internal API.** The empty-check set of the repeat over ``body``; see
  ## ``Regex.emptyStatus``.
  if body.int < r.emptyStatus.len:
    r.emptyStatus[body.int]
  else:
    0

proc setEmptyStatus*(r: var Regex, status: sink seq[uint32]) =
  ## **Internal API.** Fill in ``Regex.emptyStatus``: by body [NodeId], or
  ## empty when no repeat has a set.
  r.emptyStatus = status

proc opensUnset*(r: Regex, capIdx: int): bool {.inline.} =
  ## **Internal API.** Whether entering group ``capIdx`` (1-based) clears it;
  ## see ``Regex.opensUnset``.
  capIdx < r.opensUnset.len and r.opensUnset[capIdx]

proc setOpensUnset*(r: var Regex, groups: sink seq[bool]) =
  ## **Internal API.** Fill in ``Regex.opensUnset``: by capture index
  ## (1-based), or empty when no group needs it.
  r.opensUnset = groups

proc openOrder*(r: Regex): bool {.inline.} =
  ## **Internal API.** Whether any group keeps when its span opened; see
  ## ``Regex.openedLast``.
  r.openedFirst > 0

proc openedGroups*(r: Regex): Slice[int] {.inline.} =
  ## **Internal API.** The groups that keep when their span opened, under
  ## [openOrder]; see ``Regex.openedLast``.
  int(r.openedFirst) .. int(r.openedLast)

proc setOpenedGroups*(r: var Regex, groups: Slice[int]) =
  ## **Internal API.** Fill in ``Regex.openedLast``: a non-empty range.
  r.openedFirst = int32(groups.a)
  r.openedLast = int32(groups.b)

proc nameRefCount*(r: Regex, refs: NameRefs): int32 {.inline.} =
  ## **Internal API.** How many capture groups ``refs`` names.
  r.nameRefs[refs.int]

proc nameRefFirst*(r: Regex, refs: NameRefs): int32 {.inline.} =
  ## **Internal API.** The first capture group ``refs`` names, or -1 for none.
  ## What a ``\g<name>`` call wants: it enters one body, so a name declared
  ## twice calls the first.
  if r.nameRefs[refs.int] > 0:
    r.nameRefs[refs.int + 1]
  else:
    -1

iterator nameRefsOf*(r: Regex, refs: NameRefs): int32 =
  ## **Internal API.** The capture groups ``refs`` names, 0-based, in
  ## declaration order.  A ``\k<name>`` without a level tries them through
  ## [nameRefsBackward] instead.
  for k in 1 .. r.nameRefs[refs.int].int:
    yield r.nameRefs[refs.int + k]

iterator nameRefsBackward*(r: Regex, refs: NameRefs): int32 =
  ## **Internal API.** The capture groups ``refs`` names, 0-based, last
  ## declared first -- the order a ``\k<name>`` without a level tries them
  ## in, taking the first that is set and matches.  Oniguruma's
  ## ``compile_tree`` writes a reference's groups reversed, and
  ## ``BACKREF_MULTI`` (``_IC`` under ``(?i)``) walks them in that order:
  ## ``(?<n>a)(?<n>)\k<n>`` on "aa" matches 0..1, the empty group first.
  ## The run itself stays in declaration order, as a ``\g<name>`` reading
  ## the same run calls its first group ([nameRefFirst]).
  for k in countdown(r.nameRefs[refs.int].int, 1):
    yield r.nameRefs[refs.int + k]

proc ast*(r: Regex): lent Node {.inline.} =
  ## **Internal API.** The compiled AST root, for the compiler, the matcher
  ## and this repository's tests. Not reachable through ``import reni``, and
  ## the shape of the tree changes without notice.
  r.ast

proc captureCount*(r: Regex): int {.inline.} =
  r.captureCount

proc namedCaptures*(r: Regex): lent seq[(string, int)] {.inline.} =
  r.namedCaptures

proc groupBodies*(r: Regex): lent seq[Node] {.inline.} =
  r.groupBodies

proc groupFlags*(r: Regex): lent seq[RegexFlags] {.inline.} =
  ## **Internal API.** The flags each capture group was defined under. A
  ## call into a group (``\g<n>``, recursion) restores them, so the body
  ## matches under the modifiers it was written with rather than the caller's.
  ## Read-only: emptying the seq left the matcher's bounds check to skip the
  ## restore, silently matching the body under the caller's flags.
  r.groupFlags

proc firstCharInfo*(r: Regex): FirstCharInfo {.inline.} =
  r.firstCharInfo

proc requiredByte*(r: Regex): lent RequiredByteInfo {.inline.} =
  ## Borrowed; the set is wide.
  r.requiredByte

proc requiredLit*(r: Regex): lent RequiredLiteral {.inline.} =
  ## Borrowed, like [requiredByte].
  r.requiredLit

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

proc leadRun*(r: Regex): lent Node {.inline.} =
  ## Leading repeat whose run a failed attempt may skip, or nil.
  r.leadRun

proc leadLeaf*(r: Regex): lent Node {.inline.} =
  ## Leaf the first character of every match must match, or nil.
  r.leadLeaf

proc leadAnchors*(r: Regex): set[AnchorKind] {.inline.} =
  ## Zero-width assertions every match starts with; empty when there are none.
  r.leadAnchors

proc leadRepeat*(r: Regex): lent Node {.inline.} =
  ## Leaf every match starts with twice running, or nil.
  r.leadRepeat

proc leadBehind*(r: Regex): lent LeadBehindInfo {.inline.} =
  ## Leading look-behind literal, or invalid.
  r.leadBehind

proc span*(a, b: int): Span {.inline.} =
  Span(a: a, b: b)

proc `==`*(s: Span, sl: Slice[int]): bool {.inline.} =
  ## Convenience: allow ``check m.boundaries[0] == 0 .. 3``.
  s.a == sl.a and s.b == sl.b

proc `==`*(sl: Slice[int], s: Span): bool {.inline.} =
  s == sl

proc `$`*(s: Span): string =
  $s.a & " .. " & $s.b

template view*(nodes: seq[Node]): untyped =
  ## ``nodes`` as an ``openArray``, for ``for child in node.children.view``.
  ## A plain ``for`` over a seq field of a ``Node`` copies the whole seq under
  ## ORC first -- cursor inference does not borrow it -- and every AST pass
  ## walks children, so that copy was a large share of compiling a pattern.
  ## ``items`` and ``pairs`` read an ``openArray`` in place.  The loop body
  ## must not replace the seq it walks; no pass does.
  toOpenArray(nodes, 0, nodes.high)

iterator childNodes*(node: Node): Node =
  ## Yield all direct child nodes (skips nil).
  case node.kind
  of nkConcat:
    for c in node.children.view:
      yield c
  of nkAlternation:
    for a in node.alternatives.view:
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

proc collectGroupBodies*(
    node: Node,
    bodies: var seq[Node],
    flags: var seq[RegexFlags],
    currentFlags: RegexFlags = {},
) =
  ## Walk AST to collect capture group bodies and their definition-time flags.
  if node == nil:
    return
  var activeFlags = currentFlags
  case node.kind
  of nkCapture:
    if node.captureIndex >= bodies.len:
      bodies.setLen(node.captureIndex + 1)
      flags.setLen(node.captureIndex + 1)
    bodies[node.captureIndex] = node.captureBody
    flags[node.captureIndex] = activeFlags
  of nkNamedCapture:
    if node.namedCaptureIndex >= bodies.len:
      bodies.setLen(node.namedCaptureIndex + 1)
      flags.setLen(node.namedCaptureIndex + 1)
    bodies[node.namedCaptureIndex] = node.namedCaptureBody
    flags[node.namedCaptureIndex] = activeFlags
  of nkFlagGroup:
    activeFlags = activeFlags + node.flagsOn - node.flagsOff
  else:
    discard
  for child in node.childNodes:
    collectGroupBodies(child, bodies, flags, activeFlags)

proc numberNodes*(ast: Node): seq[Node] =
  ## Give every node reachable from ``ast`` its slot in the returned table and
  ## record that slot on the node, so both directions of the mapping are built
  ## together and cannot disagree.
  ##
  ## Slot 0 is reserved and holds ``nil`` (see ``NoNodeId``).  A node reached
  ## twice is numbered once: a rewrite may leave one subtree under two
  ## parents, so the tree is a DAG as far as this is concerned.
  ##
  ## Runs on the final tree: a later rewrite would hand the matcher an index
  ## for a node no longer in it.  Numbering twice is that mistake in visible
  ## form and is refused, as is a subtree borrowed from another numbered tree,
  ## whose id names a slot in *that* table.
  result = @[Node(nil)]
  if ast == nil:
    return
  doAssert ast.id == NoNodeId,
    "numberNodes: this tree is already numbered; number the final tree once"
  var pending = @[ast]
  while pending.len > 0:
    let node = pending.pop()
    if node.id != NoNodeId:
      # Numbered already.  On this walk, if the id names this very node in the
      # table being built -- the DAG case, and nothing more to do.  Anything
      # else is a node borrowed from another numbered tree: its id would index
      # this table at an offset naming a different node, or past its end.
      doAssert node.id.int < result.len and result[node.id.int] == node,
        "numberNodes: this tree shares a subtree with another numbered tree"
      continue
    node.id = NodeId(result.len)
    result.add(node)
    for child in childNodes(node):
      if child != nil:
        pending.add(child)

iterator namedGroupsRead*(
    namedCaptures: openArray[(string, int)], name: string, scope: int32
): int =
  ## **Internal API.** The groups called ``name`` a reference to it reads,
  ## 0-based, in declaration order, where ``scope`` is how many named groups
  ## had opened where the reference is written.  Oniguruma looks the name up
  ## right there, as it parses the reference, so a group of that name declared
  ## later is not one it reads, while the group the reference sits in is:
  ## ``(?<n>a)\k<n>(?<n>b)`` reads the first ``n`` alone.  Where no group so
  ## named has opened yet, Oniguruma rejects the pattern
  ## (``ONIGERR_UNDEFINED_NAME_REFERENCE``) and reni reads every one.
  var upto = min(int(scope), namedCaptures.len)
  var before = false
  for i in 0 ..< upto:
    if namedCaptures[i][0] == name:
      before = true
      break
  if not before:
    upto = namedCaptures.len
  for i in 0 ..< upto:
    if namedCaptures[i][0] == name:
      yield namedCaptures[i][1]

proc resolveNameRefs*(nodes: seq[Node], namedCaptures: seq[(string, int)]): seq[int32] =
  ## Resolve every name reference in ``nodes`` to the capture groups it names,
  ## recording the run's offset on the node and returning the table the
  ## offsets index.
  ##
  ## Runs over the node table rather than the tree, so it reaches exactly what
  ## [numberNodes] numbered.  Slot 0 is a zero length, so a node this never
  ## visits -- a numeric ``\g<1>``, say -- names no group.
  ##
  ## A name declared twice yields a run of the groups [namedGroupsRead] gives,
  ## which is why one index would not do: ``\k<name>`` picks one of them as it
  ## matches, and ``(?(<name>)...)`` holds if any of them captured.
  result = @[0'i32]
  if namedCaptures.len == 0:
    return
  # One run per distinct answer, not per reference: a pattern naming one group
  # from a hundred places stores one copy of it, not a hundred.  An answer is
  # the first so many groups of one name, so the name and the count key it.
  var runs: Table[(string, int32), int32]
  for node in nodes:
    if node == nil:
      continue
    template resolve(name: string, scope: int32, field: untyped) =
      if name.len > 0:
        var found = 0'i32
        for _ in namedCaptures.namedGroupsRead(name, scope):
          inc found
        var off = int32(NoNameRefs)
        if found > 0:
          off = runs.getOrDefault((name, found), -1'i32)
          if off < 0:
            off = int32(result.len)
            result.add(found)
            for index in namedCaptures.namedGroupsRead(name, scope):
              result.add(int32(index))
            runs[(name, found)] = off
        field = NameRefs(off)

    case node.kind
    of nkNamedBackref:
      resolve(node.backrefName, node.backrefScope, node.backrefRefs)
    of nkConditional:
      if node.condKind == ckNamedRef:
        resolve(node.condRefName, node.condScope, node.condRefs)
    of nkSubexpCall:
      resolve(node.callName, EveryNamedGroup, node.callRefs)
    else:
      discard

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
    requiredLit: RequiredLiteral = RequiredLiteral(),
    semiEndAnchored: bool = false,
    semiEndDMax: int = -1,
    levelBackrefs: bool = true,
    leadRun: Node = nil,
    leadLeaf: Node = nil,
    leadAnchors: set[AnchorKind] = {},
    leadRepeat: Node = nil,
    leadBehind: LeadBehindInfo = LeadBehindInfo(valid: false),
): Regex =
  ## Assemble a compiled ``Regex``.  Numbering the tree and resolving its name
  ## references happen here rather than in the caller: the matcher reaches a
  ## node through one of the tables this fills in and a name through the
  ## other, so a ``Regex`` built without them would match nothing at all.
  let nodeTable = numberNodes(ast)
  # Resolved before the constructor so `nodes: nodeTable` below is the table's
  # last use and moves; reading it inside the constructor would `=dup` it.
  let refs = resolveNameRefs(nodeTable, namedCaptures)
  Regex(
    pattern: pattern,
    ast: ast,
    nodes: nodeTable,
    nameRefs: refs,
    flags: flags,
    captureCount: captureCount,
    namedCaptures: namedCaptures,
    groupBodies: groupBodies,
    groupFlags: groupFlags,
    firstCharInfo: firstCharInfo,
    literalScan: literalScan,
    requiredByte: requiredByte,
    requiredLit: requiredLit,
    semiEndAnchored: semiEndAnchored,
    semiEndDMax: semiEndDMax,
    levelBackrefs: levelBackrefs,
    leadRun: leadRun,
    leadLeaf: leadLeaf,
    leadAnchors: leadAnchors,
    leadRepeat: leadRepeat,
    leadBehind: leadBehind,
  )

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

proc byteSetHint(bs: set[uint8]): FirstCharInfo =
  ## A multi-byte lead hint.  Every ``fcByteSet`` is built through this, so the
  ## search reads ``pair`` rather than walking the set per call.
  result = FirstCharInfo(kind: fcByteSet, bytes: bs)
  if bs.card == 2:
    var i = 0
    for v in bs:
      result.pair[i] = v
      inc i
    result.pairOk = true

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
  byteSetHint(merged)

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
  ## The characters whose multi-character case fold the matcher expands, and
  ## what each folds to: 21 of the [AllMultiCharFoldSources].  Single source
  ## of truth: the fold lookups and the length analysis below are all derived
  ## from it, so none of them can drift.
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

const AllMultiCharFoldSources*: array[29, (int32, int32)] = [
  ## Every character whose full case fold is more than one character
  ## (CaseFolding.txt status F), as ranges: the 104 Oniguruma's parser splits
  ## a ``(?i)`` class on, ``[ᾀ]`` into ``[ᾀ]|ἀι``.  [MultiCharFolds] holds
  ## the ones the matcher expands.  tests/test_unicode_data.nim holds this
  ## list to ``unicodedb``, and [MultiCharFolds]' sources inside it.
  (0x00DF'i32, 0x00DF'i32), # ß
  (0x0130'i32, 0x0130'i32), # İ
  (0x0149'i32, 0x0149'i32), # ŉ
  (0x01F0'i32, 0x01F0'i32), # ǰ
  (0x0390'i32, 0x0390'i32), # ΐ
  (0x03B0'i32, 0x03B0'i32), # ΰ
  (0x0587'i32, 0x0587'i32), # և
  (0x1E96'i32, 0x1E9A'i32), # ẖ..ẚ
  (0x1E9E'i32, 0x1E9E'i32), # ẞ
  (0x1F50'i32, 0x1F50'i32), # ὐ
  (0x1F52'i32, 0x1F52'i32), # ὒ
  (0x1F54'i32, 0x1F54'i32), # ὔ
  (0x1F56'i32, 0x1F56'i32), # ὖ
  (0x1F80'i32, 0x1FAF'i32), # ᾀ..ᾯ
  (0x1FB2'i32, 0x1FB4'i32), # ᾲ..ᾴ
  (0x1FB6'i32, 0x1FB7'i32), # ᾶ ᾷ
  (0x1FBC'i32, 0x1FBC'i32), # ᾼ
  (0x1FC2'i32, 0x1FC4'i32), # ῂ..ῄ
  (0x1FC6'i32, 0x1FC7'i32), # ῆ ῇ
  (0x1FCC'i32, 0x1FCC'i32), # ῌ
  (0x1FD2'i32, 0x1FD3'i32), # ῒ ΐ
  (0x1FD6'i32, 0x1FD7'i32), # ῖ ῗ
  (0x1FE2'i32, 0x1FE4'i32), # ῢ..ῤ
  (0x1FE6'i32, 0x1FE7'i32), # ῦ ῧ
  (0x1FF2'i32, 0x1FF4'i32), # ῲ..ῴ
  (0x1FF6'i32, 0x1FF7'i32), # ῶ ῷ
  (0x1FFC'i32, 0x1FFC'i32), # ῼ
  (0xFB00'i32, 0xFB06'i32), # ﬀ..ﬆ
  (0xFB13'i32, 0xFB17'i32), # ﬓ..ﬗ
]

const MultiCharFoldStarts* = block:
  ## The code points a fold expansion can begin with.  Hot-path lookups reject
  ## through this first: one set test instead of a walk of the table.
  ## ``unicode_utils.MultiCharFoldLeadMasks`` answers per subject byte, folds
  ## included.
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

const WidestUsefulHint = 255
  ## Above this many bytes a hint skips too little to pay for its per-position
  ## test. Only the full set is excluded: one load and bit test per byte is
  ## still cheaper than the walk it saves on rejected bytes.

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
    byteSetHint(bs)

proc firstCharFromRune(cp: int32, flags: RegexFlags): FirstCharInfo =
  ## Build a FirstCharInfo from a code point, handling both ASCII and non-ASCII.
  if cp < 128:
    let b = uint8(cp)
    if rfIgnoreCase in flags:
      if hasNonAsciiFoldEquiv(cp):
        return FirstCharInfo(kind: fcNone)
      byteSetInfo(asciiFoldBytes(b))
    else:
      # [byteSetInfo] would ask ``card``, a libgcc call without ``-mpopcnt``,
      # what one byte already answers.
      FirstCharInfo(kind: fcByte, byte: b)
  elif rfIgnoreCase in flags:
    # Case-insensitive non-ASCII: skip optimization (fold targets may differ)
    FirstCharInfo(kind: fcNone)
  else:
    # Non-ASCII case-sensitive: use the UTF-8 lead byte for fast skip
    FirstCharInfo(kind: fcByte, byte: utf8LeadByte(cp))

proc charTypeBytes(ct: CharTypeKind): set[uint8] =
  ## Bytes a character type can start with, or ``{}`` when it can start
  ## with anything.  Always the widest (Unicode) reading: the ASCII-only
  ## flags can be switched on at match time and only ever shrink the set, so
  ## a superset stays sound.  [leafLeadBytes] reads it away from the match
  ## start too.
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

const SKFoldBytes = {uint8('s'), uint8('S'), uint8('k'), uint8('K')}
  ## The only ASCII letters a non-ASCII rune folds to: ſ (U+017F) → s and
  ## K (U+212A) → k.

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

proc classCrossesAsciiBoundary*(node: Node): bool =
  ## Whether an atom of ``node`` is a range written from below U+0080 to at or
  ## above it -- the one shape that lets a stray byte above 0x7F match the
  ## class as a one-byte character, read the way [classHasByte] reads it.
  for atom in node.atoms:
    if atom.kind == ccRange and int32(atom.rangeFrom) < 0x80 and
        int32(atom.rangeTo) >= 0x80:
      return true
  false

proc atomsReachNonAscii*(atoms: seq[CcAtom]): bool =
  ## Whether a member of ``atoms`` can be a character at or above U+0080.
  ## Only answers false when every atom is provably ASCII-only, so
  ## [classFirstChar] dropping the lead bytes on that answer stays a superset.
  for atom in atoms:
    case atom.kind
    of ccLiteral:
      if int32(atom.rune) >= 0x80:
        return true
    of ccRange:
      if int32(atom.rangeTo) >= 0x80:
        return true
    of ccCharType:
      case atom.charType
      of ctDot, ctAnyChar, ctGraphemeCluster:
        return true
      else:
        # As [charTypeBytes] reads it: high bytes in the set mean the type
        # accepts characters above U+007F.
        if (charTypeBytes(atom.charType) - AllAsciiBytes).card > 0:
          return true
    of ccNestedClass:
      # A negated class accepts everything it does not list, high characters
      # included.
      if atom.nestedNegated or atomsReachNonAscii(atom.nestedAtoms):
        return true
    of ccIntersection:
      # The intersection is a subset of both sides, so it can only reach above
      # U+007F when both sides do.
      let left = atom.interLeftNeg or atomsReachNonAscii(atom.interLeft)
      let right = atom.interRightNeg or atomsReachNonAscii(atom.interRight)
      if left and right:
        return true
    else:
      # ``\p{...}``, ``\P{...}`` and the POSIX classes are Unicode-aware
      # outside ASCII.
      return true
  false

proc classLeadBytes(node: Node, flags: RegexFlags): set[uint8] =
  ## Lead bytes a character class can start with — always a superset of the
  ## truth, so the scan never skips a position the class could match.  ``{}``
  ## where it gives up.  [leafLeadBytes] reads it away from the match start
  ## too.
  var matched: set[uint8]
  var nonAscii, predicate: bool
  if not classAsciiMatches(node, matched, nonAscii, predicate):
    # What the shape reader gives up on -- a ``\p{...}``, a nested class, an
    # intersection -- ``asciiSet`` still answers below U+0080, exact and
    # before negation; above U+007F it says nothing, so the high bytes come
    # from the atoms.  ``rfIgnoreCase`` is out for [classBitmapAnswers]'s
    # reason: the set is built without folding.
    if not node.asciiSetOk or rfIgnoreCase in flags:
      return {}
    if node.negated:
      return (AllAsciiBytes - node.asciiSet) + NonAsciiBytes
    # A range across the ASCII boundary accepts stray bytes up to its end
    # ([classHasByte]), so take every high byte: the lead bytes alone would
    # drop 0x80..0xC1 and 0xF5..0xFF and the scan would skip a position the
    # class matches.  When no atom reaches U+0080 at all -- ``[[a-c][x-z]]``,
    # ``[a-z&&[^aeiou]]`` -- the ASCII set is the whole truth, and adding the
    # lead bytes would leave a hint that refuses nothing on a UTF-8 subject.
    var high: set[uint8]
    if classCrossesAsciiBoundary(node):
      high = NonAsciiBytes
    elif atomsReachNonAscii(node.atoms):
      high = ClassLeadBytes
    return node.asciiSet + high
  if node.negated:
    # ``matched`` is exact below U+0080 and case folding only ever adds to
    # it, so its complement is a superset of what the negated class accepts.
    # Every byte above 0x7F stays in: a one-byte character above U+007F
    # reaches no container, so it misses every member and the negation lets
    # it through.
    return (AllAsciiBytes - matched) + NonAsciiBytes
  var ascii = matched
  if rfIgnoreCase in flags:
    if predicate or nonAscii:
      # A fold variant of an ASCII byte can satisfy a predicate the byte
      # itself does not ((?iW:[[:^word:]]) matching "s" through ſ), and a
      # non-ASCII member can expand to arbitrary ASCII.  Give up.
      return {}
    for b in matched:
      ascii = ascii + asciiFoldBytes(b)
    ascii = ascii + SKFoldBytes
    # ſ and K are the only characters above U+007F that fold onto an ASCII
    # member, and both are multi-byte.  No member expands to several
    # characters: every fold source is above U+007F and shares its simple
    # fold with nothing below (``leafgate``'s static check).
    return ascii + ClassLeadBytes
  if nonAscii:
    ascii = ascii + ClassLeadBytes
  # Every member is ASCII, and only a one-byte character is looked up against
  # them (``codeIsClassifiable``), so the ASCII set is the whole hint.
  ascii

proc classFirstChar(node: Node, flags: RegexFlags): FirstCharInfo =
  ## [classLeadBytes] as the first-byte scan reads it.
  byteSetInfo(classLeadBytes(node, flags))

proc leafLeadBytes*(node: Node, flags: RegexFlags): set[uint8] =
  ## The bytes a character the class or type ``node`` matches can begin with,
  ## wherever it stands, or ``{}`` where nothing is known.  The required
  ## literal reads it at every position, not only where a match starts, so
  ## [classLeadBytes] and [charTypeBytes] must not narrow it to what is true
  ## at the start alone.
  case node.kind
  of nkCharClass:
    classLeadBytes(node, flags)
  of nkCharType:
    charTypeBytes(node.charType)
  else:
    {}

type FirstCharCache* = TableRef[(uint, RegexFlags), FirstCharInfo]
  ## Memo for ``extractFirstChar``, keyed by node identity and the flags it
  ## was asked under.  The analysis is a pure function of those two, and one
  ## caller -- the compiler annotating every alternative of every alternation
  ## -- asks about overlapping subtrees: without the memo a chain of nested
  ## alternations re-walks everything below it once per level.

proc isInvertedRange*(quantMin, quantMax: int): bool {.inline.} =
  ## Whether ``{quantMin,quantMax}`` is inverted (bounded ``m < n``).
  ## ``normaliseInvertedRanges`` swaps these at compile time, so only the
  ## passes that run before it need [effectiveQuantBounds]; everything
  ## downstream -- the analyses and the matcher -- may assume ``min <= max``.
  quantMax >= 0 and quantMin > quantMax

proc effectiveQuantBounds*(quantMin, quantMax: int): tuple[lo, hi: int] {.inline.} =
  ## Bounds after the inverted-range swap (``{2,0}`` like ``{0,2}``).
  if isInvertedRange(quantMin, quantMax):
    (quantMax, quantMin)
  else:
    (quantMin, quantMax)

type ReduceAction* = enum
  ## Oniguruma's ``ReduceType``: what a repeat of a repeat becomes, by
  ## [ReduceTable].
  raAsIs ## leave the pair as it stands
  raDel ## the outer repeat becomes the inner one
  raStar ## the pair becomes ``*``
  raPlus ## the pair becomes ``+``
  raLazyStar ## the pair becomes ``*?``
  raLazyOpt ## the pair becomes ``??``
  raPlusLazyOpt ## the pair becomes ``(?:X+)??``

proc quantTypeNum*(lo, hi: int, greedy: bool): int {.inline.} =
  ## Oniguruma's ``quantifier_type_num``: which of the six popular spellings
  ## a repeat of ``{lo,hi}`` is -- ``?`` 0, ``*`` 1, ``+`` 2, ``??`` 3,
  ## ``*?`` 4, ``+?`` 5 -- or -1 for a counted one, which [ReduceTable] has
  ## no row for.  ``hi`` is negative for no upper bound.
  let base = if greedy: 0 else: 3
  if lo == 0 and hi == 1:
    base
  elif lo == 0 and hi < 0:
    base + 1
  elif lo == 1 and hi < 0:
    base + 2
  else:
    -1

const ReduceTable*: array[6, array[6, ReduceAction]] = [
  # Oniguruma's ``ReduceTypeTable``, transcribed. Indexed ``[inner][outer]``,
  # both by [quantTypeNum].  The parser reads it to see a repeat as
  # Oniguruma's parser leaves it, the compiler to rewrite one.
  [raDel, raStar, raStar, raLazyOpt, raLazyStar, raAsIs], # inner ``?``
  [raDel, raDel, raDel, raPlusLazyOpt, raPlusLazyOpt, raDel], # inner ``*``
  [raStar, raStar, raDel, raAsIs, raPlusLazyOpt, raDel], # inner ``+``
  [raDel, raLazyStar, raLazyStar, raDel, raLazyStar, raLazyStar], # inner ``??``
  [raDel, raDel, raDel, raDel, raDel, raDel], # inner ``*?``
  [raAsIs, raStar, raPlus, raLazyStar, raLazyStar, raDel], # inner ``+?``
]

proc extractFirstCharUncached(
  node: Node, flags: RegexFlags, cache: FirstCharCache
): FirstCharInfo

proc extractFirstChar*(
    node: Node, flags: RegexFlags, cache: FirstCharCache = nil
): FirstCharInfo =
  ## Extract optimization hint about the first character/anchor of a pattern.
  ## ``cache``, when given, is consulted and filled as the walk descends.
  ## Runs after ``normaliseInvertedRanges``, so ``quantMin`` reads as written.
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
    for child in node.children.view:
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
    if node.quantMin >= 1:
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
  ##
  ## Runs after ``normaliseInvertedRanges``, so ``quantMin`` reads as written.
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
    # An optional prefix is no prefix.
    node.quantMin >= 1 and hasLiteralPrefix(node.quantBody, flags)
  of nkConcat:
    var currentFlags = flags
    for child in node.children.view:
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
    for alt in node.alternatives.view:
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
  ## Runs after ``normaliseInvertedRanges``, so ``quantMin`` reads as written.
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
    # A look-ahead's byte sits where the search already stands; keep it as fallback.
    var fromLook = RequiredByteInfo(valid: false)
    for child in node.children.view:
      if child.kind == nkFlagGroup and child.flagBody == nil:
        continue
      if child.kind in {nkAnchor, nkCalloutMax, nkCalloutCount, nkCalloutCmp}:
        continue
      let rb = extractRequiredByte(child, flags)
      if not rb.valid:
        continue
      if child.kind == nkLookaround:
        if not fromLook.valid:
          fromLook = rb
        continue
      return rb
    fromLook
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
  of nkLookaround:
    # Positive look-ahead only; its byte is reached by every match.
    if node.lookKind == lkAhead:
      extractRequiredByte(node.lookBody, flags)
    else:
      RequiredByteInfo(valid: false)
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

proc peelBareGroups*(node: Node): Node {.inline.} =
  ## Follow ``(?:...)`` wrappers to the body they hold. Bare groups match what
  ## their body matches, so shape readers see through them. Other groups stop it.
  result = node
  while result != nil and result.kind == nkGroup:
    result = result.groupBody

proc matchesEverywhere(node: Node): bool =
  ## Whether ``node`` has a match starting at every position, whatever the
  ## subject and the state it runs in.  Conservative: anything that might fail
  ## counts as failing.  So does an absent operator, which fails outright on
  ## the path of an absent pattern's scan (``absentScan`` in ``engine``).
  ##
  ## Every shape that answers true by itself is zero-width, so a window that
  ## ends where the match starts leaves one in place, an empty one.  A
  ## look-behind runs its body under such a window unless the body is
  ## fixed-length, and its length is then 0: either way a positive
  ## look-behind holds wherever its body matches everywhere.
  if node == nil:
    return false
  case node.kind
  of nkAnchor:
    # The start ``\K`` records is the scan's to discard.
    node.anchor == akKeep
  of nkLookaround:
    node.lookKind in {lkAhead, lkBehind} and matchesEverywhere(node.lookBody)
  of nkConcat:
    for child in node.children.view:
      if not matchesEverywhere(child):
        return false
    true
  of nkAlternation:
    for alt in node.alternatives.view:
      if matchesEverywhere(alt):
        return true
    false
  of nkQuantifier:
    effectiveQuantBounds(node.quantMin, node.quantMax).lo == 0 or
      matchesEverywhere(node.quantBody)
  of nkGroup:
    matchesEverywhere(node.groupBody)
  of nkCapture:
    matchesEverywhere(node.captureBody)
  of nkNamedCapture:
    matchesEverywhere(node.namedCaptureBody)
  of nkAtomicGroup:
    matchesEverywhere(node.atomicBody)
  of nkFlagGroup:
    node.flagBody == nil or matchesEverywhere(node.flagBody)
  else:
    false

proc loopLeafOf(expr: Node): Node =
  ## The leaf under ``expr``'s groups and repeats, or nil.  ``tuneRepeats``
  ## leaves the repeats of an E that is the loop around X as written, so a
  ## string of two or more here means a pass rewrote one.
  var node {.cursor.} = expr
  while node != nil:
    case node.kind
    of nkGroup:
      node = node.groupBody
    of nkAtomicGroup:
      node = node.atomicBody
    of nkQuantifier:
      node = node.quantBody
    of nkString:
      return (if node.runes.len == 1: node else: nil)
    of nkLiteral, nkEscapedLiteral, nkCharClass, nkCharType:
      return node
    else:
      return nil

proc markAbsents*(node: Node) =
  ## Fill in ``absentEmpty`` on every absent function under ``node``, and
  ## ``absentLoopLeaf`` on every absent expression that is the loop around
  ## its pattern.  Must run on the final tree, before anything reads
  ## [lengthBounds]: the compiler's rewrites rebuild nodes and would drop
  ## both.
  if node == nil:
    return
  if node.kind == nkAbsent:
    case node.absentKind
    of abFunction:
      node.absentEmpty = matchesEverywhere(node.absentBody)
    of abExpression:
      if node.absentLoopsOnExpr:
        node.absentLoopLeaf = loopLeafOf(node.absentExpr)
        # Without it the matcher would try X at every character and past
        # E's bound (``findExprAbsentPos``): a pass has rewritten E.
        doAssert node.absentLoopLeaf != nil,
          "a pass rewrote the loop around an absent pattern"
    else:
      discard
  for child in node.childNodes:
    markAbsents(child)

proc isEmptyAbsentFunc*(node: Node): bool {.inline.} =
  ## Whether ``node`` is an absent function whose pattern matches wherever the
  ## function starts -- ``(?~)``, ``(?~a*)``, ``(?~(?:))``.  The longest text
  ## without the pattern is then the empty one, so the function matches
  ## empty, only empty, and leaves the absent range as it found it.  The
  ## pattern is judged by what it matches rather than how it is spelt
  ## ([matchesEverywhere]): any spelling left out would walk a look-behind
  ## back to 0 again (see ``nkAbsent`` in [lengthBounds]).  The verdict is
  ## the one [markAbsents] cached at compile time.
  node.kind == nkAbsent and node.absentEmpty

func followedBy(a, b: LenBounds): LenBounds =
  ## What ``a`` and then ``b`` consume together; -1 where either is, or where
  ## the sum passes ``int.high``.
  LenBounds(
    maxLen:
      if a.maxLen < 0 or b.maxLen < 0 or b.maxLen > int.high - a.maxLen:
        -1
      else:
        a.maxLen + b.maxLen,
    fixedLen:
      if a.fixedLen < 0 or b.fixedLen < 0 or b.fixedLen > int.high - a.fixedLen:
        -1
      else:
        a.fixedLen + b.fixedLen,
  )

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
    var total = LenBounds(maxLen: 0, fixedLen: 0)
    var currentFlags = flags
    var currentGm = gm
    for child in node.children.view:
      # A bare flag group — (?i), (?y{g}) — applies to the rest of the concat
      # rather than to a body of its own.
      if child.kind == nkFlagGroup and child.flagBody == nil:
        currentFlags = currentFlags + child.flagsOn - child.flagsOff
        if child.graphemeMode != gmNone:
          currentGm = child.graphemeMode
        continue
      total = total.followedBy(lengthBounds(child, currentFlags, currentGm))
      if total.maxLen < 0 and total.fixedLen < 0:
        break
    total
  of nkAlternation:
    if node.alternatives.len == 0:
      return LenBounds(maxLen: 0, fixedLen: 0)
    # ``maxLen`` maximizes over the branches while ``fixedLen`` needs them all
    # to agree, so ``fixed`` is seeded from the first branch during the same
    # walk: a second walk would be exponential in the alternation depth.
    var best = 0
    var fixed = 0
    for i, alt in node.alternatives.view:
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
    # Inverted range: use the swapped bounds.
    let (qlo, qhi) = effectiveQuantBounds(node.quantMin, node.quantMax)
    # ``{0,0}`` and repeats of zero-width bodies consume nothing.  A repeat
    # of ``(?~)`` stays variable-length, as the body is (see ``nkAbsent``).
    if qhi == 0:
      return LenBounds(maxLen: 0, fixedLen: 0)
    if bb.maxLen == 0:
      return LenBounds(maxLen: 0, fixedLen: if bb.fixedLen == 0: 0 else: -1)
    var total = -1
    if qhi >= 0 and bb.maxLen >= 0:
      if qhi == 0 or bb.maxLen <= int.high div qhi:
        total = bb.maxLen * qhi
    var fixed = -1
    if qlo == qhi and qlo >= 0 and bb.fixedLen >= 0:
      if qlo == 0 or bb.fixedLen <= int.high div qlo:
        fixed = bb.fixedLen * qlo
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
    # A regex condition consumes what it matched before the yes branch, as
    # ``BAG_IF_ELSE`` does: ``(?(a)|b)`` is one character either way, and
    # ``(?(a)|)`` is not fixed.  The other tests are zero-width.
    let test =
      if node.condKind == ckRegexCond:
        lengthBounds(node.condBody, flags, gm)
      else:
        LenBounds(maxLen: 0, fixedLen: 0)
    let yes = test.followedBy(lengthBounds(node.condYes, flags, gm))
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
      # One branch runs, so equal fixed lengths stay fixed.
      fixedLen:
        if yes.fixedLen >= 0 and yes.fixedLen == no.fixedLen: yes.fixedLen else: -1,
    )
  of nkAbsent:
    # ``abClear`` and ``abRange`` are zero-width; the other two consume subject
    # and stay unbounded.  ``(?~)`` and the other empty absent functions
    # ([isEmptyAbsentFunc]) consume nothing, but do not count as fixed-length:
    # Oniguruma compiles them like any absent function, so a look-behind body
    # holding one runs under a window.  Their ``maxLen`` is still 0, which
    # keeps such a body from trying every start position back to 0.
    if node.isEmptyAbsentFunc:
      return LenBounds(maxLen: 0, fixedLen: -1)
    case node.absentKind
    of abClear, abRange:
      LenBounds(maxLen: 0, fixedLen: 0)
    of abFunction, abExpression:
      LenBounds(maxLen: -1, fixedLen: -1)

proc annotateLookaroundBounds*(node: Node, flags: RegexFlags, gm = gmNone) =
  ## Cache [lengthBounds] of every lookaround body on its node.
  ## Must run on the final AST.
  if node == nil:
    return
  case node.kind
  of nkLookaround:
    node.lookBounds = lengthBounds(node.lookBody, flags, gm)
    node.lookAlts = @[]
    let peeled = peelBareGroups(node.lookBody)
    if peeled != nil and peeled.kind == nkAlternation:
      for alt in peeled.alternatives.view:
        node.lookAlts.add(lengthBounds(alt, flags, gm))
    node.lookBoundsFlags = flags
    node.lookBoundsGm = gm
    node.lookBoundsValid = true
    annotateLookaroundBounds(node.lookBody, flags, gm)
  of nkConcat:
    var currentFlags = flags
    var currentGm = gm
    for child in node.children.view:
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

proc holdsAbsentLoop(node: Node): bool =
  ## Whether ``node`` holds an absent operator other than the range clear
  ## ``(?~|)`` where [lengthBounds] counts what it consumes: outside every
  ## lookaround, every conditional test but a pattern, and every repeat that
  ## runs zero times.
  if node == nil:
    return false
  case node.kind
  of nkAbsent:
    return node.absentKind != abClear
  of nkLookaround:
    return false
  of nkQuantifier:
    if effectiveQuantBounds(node.quantMin, node.quantMax).hi == 0:
      return false
  of nkConditional:
    return
      (node.condKind == ckRegexCond and holdsAbsentLoop(node.condBody)) or
      holdsAbsentLoop(node.condYes) or holdsAbsentLoop(node.condNo)
  else:
    discard
  for child in node.childNodes:
    if holdsAbsentLoop(child):
      return true
  false

proc anchorDMax*(node: Node, flags: RegexFlags): int =
  ## How far left of the ``\Z`` anchor a match of ``node`` may start, as
  ## Oniguruma's ``anchor_dmax`` counts it, or -1 when unbounded.  That is
  ## [maxByteLen] except for the absent operators: Oniguruma compiles every
  ## one but the range clear to a loop, so it counts a pattern holding one as
  ## unbounded even where the operator consumes nothing, as ``(?~)`` and
  ## ``(?~|a)`` do.  The bound decides where the scan jumps to (see
  ## ``semiEndScanStart`` in ``engine``), and on malformed UTF-8 a jump can
  ## land where ``onig_search``'s walk does not: ``(?~)\Z`` on ``"\xC0\n"``
  ## is 2..2 in Oniguruma, and was 1..1 here under a bound of 0.
  if holdsAbsentLoop(node):
    -1
  else:
    maxByteLen(node, flags)

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
    for alt in node.alternatives.view:
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
