import std/[unittest, unicode, strutils]

import ../reni
import ../reni/types
import ../reni/unicode_utils
import ./helpers

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
    # An exact count over a literal is written out, as Oniguruma writes it
    # out, so the compiled shape is the string and not the repeat.
    let r = re("a{3}")
    check r.ast.kind == nkString
    check r.ast.bytes == "aaa"
    let c = re("[a]{3}")
    check c.ast.kind == nkQuantifier
    check c.ast.quantMin == 3
    check c.ast.quantMax == 3

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
    check re("\\\\").ast.rune == Rune(ord('\\'))

  test "escaped dot":
    # Escaped as itself, it is the plain character, as Oniguruma reads it.
    check re("\\.").ast.kind == nkLiteral
    check re("\\.").ast.rune == Rune(ord('.'))

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
    check r.ast.atoms[0].prop == resolveUnicodeProp("L")

  test "negated unicode property [\\P{Cc}]":
    let r = re("[\\P{Cc}]")
    check r.ast.kind == nkCharClass
    check r.ast.atoms[0].kind == ccNegUnicodeProp
    check r.ast.atoms[0].prop == resolveUnicodeProp("Cc")

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
    # ``flattenLiteralGroups`` would drop a group around nothing but
    # literals, but it runs before this demotion, so these two survive it.
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

  test "group name starting with a digit or sign raises":
    # Oniguruma: "invalid group name <2>"
    for pat in [
      "(?<2>a)", "(?<01>a)", "(?<1a>a)", "(?<-a>a)", "(?<+a>a)", "(?<-1>a)", "(?'2'a)",
      "(?P<2>a)",
    ]:
      expect RegexError:
        discard re(pat)

  test "group name starting with a non-word character raises":
    # Oniguruma: "invalid char in group name <.a>"
    for pat in ["(?<.a>a)", "(?< a>a)", "(?<·a>a)"]:
      expect RegexError:
        discard re(pat)

  test "group name starting with any other word character is accepted":
    # Only the first character is checked, as in Oniguruma.
    for pat in [
      "(?<a1>a)", "(?<_>a)", "(?<_1>a)", "(?<é>a)", "(?<あ>a)", "(?<٣>a)",
      "(?<²a>a)", "(?<a b>a)", "(?<a-b>a)", "(?<a >a)",
    ]:
      discard re(pat)

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
    check r.ast.atoms[0].prop == resolveUnicodeProp("L")

  test "\\P{Cc} negated unicode property":
    let r = re("\\P{Cc}")
    check r.ast.kind == nkCharClass
    check r.ast.atoms.len == 1
    check r.ast.atoms[0].kind == ccNegUnicodeProp
    check r.ast.atoms[0].prop == resolveUnicodeProp("Cc")

  test "\\p{Print} long property name":
    let r = re("\\p{Print}")
    check r.ast.atoms[0].prop == resolveUnicodeProp("Print")

  test "\\pL single-letter shorthand":
    let r = re("\\pL")
    check r.ast.kind == nkCharClass
    check r.ast.atoms[0].kind == ccUnicodeProp
    check r.ast.atoms[0].prop == resolveUnicodeProp("L")

  test "\\PL single-letter negated shorthand":
    let r = re("\\PL")
    check r.ast.kind == nkCharClass
    check r.ast.atoms[0].kind == ccNegUnicodeProp
    check r.ast.atoms[0].prop == resolveUnicodeProp("L")

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

  test "a comment ends at its own close paren":
    # As in Oniguruma, a backslash escapes the character after it, and a
    # pattern that ends inside a comment is an error (-118).
    check search("ab", re("a(?#x\\)y)b")).matchSpan == 0 .. 2
    for pattern in ["a(?#xyz", "(?#", "a*(?#x", "a(?#\\"]:
      check compileError(pattern).startsWith("expected ')'")

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

  test "a repeat of a repeat counts toward the nesting cap":
    # A repeat is no level, but a repeat of one is: ``a{1}{1}`` nests a repeat
    # in a repeat, one level of the tree as a group is.  Oniguruma counts
    # every repeat toward its larger parse depth limit instead, half what a
    # group costs it, and gives up on 30,000 of them as well.
    check search("a", re("a" & "{1}".repeat(257))).matchSpan == 0 .. 1
    check compileError("a" & "{1}".repeat(258)) == "nesting too deep at position 775"
    # ``(?x)`` nests the rest a level down, so the 257th repeat is too deep,
    # and the position is where it ends, not past the space after it.
    check compileError("(?x)a" & " {1}".repeat(258)) ==
      "nesting too deep at position 1033"
    # A group with no body is no deeper than an atom.
    check compileError("(*FAIL)" & "{1}".repeat(257) & "|a") == ""
    check compileError("(*FAIL)" & "{1}".repeat(258) & "|a").startsWith(
      "nesting too deep"
    )
    # After a comment or ``\Q\E``, a repeat goes to the atom before, and nests.
    check compileError("a" & "(?#)*".repeat(300)).startsWith("nesting too deep")
    check compileError("a" & "\\Q\\E*".repeat(300)).startsWith("nesting too deep")
    # An empty node is no level, so a group holding only one nests no deeper
    # for the atom before the group.
    let deep = "a" & "{1}".repeat(250)
    for empty in ["\\E", "\\Q\\E", "(?)"]:
      check compileError(deep & "(?:" & empty & ")" & "{1}".repeat(10)) == ""
    # Nor does it drop the deeper level of an atom before it in the group, so
    # the repeats after the group still count from there.
    let inner = "(?:a" & "{1}".repeat(255) & ")"
    for empty in ["\\E", "\\Q\\E", "(?)"]:
      let pattern = "(?:" & inner & "b" & empty & ")" & "{1}".repeat(255)
      check compileError(pattern).startsWith("nesting too deep")
    # One repeat on each group adds nothing to the groups' own levels, where
    # counting every repeat would make these 150 groups 301 levels.  A setjmp
    # build runs out of stack budget before that (see test_stack_budget).
    when not compileOption("exceptions", "setjmp"):
      check compileError("(?:".repeat(150) & "a*" & ")*".repeat(150)) == ""

  test "a comment or an empty node parts no chain of repeats":
    # Oniguruma's tokenizer skips a comment, so the repeats on both sides of
    # one chain as in ``a*{2}``.  ``\E`` is nothing outside \Q...\E either.
    check search("aa{2}", re("a(?#)*{2}")).matchSpan == 0 .. 2
    check search("aa", re("a(?#)**")).matchSpan == 0 .. 2
    check search("aaa{2}", re("a\\E*{2}")).matchSpan == 0 .. 3
    check search("aa", re("a\\E(?#)*")).matchSpan == 0 .. 2
    # Inside \Q...\E a comment is text, and so is the repeat after it.
    check search("a(?#)*", re("\\Qa(?#)*\\E")).matchSpan == 0 .. 6

  test "the repeats of a group nest below the deepest level inside it":
    # They come after the group has closed: here 2 groups and 199 nested
    # repeats inside, and 199 or 49 more outside.  That bounds the depth of
    # the tree, and is reni's rule: Oniguruma counts the repeats after a group
    # from the group's own level, whatever nests inside it.
    let inner = "(?:a" & "{1}".repeat(200) & ")"
    check compileError("(?:" & inner & "{1}".repeat(200) & ")").startsWith(
      "nesting too deep"
    )
    check search("a", re("(?:" & inner & "{1}".repeat(50) & ")")).found

  test "an isolated flag group nests the rest of its group":
    # ``(?i)(?i)a`` nests as ``(?i:(?i:a))`` does, in Oniguruma too.
    check search("A", re("(?i)".repeat(256) & "a")).found
    check compileError("(?i)".repeat(257) & "a").startsWith("nesting too deep")

  test "a repeat after a group of characters under {1} takes the last one":
    # Oniguruma drops ``{1}`` and the ``(?:...)`` with it, so the next repeat
    # meets the bare characters and takes the last alone, as after ``ab``.
    check search("xa", re("x(?:ab){1}?")).matchSpan == 0 .. 2
    check search("abbb", re("(?:ab){1}+")).matchSpan == 0 .. 4
    check search("abcc", re("(?:abc){1}{2}")).matchSpan == 0 .. 4
    check search("a", re("(?:(?:ab){1}){1}?")).matchSpan == 0 .. 1
    check search("a", re("(?:ab){1}(?#c)?")).matchSpan == 0 .. 1
    check search("a", re("(?:a\\.){1}?")).matchSpan == 0 .. 1
    # ``\p`` with no property after it is the letter, as ``\.`` is the dot.
    check search("ap", re("(?:a\\pb){1}?")).matchSpan == 0 .. 2
    # A ``{1}`` on the last character drops as the one around the group does
    # and leaves the string whole; one before the last ends the string.
    check search("abb", re("(?:ab{1}){1}{2}")).matchSpan == 0 .. 3
    check search("a", re("(?:\\Qab\\E{1}){1}?")).matchSpan == 0 .. 1
    check search("a", re("(?:a{1}b){1}?")).matchSpan == 0 .. 0
    # Not without the ``{1}``, nor when a code, a group or a capture is there:
    # those are no one string to it.
    check search("x", re("x(?:ab)?")).matchSpan == 0 .. 1
    check search("a", re("(?:a\\tb){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:a(?:b)){1}?")).matchSpan == 0 .. 0
    check search("a", re("(ab){1}?")).matchSpan == 0 .. 0
    # ``\M-x`` is a code to Oniguruma, which reni reads as the letter M.
    check search("M", re("(?:\\M-ab){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:a\\M-b){1}?")).matchSpan == 0 .. 0
    # A ``\Q...\E`` quote is a string of its own: alone it splits, and with
    # anything around it the run is two strings.
    check search("a", re("(?:\\Qab\\E){1}?")).matchSpan == 0 .. 1
    check search("a", re("(?:a\\Qb\\E){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:\\Qa\\Eb){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:\\Qa\\E\\Qb\\E){1}?")).matchSpan == 0 .. 0
    # An empty one is an empty string, and Oniguruma reads a bare ``\E`` as
    # E: the characters around either are no one string, even when the group
    # holds nothing else.
    check search("a", re("(?:ab\\Q\\E){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:a\\Q\\Eb){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:\\Q\\Eab){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:\\Qab\\E\\Q\\E){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:(?:ab){1}\\Q\\E){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:(?:ab\\Q\\E){1}){1}?")).matchSpan == 0 .. 0
    check search("a", re("(?:a\\Eb){1}?")).matchSpan == 0 .. 0
    # A repeat after either goes to the atom before it, whole.  Oniguruma
    # gives it to the empty string or the E, and splits nothing either.
    check search("xa", re("x(?:ab){1}\\Q\\E?")).matchSpan == 0 .. 1
    check search("xa", re("x(?:ab){1}\\E?")).matchSpan == 0 .. 1

  test "a repeat that splits a run of characters still nests a level":
    # As the dropped ``{1}`` counts toward Oniguruma's parse depth, and as
    # ``(?:a){1}?`` counts here.  A setjmp build runs out of stack budget
    # before 255 groups (see test_stack_budget).
    when not compileOption("exceptions", "setjmp"):
      for inner in ["(?:ab){1}?", "(?:a){1}?"]:
        check compileError("(?:".repeat(254) & inner & ")".repeat(254)) == ""
        check compileError("(?:".repeat(255) & inner & ")".repeat(255)).startsWith(
          "nesting too deep"
        )

  test "a condition number past 32 bits is a pattern":
    # Oniguruma's ``scan_number`` gives up past ``high(int32)``, and the
    # condition is then read as a pattern, as ``(?(1a)`` is.
    check search("b", re("(a)?(?(4294967297)a|b)")).matchSpan == 0 .. 1
    check search("2147483648a", re("(?(2147483648)a|b)")).matchSpan == 0 .. 11
    check search("b", re("(?(-2147483648)a|b)")).matchSpan == 0 .. 1
    check search("b", re("(a)?(?(1+2147483648)a|b)")).matchSpan == 0 .. 1
    check compileError("(?(2147483647)a|b)").startsWith(
      "invalid conditional group reference"
    )
    check compileError("(a)(?(+2147483647)a|b)").startsWith(
      "invalid conditional group reference"
    )

  test "an error in a condition gives its position in the pattern":
    # The condition is parsed in place, up to the ``)`` that closes it, so a
    # ``)`` in a class or after a backslash does not end it.
    for (pattern, msg) in [
      ("x(?([a)b)", "unterminated character class at position 9"),
      ("x(?(a\\)b)", "expected ')' at position 9"),
      ("x(?(a(?(?=b)c)", "expected ')' at position 14"),
    ]:
      check compileError(pattern) == msg

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

  test "\\k<+0>, \\k<-0> and numbers past 32 bits are names no group has":
    # Oniguruma's -215 and -200; ``\k<+0>`` read the last group before.
    for pattern in [
      "(a)\\k<+0>", "(a)\\k<-0>", "(a)\\k<2147483648>", "(?<n>a)\\k<n+2147483648>"
    ]:
      expect RegexError:
        discard re(pattern)

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

