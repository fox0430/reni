import std/[unittest, unicode]

import ../reni
import ../reni/types

suite "Step 1: Literals":
  test "single char":
    let r = re("a")
    check r.ast.kind == nkLiteral
    check r.ast.rune == Rune('a')

  test "multi-char literal string":
    let r = re("hello")
    check r.ast.kind == nkString
    check r.ast.runes.len == 5
    check r.ast.runes[0] == Rune('h')
    check r.ast.runes[4] == Rune('o')

  test "empty pattern":
    let r = re("")
    check r.ast.kind == nkConcat
    check r.ast.children.len == 0

  test "unicode literal":
    let r = re("あ")
    check r.ast.kind == nkLiteral
    check r.ast.rune == Rune(0x3042)

suite "Step 2: Alternation and non-capturing groups":
  test "simple alternation":
    let r = re("a|b")
    check r.ast.kind == nkAlternation
    check r.ast.alternatives.len == 2
    check r.ast.alternatives[0].kind == nkLiteral
    check r.ast.alternatives[1].kind == nkLiteral

  test "three-way alternation":
    let r = re("a|b|c")
    check r.ast.kind == nkAlternation
    check r.ast.alternatives.len == 3

  test "non-capturing group":
    let r = re("(?:ab)")
    check r.ast.kind == nkGroup
    check r.ast.groupBody.kind == nkString

  test "alternation in group":
    let r = re("(?:a|b)")
    check r.ast.kind == nkGroup
    check r.ast.groupBody.kind == nkAlternation

  test "capturing group":
    let r = re("(a)")
    check r.ast.kind == nkCapture
    check r.ast.captureIndex == 0
    check r.ast.captureBody.kind == nkLiteral
    check r.captureCount == 1

  test "nested groups":
    let r = re("((a))")
    check r.ast.kind == nkCapture
    check r.ast.captureIndex == 0
    check r.ast.captureBody.kind == nkCapture
    check r.ast.captureBody.captureIndex == 1
    check r.captureCount == 2

  test "unbalanced paren raises":
    expect RegexError:
      discard re("(a")
    expect RegexError:
      discard re("a)")

suite "Step 3: Quantifiers":
  test "star":
    let r = re("a*")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 0
    check r.ast.quantMax == -1
    check r.ast.quantKind == qkGreedy

  test "plus":
    let r = re("a+")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 1
    check r.ast.quantMax == -1

  test "question":
    let r = re("a?")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 0
    check r.ast.quantMax == 1

  test "lazy star":
    let r = re("a*?")
    check r.ast.kind == nkQuantifier
    check r.ast.quantKind == qkLazy

  test "possessive plus":
    let r = re("a++")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 1
    check r.ast.quantMax == -1
    check r.ast.quantKind == qkPossessive

  test "counted {n,m}":
    let r = re("a{2,5}")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 2
    check r.ast.quantMax == 5

  test "counted {n}":
    let r = re("a{3}")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 3
    check r.ast.quantMax == 3

  test "counted {n,}":
    let r = re("a{2,}")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 2
    check r.ast.quantMax == -1

  test "counted {,m}":
    let r = re("a{,5}")
    check r.ast.kind == nkQuantifier
    check r.ast.quantMin == 0
    check r.ast.quantMax == 5

  test "nothing to repeat raises":
    expect RegexError:
      discard re("*")
    expect RegexError:
      discard re("+")

suite "Step 4: Character types and anchors":
  test "dot":
    let r = re(".")
    check r.ast.kind == nkCharType
    check r.ast.charType == ctDot

  test "word type":
    let r = re("\\w")
    check r.ast.kind == nkCharType
    check r.ast.charType == ctWord

  test "digit type":
    let r = re("\\d")
    check r.ast.kind == nkCharType
    check r.ast.charType == ctDigit

  test "space type":
    let r = re("\\s")
    check r.ast.kind == nkCharType
    check r.ast.charType == ctSpace

  test "anchors":
    check re("^").ast.anchor == akLineBegin
    check re("$").ast.anchor == akLineEnd
    check re("\\b").ast.anchor == akWordBoundary
    check re("\\B").ast.anchor == akNotWordBoundary
    check re("\\A").ast.anchor == akStringBegin
    check re("\\z").ast.anchor == akStringEnd
    check re("\\Z").ast.anchor == akStringEndOrNewline
    check re("\\G").ast.anchor == akSearchBegin