suite "resolved \\p{...} property matching":
  test "\\p{ascii} rejects out-of-range runes":
    let p = resolveUnicodeProp("ascii")
    check matchUnicodeProp(Rune(0), p)
    check matchUnicodeProp(Rune(127), p)
    check not matchUnicodeProp(Rune(128), p)
    # Must agree with matchPosixClass, which the rfAsciiPosix path uses.
    for cp in [int32(-1), int32(-128), low(int32)]:
      check not matchUnicodeProp(Rune(cp), p)
      check not matchPosixClass(Rune(cp), pcAscii, true)

suite "(?I) and (?L) may only open a pattern":
  # Oniguruma treats ignore-case-ASCII and find-longest as options of the whole
  # match, not of a position in it.  It takes them in one group at the very
  # start of the pattern and nowhere else, and never lets them be cleared.
  #
  # "The start" is the run of wrappers the pattern opens with, and only
  # ``(?:...)`` and ``(?flags:...)`` belong to it: a capture, a lookaround, an
  # atomic group, an isolated ``(?flags)`` or any content at all ends it.  Every
  # expectation below is Oniguruma 6.9.10's answer through ``onig_new`` under
  # ``ONIG_SYNTAX_ONIGURUMA``.

  proc accepts(pattern: string): bool =
    try:
      discard re(pattern)
      true
    except RegexError:
      false

  test "a group that opens the pattern is taken":
    check accepts("(?I)a")
    check accepts("(?L)a")
    check accepts("(?iI)a")
    check accepts("(?Ii)a")
    check accepts("(?IL)a")
    check accepts("(?iIL)a")
    check accepts("(?I)")
    check accepts("(?I)a|b")
    check accepts("(?I)|b")
    check accepts("(?I)(?i)a")
    check accepts("(?I)(?W)a")
    check accepts("(?I)[a]")

  test "only (?:...) and (?flags:...) keep the pattern open":
    check accepts("(?:(?I)a)")
    check accepts("(?i:(?I)a)")
    check accepts("(?W:(?I)a)")
    check accepts("(?:(?:(?I)a))")
    check accepts("(?:(?i:(?I)a))")
    check accepts("(?W:(?:(?I)a))")
    # A leading comment is transparent -- it neither opens nor ends the run.
    check accepts("(?#c)(?I)a")
    # Anything else ends it.
    check not accepts("((?I)a)")
    check not accepts("(?<n>(?I)a)")
    check not accepts("(?>(?I)a)")
    check not accepts("(?=(?I)a)")
    check not accepts("(?<=a)(?I)b")
    check not accepts("(?!a)(?I)b")

  test "content or an isolated (?flags) ends it":
    check not accepts("a(?I)b")
    check not accepts("[a](?I)b")
    check not accepts("a|(?I)b")
    check not accepts("(?:a(?I)b)")
    check not accepts("(?:(?:a(?I)b))")
    check not accepts("(?i)(?I)a")
    check not accepts("(?m)(?I)a")
    check not accepts("(?x)(?I)a")
    check not accepts("(?-i)(?I)a")
    check not accepts("(?W)(?I)a")
    check not accepts("(?i)(?W)(?I)a")
    check not accepts("(?:)(?I)a")
    check not accepts("(?i:)(?I)a")
    check not accepts("(?i)(?L)a")

  test "one such group is all a pattern gets":
    check not accepts("(?I)(?I)a")
    check not accepts("(?L)(?L)a")
    check not accepts("(?I)(?L)a")
    check not accepts("(?L)(?I)a")
    check not accepts("(?iI)(?I)a")
    check not accepts("(?I)(?I:a)")
    # Even where the second one would otherwise still be opening the pattern.
    check not accepts("(?I:(?I)a)")
    check not accepts("(?I:(?I:a))")
    check not accepts("(?I:(?L:a))")
    check not accepts("(?L:(?I:a))")
    check not accepts("(?iI:(?L:a))")

  test "the scoped form has to span the pattern":
    check accepts("(?I:a)")
    check accepts("(?I:a|b)")
    check accepts("(?:(?I:a))")
    check accepts("(?i:(?I:a))")
    check accepts("(?:(?:(?I:a)))")
    check accepts("(?L:a)")
    check accepts("(?L:a|b)")
    check accepts("(?:(?L:a))")
    check accepts("(?i:(?L:a))")
    check accepts("(?:(?:(?L:a)))")
    # A sibling after it, or an alternation around it, is not allowed -- unlike
    # the isolated form, which wraps whatever follows.
    check not accepts("(?I:a)b")
    check not accepts("(?L:a)b")
    check not accepts("(?iI:a)b")
    check not accepts("(?I:a)|b")
    check not accepts("(?L:a)|b")
    check not accepts("b|(?I:a)")
    check not accepts("(?:(?I:a)b)")
    check not accepts("a(?I:b)")
    check not accepts("((?I:a))")

  test "a quantified exclusive group is rejected":
    # A quantifier on the exclusive group (or on transparent wrappers around
    # it) stops it from spanning the pattern, so Oniguruma rejects it. A
    # quantifier *inside* its body -- or inside the isolated form's span --
    # is fine. Nested inside ``(?flags:...)`` the outer group masks the
    # quantifier, so Oniguruma takes ``(?i:(?I:a)+)``.
    check not accepts("(?I:a)+")
    check not accepts("(?I:a)*")
    check not accepts("(?I:a)?")
    check not accepts("(?I:a){2}")
    check not accepts("(?L:a)+")
    check not accepts("(?I)+")
    check not accepts("(?L)+")
    check not accepts("(?:(?I:a))+")
    check not accepts("(?:(?I:a))*")
    check not accepts("(?:(?I:a))?")
    check not accepts("(?:(?I:a)+)")
    check not accepts("(?:(?I)a)+")
    check not accepts("(?:(?I)ab)+")
    check not accepts("(?i:(?I:a))+")
    check not accepts("(?I:a)+b")
    check not accepts("(?I-i:a)+")
    # Controls: quantifiers inside the span are fine, as is the masked form.
    check accepts("(?I:a+)")
    check accepts("(?I:ab+)")
    check accepts("(?I:(?:a)+)")
    check accepts("(?I)a+")
    check accepts("(?I)ab+")
    check accepts("(?:(?I:a+))")
    check accepts("(?i:(?I:a)+)")

  test "an isolated flag group after an exclusive group is rejected":
    # An isolated ``(?flags)`` still counts as a sibling of what precedes it,
    # even though it wraps the rest -- unlike content inside the isolated
    # group's own span, which is fine.
    check not accepts("(?I:a)(?i)")
    check not accepts("(?L:a)(?i)")
    check not accepts("(?I:a)(?m)")
    check not accepts("(?I:a)(?W)")
    check not accepts("(?I:a)(?i)a")
    check not accepts("(?:(?I:a))(?i)")
    check not accepts("(?:(?I)ab)(?i)")
    # Controls: wrapping the rest from the exclusive group itself is fine,
    # and comments are not siblings.
    check accepts("(?I)(?i)a")
    check accepts("(?I:a)(?#c)")

  test "scoped mixed flags still have to span the pattern":
    # Turning another flag off alongside is fine, but the scoped mixed form
    # still has to span the pattern just like the plain scoped form.
    check accepts("(?I-i:a)")
    check accepts("(?L-i:a)")
    check accepts("(?iI-x:a)")
    check accepts("(?:(?I-i:a))")
    check not accepts("(?I-i:a)b")
    check not accepts("(?L-i:a)b")
    check not accepts("(?I-i:a)|b")
    check not accepts("(?L-i:a)|b")
    check not accepts("b|(?I-i:a)")
    check not accepts("(?:(?I-i:a)b)")

  test "the isolated form may not have siblings outside its wrappers":
    # The isolated form wraps the rest of its own group, so content after it
    # inside that group is fine -- but the wrappers around it must hold
    # nothing else, in either direction.
    check accepts("(?I)ab")
    check accepts("(?I)a|b")
    check accepts("(?I)(?:a)b")
    check accepts("(?:(?I)ab)")
    check accepts("(?:(?:(?I)a))")
    check not accepts("(?:(?I)a)b")
    check not accepts("(?:(?L)a)b")
    check not accepts("(?:(?I)a)|b")
    check not accepts("(?:(?I)a)(?:b)")
    check not accepts("(?:(?I)a)+b")
    check not accepts("(?i:(?I)a)b")
    check not accepts("(?W:(?I)a)b")
    check not accepts("(?:(?:(?I)a))b")
    # An empty body is no different.
    check not accepts("(?:(?I))b")
    # A sibling before the wrapper is caught too.
    check not accepts("a(?:(?I)b)")
    check not accepts("b(?:(?I)a)")
    check not accepts("(?:a)(?:(?I)b)")

  test "neither can be cleared":
    check not accepts("(?-I)a")
    check not accepts("(?-L)a")
    check not accepts("(?i-I)a")
    check not accepts("(?i-L)a")
    check not accepts("(?-I:a)")
    check not accepts("(?i-I:a)")
    check not accepts("(?I-I:a)")
    # Turning something else off alongside is fine.
    check accepts("(?I-i)a")
    check accepts("(?L-i)a")
    check accepts("(?iI-x)a")

  test "a body may still carry ordinary option groups":
    check accepts("(?I:(?i)a)")
    check accepts("(?I:(?W)a)")
    check accepts("(?I:(?:a))")
    check accepts("(?I)(?i:a)")