suite "Step 5: Escape sequences":
  test "literal escapes":
    check re("\\n").ast.escapedRune == Rune(0x0A)
    check re("\\t").ast.escapedRune == Rune(0x09)
    check re("\\r").ast.escapedRune == Rune(0x0D)

  test "hex escape \\xHH":
    check re("\\x41").ast.escapedRune == Rune(0x41)

  test "hex escape \\x{HHHH}":
    check re("\\x{1F600}").ast.escapedRune == Rune(0x1F600)

  test "unicode escape \\uHHHH":
    check re("\\u0041").ast.escapedRune == Rune(0x41)

  test "octal escape \\0NN":
    check re("\\071").ast.escapedRune == Rune(57) # '9'

  test "control char \\cx":
    check re("\\ca").ast.escapedRune == Rune(1) # control-a

  test "literal escape \\\\":
    check re("\\\\").ast.escapedRune == Rune(ord('\\'))

  test "escaped dot":
    check re("\\.").ast.kind == nkEscapedLiteral
    check re("\\.").ast.escapedRune == Rune(ord('.'))

  test "backreference \\1":
    let r = re("(a)\\1")
    check r.ast.kind == nkConcat
    check r.ast.children[1].kind == nkBackreference
    check r.ast.children[1].backrefIndex == 1

suite "Step 6: Character classes":
  test "simple class [abc]":
    let r = re("[abc]")
    check r.ast.kind == nkCharClass
    check r.ast.negated == false
    check r.ast.atoms.len == 3
    check r.ast.atoms[0].kind == ccLiteral
    check r.ast.atoms[0].rune == Rune('a')
    check r.ast.atoms[2].rune == Rune('c')

  test "negated class [^abc]":
    let r = re("[^abc]")
    check r.ast.kind == nkCharClass
    check r.ast.negated == true
    check r.ast.atoms.len == 3

  test "range [a-z]":
    let r = re("[a-z]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccRange
    check r.ast.atoms[0].rangeFrom == Rune('a')
    check r.ast.atoms[0].rangeTo == Rune('z')

  test "mixed class [a-z0-9_]":
    let r = re("[a-z0-9_]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 3 # range, range, literal
    check r.ast.atoms[0].kind == ccRange
    check r.ast.atoms[1].kind == ccRange
    check r.ast.atoms[2].kind == ccLiteral
    check r.ast.atoms[2].rune == Rune('_')

  test "] as first char is literal":
    let r = re("[]abc]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 4
    check r.ast.atoms[0].kind == ccLiteral
    check r.ast.atoms[0].rune == Rune(']')

  test "] after ^ is literal":
    let r = re("[^]abc]")
    check r.ast.kind == nkCharClass
    check r.ast.negated == true
    check r.ast.atoms[0].rune == Rune(']')

  test "- at end is literal":
    let r = re("[abc-]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 4 # a, b, c, -
    check r.ast.atoms[3].kind == ccLiteral
    check r.ast.atoms[3].rune == Rune('-')

  test "escape in class [\\w\\d]":
    let r = re("[\\w\\d]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 2
    check r.ast.atoms[0].kind == ccCharType
    check r.ast.atoms[0].charType == ctWord
    check r.ast.atoms[1].charType == ctDigit

  test "\\b in class is backspace":
    let r = re("[\\b]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccLiteral
    check r.ast.atoms[0].rune == Rune(0x08)

  test "hex escape in class [\\x41-\\x5A]":
    let r = re("[\\x41-\\x5A]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccRange
    check r.ast.atoms[0].rangeFrom == Rune(0x41)
    check r.ast.atoms[0].rangeTo == Rune(0x5A)

  test "POSIX class [:alpha:]":
    let r = re("[[:alpha:]]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccPosix
    check r.ast.atoms[0].posixClass == pcAlpha

  test "negated POSIX class [:^digit:]":
    let r = re("[[:^digit:]]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccNegPosix
    check r.ast.atoms[0].posixClass == pcDigit

  test "nested class [a-z[0-9]]":
    let r = re("[a-z[0-9]]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 2 # range + nested
    check r.ast.atoms[0].kind == ccRange
    check r.ast.atoms[1].kind == ccNestedClass

  test "escaped literal in class [\\-\\]]":
    let r = re("[\\-\\]]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 2
    check r.ast.atoms[0].rune == Rune('-')
    check r.ast.atoms[1].rune == Rune(']')

  test "unicode in class [あ-ん]":
    let r = re("[あ-ん]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccRange
    check r.ast.atoms[0].rangeFrom == Rune(0x3042) # あ
    check r.ast.atoms[0].rangeTo == Rune(0x3093) # ん

  test "unterminated class raises":
    expect RegexError:
      discard re("[abc")

  test "class in pattern context":
    let r = re("^[a-z]+$")
    check r.ast.kind == nkConcat
    check r.ast.children.len == 3 # ^, [a-z]+, $
    check r.ast.children[1].kind == nkQuantifier
    check r.ast.children[1].quantBody.kind == nkCharClass

  test "intersection [a-z&&[^aeiou]]":
    let r = re("[a-z&&[^aeiou]]")
    check r.ast.kind == nkCharClass
    # && wraps left and right into a single ccIntersection atom
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccIntersection
    # Left side: a-z range
    check r.ast.atoms[0].interLeft.len == 1
    check r.ast.atoms[0].interLeft[0].kind == ccRange
    # Right side: [^aeiou] parsed via parseCharClassBody, negation captured there
    check r.ast.atoms[0].interRightNeg == false
    check r.ast.atoms[0].interRight.len == 1
    check r.ast.atoms[0].interRight[0].kind == ccNestedClass
    check r.ast.atoms[0].interRight[0].nestedNegated == true
    check r.ast.atoms[0].interRight[0].nestedAtoms.len == 5

  test "unicode property in class [\\p{L}]":
    let r = re("[\\p{L}]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccUnicodeProp
    check r.ast.atoms[0].propName == "L"

  test "negated unicode property [\\P{Cc}]":
    let r = re("[\\P{Cc}]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms[0].kind == ccNegUnicodeProp
    check r.ast.atoms[0].propName == "Cc"

suite "Step 7: Named captures and backreferences":
  test "named capture (?<name>...)":
    let r = re("(?<foo>a)")
    check r.ast.kind == nkNamedCapture
    check r.ast.captureName == "foo"
    check r.ast.namedCaptureIndex == 0
    check r.ast.namedCaptureBody.kind == nkLiteral
    check r.captureCount == 1
    check r.namedCaptures.len == 1
    check r.namedCaptures[0] == ("foo", 0)

  test "named capture (?'name'...)":
    let r = re("(?'bar'b)")
    check r.ast.kind == nkNamedCapture
    check r.ast.captureName == "bar"
    check r.ast.namedCaptureIndex == 0
    check r.captureCount == 1

  test "mixed captures":
    # When named captures exist, unnamed captures are demoted to non-capturing groups
    # (Oniguruma default behavior)
    let r = re("(a)(?<x>b)(c)")
    check r.ast.kind == nkConcat
    check r.ast.children[0].kind == nkGroup
    check r.ast.children[0].groupBody.kind == nkLiteral
    check r.ast.children[1].kind == nkNamedCapture
    check r.ast.children[1].captureName == "x"
    check r.ast.children[1].namedCaptureIndex == 0
    check r.ast.children[2].kind == nkGroup
    check r.ast.children[2].groupBody.kind == nkLiteral
    check r.captureCount == 1

  test "named backreference \\k<name>":
    let r = re("(?<foo>a)\\k<foo>")
    check r.ast.kind == nkConcat
    check r.ast.children[1].kind == nkNamedBackref
    check r.ast.children[1].backrefName == "foo"

  test "named backreference \\k'name'":
    let r = re("(?'foo'a)\\k'foo'")
    check r.ast.kind == nkConcat
    check r.ast.children[1].kind == nkNamedBackref
    check r.ast.children[1].backrefName == "foo"

  test "backreference \\1":
    let r = re("(a)\\1")
    check r.ast.kind == nkConcat
    check r.ast.children[1].kind == nkBackreference
    check r.ast.children[1].backrefIndex == 1

  test "numbered backref with named capture raises":
    # Oniguruma: "numbered backref/call is not allowed. (use name)"
    expect RegexError:
      discard re("(a)(?<x>b)\\1")
    expect RegexError:
      discard re("(a)(?<x>b)\\2")

  test "\\k<number> with named capture raises":
    expect RegexError:
      discard re("(a)(?<x>b)\\k<1>")
    expect RegexError:
      discard re("(a)(?<x>b)\\k<2>")

  test "numbered subroutine call with named capture raises":
    expect RegexError:
      discard re("(a)(?<x>b)(?1)")
    expect RegexError:
      discard re("(a)(?<x>b)\\g<1>")

  test "(?R) / \\g<0> with named capture raises":
    expect RegexError:
      discard re("(?<x>a)(?R)")
    expect RegexError:
      discard re("(?<x>a)\\g<0>")

  test "numbered conditional with named capture raises":
    expect RegexError:
      discard re("(a)(?<x>b)(?(1)c|d)")

  test "named refs with named capture still work":
    discard re("(?<x>a)\\k<x>")
    discard re("(?<x>a)\\g<x>")
    discard re("(?<x>a)(?&x)")

  test "numbered backref without named capture still works":
    let r = re("(a)\\1")
    check r.ast.children[1].kind == nkBackreference

  test "named conditional with named capture still works":
    discard re("(a)(?<x>b)(?(<x>)c|d)")

suite "Step 8: Lookaround":
  test "positive lookahead (?=...)":
    let r = re("a(?=b)")
    check r.ast.kind == nkConcat
    check r.ast.children[1].kind == nkLookaround
    check r.ast.children[1].lookKind == lkAhead
    check r.ast.children[1].lookBody.kind == nkLiteral

  test "negative lookahead (?!...)":
    let r = re("a(?!b)")
    check r.ast.kind == nkConcat
    check r.ast.children[1].kind == nkLookaround
    check r.ast.children[1].lookKind == lkNegAhead

  test "positive lookbehind (?<=...)":
    let r = re("(?<=a)b")
    check r.ast.kind == nkConcat
    check r.ast.children[0].kind == nkLookaround
    check r.ast.children[0].lookKind == lkBehind
    check r.ast.children[0].lookBody.kind == nkLiteral

  test "negative lookbehind (?<!...)":
    let r = re("(?<!a)b")
    check r.ast.kind == nkConcat
    check r.ast.children[0].kind == nkLookaround
    check r.ast.children[0].lookKind == lkNegBehind

  test "?< disambiguation: (?<=) vs (?<name>)":
    let r1 = re("(?<=x)y")
    check r1.ast.children[0].kind == nkLookaround
    check r1.ast.children[0].lookKind == lkBehind
    let r2 = re("(?<name>x)")
    check r2.ast.kind == nkNamedCapture
    check r2.ast.captureName == "name"

  test "nested lookaround":
    let r = re("(?=(?<=a)b)")
    check r.ast.kind == nkLookaround
    check r.ast.lookKind == lkAhead
    check r.ast.lookBody.kind == nkConcat

  test "atomic group (?>...)":
    let r = re("(?>a+)")
    check r.ast.kind == nkAtomicGroup
    check r.ast.atomicBody.kind == nkQuantifier

suite "Step 9: Inline flags":
  test "scoped flag group (?i:...)":
    let r = re("(?i:abc)")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagsOn == {rfIgnoreCase}
    check r.ast.flagsOff == {}
    check r.ast.flagBody != nil
    check r.ast.flagBody.kind == nkString

  test "multiple flags (?im:...)":
    let r = re("(?im:abc)")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagsOn == {rfIgnoreCase, rfMultiLine}
    check r.ast.flagBody != nil

  test "flag negation (?-i:...)":
    let r = re("(?-i:abc)")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagsOn == {}
    check r.ast.flagsOff == {rfIgnoreCase}

  test "mixed flag on/off (?im-x:...)":
    let r = re("(?im-x:abc)")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagsOn == {rfIgnoreCase, rfMultiLine}
    check r.ast.flagsOff == {rfExtended}

  test "isolated flags (?i)":
    let r = re("(?i)abc")
    # Isolated (?i) wraps the rest as flagBody
    check r.ast.kind == nkFlagGroup
    check r.ast.flagsOn == {rfIgnoreCase}
    check r.ast.flagBody != nil
    check r.ast.flagBody.kind == nkString
    check r.ast.flagBody.runes.len == 3

  test "extended mode skips whitespace":
    let r = re("(?x: a b c )")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagBody.kind == nkString
    check r.ast.flagBody.runes.len == 3

  test "extended mode skips comments":
    let r = re("(?x: a # comment\n b )")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagBody.kind == nkString
    check r.ast.flagBody.runes.len == 2

  test "extended mode with quantifier":
    let r = re("(?x: a + )")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagBody.kind == nkQuantifier
    check r.ast.flagBody.quantMin == 1

  test "extended mode does not affect char class":
    # Spaces inside [...] should NOT be skipped even in extended mode
    let r = re("(?x:[ ])")
    check r.ast.kind == nkFlagGroup
    check r.ast.flagBody.kind == nkCharClass
    check r.ast.flagBody.atoms.len == 1
    check r.ast.flagBody.atoms[0].rune == Rune(' ')

  test "comment group (?#...)":
    let r = re("a(?#comment)b")
    check r.ast.kind == nkString
    check r.ast.runes.len == 2
    check r.ast.runes[0] == Rune('a')
    check r.ast.runes[1] == Rune('b')

  test "flag passed via re() API":
    let r = re("a b", {rfExtended})
    check r.ast.kind == nkString
    check r.ast.runes.len == 2

suite "Step 10: Unicode properties and remaining features":
  test "\\p{L} unicode property":
    let r = re("\\p{L}")
    check r.ast.kind == nkCharClass
    check r.ast.negated == false
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccUnicodeProp
    check r.ast.atoms[0].propName == "L"

  test "\\P{Cc} negated unicode property":
    let r = re("\\P{Cc}")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccNegUnicodeProp
    check r.ast.atoms[0].propName == "Cc"

  test "\\p{Print} long property name":
    let r = re("\\p{Print}")
    check r.ast.atoms[0].propName == "Print"

  test "\\pL single-letter shorthand":
    let r = re("\\pL")
    check r.ast.kind == nkCharClass
    check r.ast.atoms[0].kind == ccUnicodeProp
    check r.ast.atoms[0].propName == "L"

  test "\\PL single-letter negated shorthand":
    let r = re("\\PL")
    check r.ast.kind == nkCharClass
    check r.ast.atoms[0].kind == ccNegUnicodeProp
    check r.ast.atoms[0].propName == "L"

  test "\\p{} empty property raises":
    expect RegexError:
      discard re("\\p{}")

  test "\\h hex digit type":
    let r = re("\\h")
    check r.ast.kind == nkCharType
    check r.ast.charType == ctHexDigit

  test "\\H not hex digit type":
    let r = re("\\H")
    check r.ast.kind == nkCharType
    check r.ast.charType == ctNotHexDigit

  test "atomic group (?>...)":
    let r = re("(?>a+)b")
    check r.ast.kind == nkConcat
    check r.ast.children[0].kind == nkAtomicGroup
    check r.ast.children[0].atomicBody.kind == nkQuantifier

  test "comment group (?#...) is ignored":
    let r = re("a(?#this is a comment)b")
    check r.ast.kind == nkString
    check r.ast.runes.len == 2
    check r.ast.runes[0] == Rune('a')
    check r.ast.runes[1] == Rune('b')

  test "\\K keep anchor":
    let r = re("\\K")
    check r.ast.kind == nkAnchor
    check r.ast.anchor == akKeep

  test "unicode property in context":
    let r = re("\\p{L}+")
    check r.ast.kind == nkQuantifier
    check r.ast.quantBody.kind == nkCharClass
    check r.ast.quantBody.atoms[0].kind == ccUnicodeProp

suite "Bug fixes and validation":
  test "isolated flag scoped to enclosing group (#1)":
    # (?i) inside a group must NOT leak to outside
    # ((?i)abc)def — only abc should be under (?i), not def
    let r = re("((?i)abc)def")
    check r.ast.kind == nkConcat
    let grp = r.ast.children[0]
    check grp.kind == nkCapture
    # Inside the group: isolated (?i) wraps abc as flagBody
    let body = grp.captureBody
    check body.kind == nkFlagGroup
    check body.flagsOn == {rfIgnoreCase}
    check body.flagBody != nil
    check body.flagBody.kind == nkString
    check body.flagBody.runes.len == 3
    # def is outside the group — should be merged into nkString
    check r.ast.children[1].kind == nkString
    check r.ast.children[1].runes == @[Rune('d'), Rune('e'), Rune('f')]

  test "isolated flag in non-capturing group scoped (#1)":
    # (?:(?i)abc)def — (?i) should not leak
    let r = re("(?:(?i)abc)def")
    check r.ast.kind == nkConcat
    check r.ast.children[0].kind == nkGroup

  test "extended mode isolated does not leak (#1)":
    # ((?x) a b )cd — spaces skipped inside group only
    # After group closes, 'c' 'd' should be normal literals
    let r = re("((?x) a b )cd")
    check r.ast.kind == nkConcat
    let grp = r.ast.children[0]
    check grp.kind == nkCapture
    # Inside: isolated (?x) wraps a + b as flagBody (spaces skipped)
    let body = grp.captureBody
    check body.kind == nkFlagGroup
    check body.flagsOn == {rfExtended}
    check body.flagBody != nil
    check body.flagBody.kind == nkString
    check body.flagBody.runes.len == 2 # a, b
    # Outside: c, d merged into nkString (not extended mode)
    check r.ast.children[1].kind == nkString
    check r.ast.children[1].runes == @[Rune('c'), Rune('d')]

  test "reversed range [z-a] raises (#6)":
    expect RegexError:
      discard re("[z-a]")

  test "valid range [a-z] accepted (#6)":
    let r = re("[a-z]")
    check r.ast.atoms[0].kind == ccRange

  test "empty backreference name \\k<> raises (#7)":
    expect RegexError:
      discard re("\\k<>")

  test "empty backreference name \\k'' raises (#7)":
    expect RegexError:
      discard re("\\k''")

  test "empty unicode property [\\p{}] raises (#8)":
    expect RegexError:
      discard re("[\\p{}]")

  test "extremely large quantifier raises error":
    expect RegexError:
      discard re("a{99999999999999999999}")

  test "large quantifier max value raises error":
    expect RegexError:
      discard re("a{100001}")

  test "large quantifier second number raises error":
    expect RegexError:
      discard re("a{1,99999999999999999999}")

  test "octal escape at max codepoint \\o{4177777} succeeds":
    let r = re("\\o{4177777}")
    check r.ast.kind == nkEscapedLiteral

  test "octal escape beyond max codepoint \\o{4200000} raises error":
    expect RegexError:
      discard re("\\o{4200000}")

  test "very long octal string raises error":
    expect RegexError:
      discard re("\\o{77777777777777777777}")

  test "octal escape beyond max in character class raises error":
    expect RegexError:
      discard re("[\\o{4200000}]")

suite "Relative and numeric reference bounds":
  test "\\k<-n> out of range raises":
    expect RegexError:
      discard re("\\k<-1>")
    expect RegexError:
      discard re("(a)\\k<-2>")

  test "\\g<-n> out of range raises":
    expect RegexError:
      discard re("(a)\\g<-2>")
    expect RegexError:
      discard re("\\g<-1>")

  test "(?-n) out of range raises":
    expect RegexError:
      discard re("(a)(?-2)")
    expect RegexError:
      discard re("(?-1)")

  test "(?+n) forward reference beyond group count raises":
    expect RegexError:
      discard re("(a)(?+5)")

  test "\\g<+n> forward reference beyond group count raises":
    expect RegexError:
      discard re("(a)\\g<+5>")

  test "\\k<-1> valid within range":
    let r = re("(a)\\k<-1>")
    check r.ast.kind == nkConcat

  test "\\g<0> whole-pattern recursion is valid":
    let r = re("a(?:\\g<0>)?b")
    check r.ast.kind == nkConcat

  test "(?(-n)...) out-of-range conditional raises":
    expect RegexError:
      discard re("(a)(?(-2)yes|no)")
    expect RegexError:
      discard re("(?(-5)yes|no)")

  test "numeric backref beyond capture count raises":
    expect RegexError:
      discard re("(a)\\2")

  test "(?N) numeric subexp call beyond range raises":
    expect RegexError:
      discard re("(a)(?5)")

  test "undefined \\g<name> raises":
    expect RegexError:
      discard re("\\g<foo>")

  test "undefined \\k<name> raises":
    expect RegexError:
      discard re("\\k<foo>")
