import std/[unittest, strutils, options, unicode]

import ../reni
import ../reni/engine
import ../reni/types

# What a pattern answers; the invariants behind it are in
# ``test_engine_internals.nim``.  Keep the two apart: ``refc`` allows 3500
# module-level globals and a ``unittest`` body is module-level.

suite "Step 1: Literal matching":
  test "empty pattern matches empty string":
    let m = search("", re(""))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 0

  test "empty pattern matches non-empty string at pos 0":
    let m = search("abc", re(""))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 0

  test "single ASCII literal":
    let m = search("a", re("a"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "single literal no match":
    let m = search("b", re("a"))
    check not m.found

  test "multi-char literal (concat)":
    let m = search("hello", re("hello"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 5

  test "literal match at non-zero position":
    let m = search("xxab", re("ab"))
    check m.found
    check m.boundaries[0].a == 2
    check m.boundaries[0].b == 4

  test "partial match does not succeed":
    let m = search("ab", re("abc"))
    check not m.found

  test "Unicode literal (2-byte UTF-8)":
    let m = search("\xC3\xA9", re("\xC3\xA9")) # é
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 2

  test "Unicode literal (3-byte UTF-8)":
    let m = search("a\xE3\x81\x82b", re("\xE3\x81\x82")) # あ
    check m.found
    check m.boundaries[0].a == 1
    check m.boundaries[0].b == 4

  test "escaped literal \\n":
    let m = search("a\nb", re("\\n"))
    check m.found
    check m.boundaries[0].a == 1
    check m.boundaries[0].b == 2

  test "escaped literal \\t":
    let m = search("\t", re("\\t"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "no match in empty subject":
    let m = search("", re("a"))
    check not m.found

  test "leftmost match returned":
    let m = search("aXaX", re("a"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

suite "Step 2: Anchors":
  test "^ matches at start of string":
    let m = search("abc", re("^a"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "^ does not match mid-string":
    let m = search("ba", re("^a"))
    check not m.found

  test "^ matches after newline (always multiline in Oniguruma)":
    let m = search("x\na", re("^a"))
    check m.found
    check m.boundaries[0].a == 2
    check m.boundaries[0].b == 3

  test "$ matches at end of string":
    let m = search("abc", re("c$"))
    check m.found
    check m.boundaries[0].a == 2
    check m.boundaries[0].b == 3

  test "$ matches before newline":
    let m = search("a\nb", re("a$"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "\\A matches only at string begin":
    let m = search("a\na", re("\\Aa"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "\\A does not match after newline":
    # \A should only match at absolute start, not after newline
    let m = search("\na", re("\\Aa"))
    check not m.found

  test "\\z matches at string end":
    let m = search("abc", re("c\\z"))
    check m.found
    check m.boundaries[0].a == 2
    check m.boundaries[0].b == 3

  test "\\z does not match before newline":
    let m = search("a\n", re("a\\z"))
    check not m.found

  test "\\Z matches at end":
    let m = search("abc", re("c\\Z"))
    check m.found
    check m.boundaries[0].a == 2
    check m.boundaries[0].b == 3

  test "\\Z matches before trailing newline":
    let m = search("a\n", re("a\\Z"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "\\G matches at search start":
    let m = search("abc", re("\\Ga"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "\\G does not match at non-start":
    # \G only matches at the position where the search started
    let m = search("ba", re("\\Ga"))
    check not m.found

suite "Step 3: Dot and character types":
  test ". matches any char except newline":
    let m = search("a", re("."))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test ". does not match newline by default":
    let m = search("\n", re("."))
    check not m.found

  test ". matches newline with (?m) flag":
    let m = search("\n", re("(?m)."))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test ". matches Unicode rune":
    let m = search("\xE3\x81\x82", re(".")) # あ (3 bytes)
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3

  test "\\w matches word character":
    let m = search("a", re("\\w"))
    check m.found

  test "\\w matches digit":
    let m = search("5", re("\\w"))
    check m.found

  test "\\w matches underscore":
    let m = search("_", re("\\w"))
    check m.found

  test "\\w does not match space":
    let m = search(" ", re("\\w"))
    check not m.found

  test "\\W matches non-word":
    let m = search(" ", re("\\W"))
    check m.found

  test "\\d matches digit":
    let m = search("7", re("\\d"))
    check m.found

  test "\\d does not match letter":
    let m = search("a", re("\\d"))
    check not m.found

  test "\\D matches non-digit":
    let m = search("a", re("\\D"))
    check m.found

  test "\\s matches space":
    let m = search(" ", re("\\s"))
    check m.found

  test "\\s matches tab":
    let m = search("\t", re("\\s"))
    check m.found

  test "\\S matches non-space":
    let m = search("a", re("\\S"))
    check m.found

  test "\\h matches hex digit":
    let m = search("f", re("\\h"))
    check m.found

  test "\\h does not match g":
    let m = search("g", re("\\h"))
    check not m.found

  test "\\H matches non-hex":
    let m = search("z", re("\\H"))
    check m.found

  test "case insensitive literal":
    let m = search("A", re("(?i)a"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "case insensitive no match":
    let m = search("b", re("(?i)a"))
    check not m.found

suite "Step 4: Alternation and quantifiers":
  test "simple alternation a|b matches a":
    let m = search("a", re("a|b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "simple alternation a|b matches b":
    let m = search("b", re("a|b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "alternation with concat":
    let m = search("cd", re("ab|cd"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 2

  test "alternation backtracks with continuation":
    # (?:a|ab)c — first alt 'a' matches but 'c' fails, must backtrack to 'ab'
    let m = search("abc", re("(?:a|ab)c"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3

  test "greedy * matches zero":
    let m = search("b", re("a*b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "greedy * matches many":
    let m = search("aaab", re("a*b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 4

  test "greedy + matches one":
    let m = search("ab", re("a+b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 2

  test "greedy + fails on zero":
    let m = search("b", re("a+b"))
    check not m.found

  test "greedy ? matches zero":
    let m = search("b", re("a?b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "greedy ? matches one":
    let m = search("ab", re("a?b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 2

  test "greedy {2,3}":
    let m = search("xaaay", re("a{2,3}"))
    check m.found
    check m.boundaries[0].a == 1
    check m.boundaries[0].b == 4 # greedy matches 3

  test "greedy * backtracks":
    # a*a matches "aaa" — greedy * takes 2, last a matches 3rd
    let m = search("aaa", re("a*a"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3

  test "lazy *? matches minimal":
    let m = search("aaab", re("a*?b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 4

  test "lazy +? matches one":
    let m = search("aaab", re("a+?"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "possessive *+ no backtrack":
    # a*+a can never match because *+ won't give back
    let m = search("aaa", re("a*+a"))
    check not m.found

  test "possessive ++ no backtrack":
    let m = search("aaa", re("a++a"))
    check not m.found

  test "possessive quantifier rolls back a failed iteration's \\K":
    # The last iteration matches \K and then fails, so its match-start move has
    # to be undone: /(?:\Ka)*+/ matches "a" at 0..1, not 1..1.
    let m = search("a", re("(?:\\Ka)*+"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "possessive quantifier rolls back a failed iteration's captures":
    # Iteration 2 captures "b" at 2..3 before failing on [^a]; group 1 must keep
    # the value written by iteration 1.
    let m = search("abb", re("(?:\\K([ab])[^a])*+"))
    check m.found
    check m.boundaries[0] == 0 .. 2
    check m.boundaries[1] == 0 .. 1

  test "dot star greedy":
    let m = search("abc", re(".*"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3

  test "alternation in quantifier backtracks body":
    # (a|ab)*c on "aabc": need rep1=a, rep2=ab, then c
    let m = search("aabc", re("(?:a|ab)*c"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 4

  test "nested quantifiers":
    let m = search("aabb", re("(?:a+b+)+"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 4

  test "quantifier chaining ?{2} on empty":
    let m = search("", re("(?:ab)?{2}"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 0

  test "quantifier chaining ?{2} on content":
    let m = search("ababa", re("(?:ab)?{2}"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 4

  test "quantifier chaining *{0}":
    let m = search("ababa", re("(?:ab)*{0}"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 0

  test "inverted range {3,2} greedy":
    # Oniguruma: {3,2} = {0,3}
    let m = search("aaab", re("a{3,2}b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 4

  test "inverted range {3,2} matches fewer":
    let m = search("aab", re("a{3,2}b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3

  test "inverted range {3,2}? lazy on empty":
    let m = search("", re("a{3,2}?"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 0

  test "inverted range {2,0} requires nothing":
    # The bounds swap leaves ``{0,2}``, so ``x`` need not appear: the
    # required-byte quick reject must not treat it as mandatory.
    let m = search("y", re("x{2,0}y"))
    check m.found
    check m.matchSpan == 0 .. 1
    let m2 = search("zy", re("x{2,0}y"))
    check m2.found
    check m2.matchSpan == 1 .. 2
    let m3 = search("", re("x{2,0}"))
    check m3.found
    check m3.matchSpan == 0 .. 0

  test "scoped flag group with alternation and continuation":
    # (?i:a|ab)c on "ABc" — case insensitive body, case sensitive continuation
    let m = search("ABc", re("(?i:a|ab)c"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3

  test "scoped flag does not leak to continuation":
    # (?i:a)B should match "aB" but not "ab" (B is case sensitive)
    let m1 = search("aB", re("(?i:a)B"))
    check m1.found
    let m2 = search("ab", re("(?i:a)B"))
    check not m2.found

suite "Step 5: Character classes":
  test "[abc] matches single char":
    let m = search("b", re("[abc]"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 1

  test "[abc] no match":
    let m = search("d", re("[abc]"))
    check not m.found

  test "[a-z] range":
    let m = search("m", re("[a-z]"))
    check m.found

  test "[a-z] range no match":
    let m = search("M", re("[a-z]"))
    check not m.found

  test "[^abc] negated":
    let m = search("d", re("[^abc]"))
    check m.found

  test "[^abc] negated no match":
    let m = search("a", re("[^abc]"))
    check not m.found

  test "[\\w] char type in class":
    let m = search("a", re("[\\w]"))
    check m.found

  test "[\\d] digit in class":
    let m = search("5", re("[\\d]"))
    check m.found

  test "[:alpha:] POSIX class":
    let m = search("z", re("[[:alpha:]]"))
    check m.found

  test "[:alpha:] POSIX no match digit":
    let m = search("5", re("[[:alpha:]]"))
    check not m.found

  test "[:^alpha:] negated POSIX":
    let m = search("5", re("[[:^alpha:]]"))
    check m.found

  test "case insensitive char class":
    let m = search("A", re("(?i)[a-z]"))
    check m.found

  test "\\p{L} unicode property as char class":
    let m = search("a", re("\\p{L}"))
    check m.found

  test "\\P{L} negated unicode property":
    let m = search("5", re("\\P{L}"))
    check m.found

  test "&& intersection matches consonant":
    let m = search("b", re("[a-z&&[^aeiou]]"))
    check m.found

  test "&& intersection rejects vowel":
    let m = search("a", re("[a-z&&[^aeiou]]"))
    check not m.found

  test "&& intersection with outer negation":
    # [^[^abc]&&[^cde]] = NOT(NOT{a,b,c} AND NOT{c,d,e}) = {a,b,c,d,e}
    let m = search("e", re("[^[^abc]&&[^cde]]"))
    check m.found

  test "&& intersection with outer negation rejects":
    let m = search("f", re("[^[^abc]&&[^cde]]"))
    check not m.found

suite "Step 6: Capture groups":
  test "simple capture":
    let m = search("abc", re("(a)bc"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3
    check m.boundaries[1].a == 0
    check m.boundaries[1].b == 1

  test "multiple captures":
    let m = search("abc", re("(a)(b)(c)"))
    check m.found
    check m.boundaries[1].a == 0
    check m.boundaries[1].b == 1
    check m.boundaries[2].a == 1
    check m.boundaries[2].b == 2
    check m.boundaries[3].a == 2
    check m.boundaries[3].b == 3

  test "nested capture":
    let m = search("abc", re("(a(b)c)"))
    check m.found
    check m.boundaries[1].a == 0
    check m.boundaries[1].b == 3
    check m.boundaries[2].a == 1
    check m.boundaries[2].b == 2

  test "capture with quantifier":
    let m = search("aab", re("(a)+b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3
    # Last capture
    check m.boundaries[1].a == 1
    check m.boundaries[1].b == 2

  test "named capture":
    let m = search("abc", re("(?<x>a)bc"))
    check m.found
    check m.boundaries[1].a == 0
    check m.boundaries[1].b == 1

  test "non-capturing group does not create capture":
    let m = search("abc", re("(?:a)bc"))
    check m.found
    check m.boundaries.len == 1 # only overall match

suite "Step 7: Backreferences":
  test "simple backref \\1":
    let m = search("aa", re("(a)\\1"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 2

  test "backref no match":
    let m = search("ab", re("(a)\\1"))
    check not m.found

  test "backref multi-char":
    let m = search("abcabc", re("(abc)\\1"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 6

  test "case insensitive backref":
    let m = search("aA", re("(?i)(a)\\1"))
    check m.found

suite "Step 8: Word boundary":
  test "\\b at word start":
    let m = search("hello world", re("\\bworld"))
    check m.found
    check m.boundaries[0].a == 6
    check m.boundaries[0].b == 11

  test "\\b at word end":
    let m = search("hello world", re("hello\\b"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 5

  test "\\b at string start":
    let m = search("hello", re("\\bhello"))
    check m.found

  test "\\b at string end":
    let m = search("hello", re("hello\\b"))
    check m.found

  test "\\B inside word":
    let m = search("hello", re("h\\Bello"))
    check m.found

  test "\\B fails at word boundary":
    let m = search("hello world", re("hello\\Bworld"))
    check not m.found

suite "Steps 10-11: Atomic, lookaround":
  test "atomic group no backtrack":
    let m = search("aaa", re("(?>a+)a"))
    check not m.found

  test "positive lookahead":
    let m = search("foobar", re("foo(?=bar)"))
    check m.found
    check m.boundaries[0].a == 0
    check m.boundaries[0].b == 3 # only "foo", not "foobar"

  test "negative lookahead":
    let m = search("foobar", re("foo(?!baz)"))
    check m.found

  test "negative lookahead fails":
    let m = search("foobar", re("foo(?!bar)"))
    check not m.found

  test "positive lookbehind":
    let m = search("foobar", re("(?<=foo)bar"))
    check m.found
    check m.boundaries[0].a == 3
    check m.boundaries[0].b == 6

  test "negative lookbehind":
    let m = search("foobar", re("(?<!baz)bar"))
    check m.found

  test "negative lookbehind fails":
    let m = search("foobar", re("(?<!foo)bar"))
    check not m.found

  test "variable-length lookbehind with alternation":
    let m = search("abcdef", re("(?<=ab|abc|abcd)ef"))
    check m.found
    check m.boundaries[0] == 4 .. 6

  test "lookbehind with quantifier":
    let m = search("abbbz", re("(?<=a.*\\w)z"))
    check m.found
    check m.boundaries[0] == 4 .. 5

suite "Isolated flags and chaining":
  test "isolated flag across alternation":
    let m = search("aC", re("a(?i)b|c"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "isolated flag in second branch":
    let m = search("cB", re("c(?i)a|b"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "case-insensitive range with resolveCaseFold":
    let m = search("D", re("(?i:[A-c])"))
    check m.found

  test "\\p{^Word} negated property":
    let m = search(" ", re("\\p{^Word}"))
    check m.found

  test "(?P) restricts \\p{Word} to ASCII":
    let m = search("\xe3\x81\x82", re("(?P:\\p{Word})")) # hiragana 'a'
    check not m.found

  test "forward reference in backref":
    let m = search("zaaa", re("(?:(?:\\1|z)(a))+$"))
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "octal escape fallback for multi-digit":
    let m = search("\x0F", re("\\17"))
    check m.found

  test "quantifier chaining {n}?":
    let m = search("aa", re("a{3}?"))
    check m.found
    check m.boundaries[0] == 0 .. 0 # (a{3})? lazy = 0 reps

  test "quantifier chaining {n}+":
    let m = search("aaaaaa", re("a{3}+"))
    check m.found
    check m.boundaries[0] == 0 .. 6 # (a{3})+ = 2 reps

  test "POSIX punct matches $":
    let m = search("$", re("[[:punct:]]"))
    check m.found

  test "multi-codepoint hex escape":
    let m = search("\x0A/", re("\\x{000A 002f}"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "multi-codepoint hex in char class":
    let m = search("\x0A", re("[\\x{000A 002f}]"))
    check m.found

  test "multi-codepoint hex range in char class":
    let m = search("5", re("[\\x{0030-0039}]"))
    check m.found

  test "\\x{HHHH} dash without endpoint is error":
    expect(RegexError):
      discard re("[\\x{0030 - }]")

  test "multi-codepoint octal escape":
    let m = search("BC", re("\\o{102 103}"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "POSIX class fallback for [[:upper]]":
    let m1 = search("A", re("[[:upper]]"))
    check not m1.found # not valid POSIX, [[:upper]] = nested CC containing :,u,p,p,e,r
    let m2 = search(":", re("[[:upper]]"))
    check m2.found

  test "{,} treated as literal":
    let m = search("ab{,}", re("(?:ab){,}"))
    check m.found
    check m.boundaries[0] == 0 .. 5

  test "\\c\\\\ control escape":
    let m = search("\x1C", re("\\c\\\\"))
    check m.found

  test "\\p{InBasicLatin} block property":
    let m = search("A", re("\\p{InBasicLatin}"))
    check m.found

  test "\\p{Inherited} script property":
    # "In"-prefixed names try the block table first, but Inherited is a script
    # name, not a block, so it must fall through instead of matching nothing.
    let m = search("\u0301", re("\\p{Inherited}"))
    check m.found
    check not search("a", re("\\p{Inherited}")).found

  test "\\p{InHiragana} block wins over the Hiragana script":
    # U+3099 lives in the Hiragana block but belongs to the Inherited script.
    check search("\u3099", re("\\p{InHiragana}")).found
    check not search("\u3099", re("\\p{Hiragana}")).found
    check search("\u3042", re("\\p{Hiragana}")).found

  test "\\p{PosixPunct}":
    let m = search("$", re("\\p{PosixPunct}"))
    check m.found

  test "(*FAIL) always fails":
    let m = search("abc", re("(*FAIL)"))
    check not m.found

  test "codepoint > 0x10FFFF errors":
    var raised = false
    try:
      discard re("\\x{7fffffff}")
    except RegexError:
      raised = true
    check raised

suite "ReDoS protection (stepLimit)":
  test "stepLimit triggers on catastrophic backtracking":
    let r = re("(a+)+b")
    var raised = false
    try:
      discard search("aaaaaaaaaaaaaaaaaa", r, stepLimit = 10_000)
    except RegexLimitError:
      raised = true
    check raised

  test "stepLimit=0 means unlimited":
    let r = re("a+")
    let m = search("aaaa", r, stepLimit = 0)
    check m.found

  test "normal match within stepLimit succeeds":
    let r = re("(a+)b")
    let m = search("aaab", r, stepLimit = 10_000)
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "default stepLimit prevents ReDoS":
    let r = re("(a+)+b")
    expect RegexLimitError:
      discard search("a".repeat(100), r)

  test "explicit unlimited stepLimit":
    let m = search("aab", re("(a+)+b"), stepLimit = 0)
    check m.found

suite "search with start position":
  test "search from middle of string":
    let r = re("\\d+")
    let m = search("abc123def456", r, start = 6)
    check m.found
    check m.boundaries[0] == 9 .. 12

  test "search from position 0 (default)":
    let r = re("\\d+")
    let m = search("abc123def456", r)
    check m.found
    check m.boundaries[0] == 3 .. 6

  test "search past all matches":
    let r = re("a")
    let m = search("aaa", r, start = 3)
    check not m.found

  test "continuing search after match":
    let r = re("[a-z]+")
    let m1 = search("abc def ghi", r)
    check m1.found
    check m1.boundaries[0] == 0 .. 3
    let m2 = search("abc def ghi", r, start = m1.boundaries[0].b)
    check m2.found
    check m2.boundaries[0] == 4 .. 7

suite "matchAt (position-anchored matching)":
  test "match at correct position":
    let r = re("\\d+")
    let m = matchAt("abc123def", r, pos = 3)
    check m.found
    check m.boundaries[0] == 3 .. 6

  test "no match at wrong position":
    let r = re("\\d+")
    let m = matchAt("abc123def", r, pos = 0)
    check not m.found

  test "match at position 0":
    let r = re("abc")
    let m = matchAt("abcdef", r, pos = 0)
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "\\G anchor works with matchAt":
    let r = re("\\Gabc")
    let m = matchAt("xyzabc", r, pos = 3)
    check m.found
    check m.boundaries[0] == 3 .. 6

  test "captures work with matchAt":
    let r = re("(\\w+)=(\\w+)")
    let m = matchAt("  key=val", r, pos = 2)
    check m.found
    check captureText(m, 1, "  key=val") == some("key")
    check captureText(m, 2, "  key=val") == some("val")

  test "zero-width match at position":
    let r = re("(?=abc)")
    let m = matchAt("abc", r, pos = 0)
    check m.found
    check m.boundaries[0] == 0 .. 0

suite "captureText":
  test "basic capture":
    let r = re("(\\w+)@(\\w+)")
    let m = search("user@host", r)
    check captureText(m, 0, "user@host") == some("user@host")
    check captureText(m, 1, "user@host") == some("user")
    check captureText(m, 2, "user@host") == some("host")

  test "uncaptured group returns none":
    let r = re("(a)|(b)")
    let m = search("b", r)
    check m.found
    check captureText(m, 1, "b") == none(string) # group 1 not captured
    check captureText(m, 2, "b") == some("b")

  test "out of range returns none":
    let r = re("abc")
    let m = search("abc", r)
    check captureText(m, 99, "abc") == none(string)

  test "no match returns none":
    let m = Match(found: false)
    check captureText(m, 0, "abc") == none(string)

suite "captureByName":
  test "named capture":
    let r = re("(?<user>\\w+)@(?<host>\\w+)")
    let m = search("admin@server", r)
    check captureText(m, "user", "admin@server", r) == some("admin")
    check captureText(m, "host", "admin@server", r) == some("server")

  test "unknown name returns none":
    let r = re("(?<x>abc)")
    let m = search("abc", r)
    check captureText(m, "y", "abc", r) == none(string)

  test "captureIndex":
    let r = re("(?<first>\\w+) (?<second>\\w+)")
    check captureIndex(r, "first") == 1
    check captureIndex(r, "second") == 2
    check captureIndex(r, "third") == -1

suite "findAll":
  test "basic findAll":
    let r = re("\\d+")
    var matches: seq[string]
    for m in findAll("a1b22c333", r):
      matches.add captureText(m, 0, "a1b22c333").get("")
    check matches == @["1", "22", "333"]

  test "zero-width matches advance":
    let r = re("")
    var count = 0
    for m in findAll("ab", r):
      inc count
    check count == 3 # before a, before b, after b

  test "no matches":
    let r = re("\\d")
    var count = 0
    for m in findAll("abc", r):
      inc count
    check count == 0

  test "overlapping avoided":
    let r = re("aba")
    var matches: seq[Span]
    for m in findAll("abababa", r):
      matches.add m.boundaries[0]
    check matches == @[span(0, 3), span(4, 7)]

suite "replace":
  test "basic replace all":
    check replace("abc123def456", re("\\d+"), "N") == "abcNdefN"

  test "replace with backreference":
    check replace("2024-03-27", re("(\\d{4})-(\\d{2})-(\\d{2})"), "$3/$2/$1") ==
      "27/03/2024"

  test "replace $0 (whole match)":
    check replace("hello", re("\\w+"), "[$0]") == "[hello]"

  test "replace $$ literal dollar":
    check replace("100", re("\\d+"), "$$$$") == "$$"

  test "replace with count limit":
    check replace("aaa", re("a"), "b", count = 2) == "bba"

  test "replace with named capture":
    check replace("John Smith", re("(?<first>\\w+) (?<last>\\w+)"), "${last}, ${first}") ==
      "Smith, John"

  test "replace with callback":
    let result = replace(
      "hello world",
      re("\\w+"),
      proc(m: Match, s: string): string =
        let text = captureText(m, 0, s).get("")
        text[0 ..< 1].toUpperAscii & text[1 ..< text.len],
    )
    check result == "Hello World"

  test "replace zero-width matches":
    check replace("abc", re(""), "-") == "-a-b-c-"

suite "split":
  test "basic split":
    check split("a,b,c", re(",")) == @["a", "b", "c"]

  test "split with captures":
    check split("a1b2c", re("(\\d)")) == @["a", "1", "b", "2", "c"]

  test "split with maxSplit":
    check split("a,b,c,d", re(","), maxSplit = 2) == @["a", "b", "c,d"]

  test "split no match":
    check split("abc", re(",")) == @["abc"]

  test "split at start/end":
    check split(",a,b,", re(",")) == @["", "a", "b", ""]

suite "searchBackward with start position":
  test "searchBackward default (from end)":
    let r = re("x")
    let m = searchBackward("axbxc", r)
    check m.found
    check m.boundaries[0] == 3 .. 4

  test "searchBackward from start position":
    let r = re("x")
    let m = searchBackward("axbxc", r, start = 2)
    check m.found
    check m.boundaries[0] == 1 .. 2

  test "searchBackward start before any match":
    let r = re("\\d+")
    let m = searchBackward("abc123", r, start = 2)
    check not m.found

  test "searchBackward start=0":
    let r = re("a")
    let m = searchBackward("abc", r, start = 0)
    check m.found
    check m.boundaries[0] == 0 .. 1

suite "Conditionals":
  test "backref condition: captured takes yes branch":
    let m = search("ab", re("(a)?(?(1)b|c)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "backref condition: not captured takes no branch":
    let m = search("c", re("(a)?(?(1)b|c)"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  # Every expectation from here to the end of the false-condition group was
  # read off Oniguruma 6.9.10 (ONIG_SYNTAX_ONIGURUMA, UTF-8, onig_search).
  # Oniguruma has no regex conditions — /(?(?=a))b/ and /(?(a+))b/ are syntax
  # errors there — so the regex-condition cases below follow PCRE2 instead.
  test "backref condition: no else branch skips a non-empty yes branch":
    # Oniguruma matches the empty string at 0 here.
    let m = search("c", re("(a)?(?(1)b)"))
    check m.found
    check m.boundaries[0] == 0 .. 0

  test "named ref condition: no else branch skips a non-empty yes branch":
    let m = search("c", re("(?<x>a)?(?(<x>)b)"))
    check m.found
    check m.boundaries[0] == 0 .. 0

  test "backref condition: empty yes branch and no else branch fails":
    # /(a)?(?(1))b/ does not match "b" in Oniguruma, unlike /(a)?(?(1)x)b/.
    check not search("b", re("(a)?(?(1))b")).found

  test "backref condition: empty yes branch still runs when the condition holds":
    let m = search("ab", re("(a)(?(1))b"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "backref condition: a group is not an empty yes branch":
    let m = search("b", re("(a)?(?(1)(?:))b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "backref condition: a comment is not an empty yes branch":
    # (?#...) is erased while parsing, but it was there in the source, so the
    # branch counts as non-empty just like /(a)?(?(1)(?:))b/ does.
    let m = search("b", re("(a)?(?(1)(?#note))b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "backref condition: comment yes branch still runs when condition holds":
    let m = search("ab", re("(a)(?(1)(?#note))b"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "backref condition: \\Q\\E is not an empty yes branch":
    # \Q\E parses to no nodes at all, but it was written in the source, so it
    # counts as non-empty just like /(a)?(?(1)(?#note))b/ does.
    let m = search("b", re("(a)?(?(1)\\Q\\E)b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "backref condition: extended-mode whitespace is not an empty yes branch":
    let m = search("b", re("(?x)(a)?(?(1) )b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "backref condition: extended-mode comment is not an empty yes branch":
    let m = search("b", re("(?x)(a)?(?(1)#c\n)b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "named ref condition: captured":
    let m = search("ab", re("(?<x>a)?(?(<x>)b|c)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "named ref condition: not captured":
    let m = search("c", re("(?<x>a)?(?(<x>)b|c)"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "always-true condition takes yes branch":
    let m = search("a", re("(?()a|b)"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "always-true condition skips no branch":
    let m = search("b", re("(?()a|b)"))
    check not m.found

  test "always-false condition takes no branch":
    let m = search("b", re("(?(*FAIL)a|b)"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "always-false condition skips yes branch":
    let m = search("a", re("(?(*FAIL)a|b)"))
    check not m.found

  test "regex condition lookahead yes":
    let m = search("a1", re("(?(?=a)a1|b2)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "regex condition lookahead no":
    let m = search("b2", re("(?(?=a)a1|b2)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "regex condition lookbehind":
    let m = search("xy", re("(?(?<=x)y|n)"))
    check m.found
    check m.boundaries[0] == 1 .. 2

  test "nested conditional with capture":
    let m = search("ab", re("(a)?(?(1)(b)|c)"))
    check m.found
    check captureText(m, 2, "ab") == some("b")

  test "conditional no else regex gives empty match":
    let m = search("b", re("(?(?=a)a)"))
    check m.found
    check m.boundaries[0] == 0 .. 0

  test "regex condition: empty yes branch and no else is skipped":
    # The empty-yes-branch rule is Oniguruma's, and Oniguruma has no regex
    # conditions — /(?(?=a))b/ is a syntax error there.  PCRE2 is the only
    # reference, and it skips the false condition and matches "b".
    let m = search("b", re("(?(?=a))b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "regex condition: empty yes branch skipped mid-subject":
    let m = search("ab", re("(?(?=a))b"))
    check m.found
    check m.boundaries[0] == 1 .. 2

  test "bare regex condition: empty yes branch and no else is skipped":
    let m = search("b", re("(?(a+))b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "always-false condition: empty yes branch and no else is skipped":
    let m = search("b", re("(?(*FAIL))b"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "conditional alternation both branches":
    let m1 = search("ab", re("(a)?(?(1)b|c)"))
    check m1.found
    check m1.boundaries[0] == 0 .. 2
    let m2 = search("cb", re("(a)?(?(1)b|c)"))
    check m2.found
    check m2.boundaries[0] == 0 .. 1

  test "conditional with named capture after unnamed demote":
    let m = search("abc", re("(a)(?<x>b)(?(<x>)c|d)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

suite "Subroutine calls and recursion":
  test "numeric call (?1)":
    let m = search("aa", re("(a)(?1)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "call re-evaluates body, not backref":
    let m = search("aab", re("([abc])\\1(?1)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "call second group (?2)":
    let m = search("aba", re("(a)(b)(?1)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "named call (?&name)":
    let m = search("42", re("(?<d>[0-9])(?&d)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "named call triple":
    let m = search("789", re("(?<d>[0-9])(?&d)(?&d)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "simple recursion a(?R)?b":
    let m = search("aabb", re("a(?R)?b"))
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "whole pattern recursion balanced parens":
    let m = search("(a(b)c)", re("\\((?:[^()]*|(?R))*\\)"))
    check m.found
    check m.boundaries[0] == 0 .. 7

  test "deep recursion balanced parens":
    let m = search("(a(b(c)d)e)", re("\\((?:[^()]*|(?R))*\\)"))
    check m.found
    check m.boundaries[0] == 0 .. 11

  test "relative call (?-1)":
    let m = search("aa", re("(a)(?-1)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "relative call (?-1) two groups":
    let m = search("abb", re("(a)(b)(?-1)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "Python (?P>name)":
    let m = search("ab", re("(?P<L>[a-z])(?P>L)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "recursion depth limit does not crash":
    let s = "a".repeat(60)
    # Each subject character costs about one ``matchNodeRecursive`` level,
    # and ``maxRecursionDepth`` (default 50) caps the subroutine nesting, so
    # this stays near ~50 delegation levels: inside the byte budget in both
    # exception models, and the partial match the depth cap bounds is the
    # answer. Under a small ``-d:reniMaxStackBytes`` the same shape is what
    # the budget guard turns into RegexLimitError. A segfault is neither.
    when compileOption("exceptions", "setjmp") or engine.MaxStackBytes <= 64 * 1024:
      try:
        check search(s, re("(a(?1)?)")).found
      except RegexLimitError:
        discard
    else:
      check search(s, re("(a(?1)?)")).found

  test "maxRecursionDepth bounds recursion before the call depth guard does":
    # The public maxRecursionDepth is only meaningful if it is reachable: the
    # call depth guard must not fire first and turn a bounded partial match
    # into an error. Subroutine calls hold no native frame per level, so 40
    # characters fit every budget on every build and the depth cap answers.
    let m = search("a".repeat(40), re("(a(?1)?)"), maxRecursionDepth = 50)
    check m.found
    check m.matchSpan == Span(a: 0, b: 40)

suite "Absent operator":
  test "abClear (?~) matches empty":
    let m = search("ab", re("a(?~)b"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "abFunction (?~abc) stops before absent":
    let m = search("xyzabcdef", re("(?~abc)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "abFunction no absent matches all":
    let m = search("abcdef", re("(?~x)"))
    check m.found
    check m.boundaries[0] == 0 .. 6

  test "abFunction absent at start matches empty":
    let m = search("xabc", re("(?~x)"))
    check m.found
    check m.boundaries[0] == 0 .. 0

  test "abFunction single char":
    let m = search("abc", re("(?~b)"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "abExpression limits match range":
    let m = search("abcxdef", re("(?~|x|.+)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "abExpression multi-char absent":
    let m = search("xyzabcdef", re("(?~|abc|.+)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "abRange limits subject end":
    let m = search("abcxdef", re("(?~|x).*"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "abRange no absent found":
    let m = search("abcdef", re("(?~|z).*"))
    check m.found
    check m.boundaries[0] == 0 .. 6

  test "abRange limits dot":
    let m = search("abc", re("(?~|b)."))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "abExpression alternation retries inside the narrowed range":
    # The loop un-narrows subjectEnd while walking out of the absent frame;
    # when the parent then fails, the second branch must retry narrowed.
    # Retrying widened matched past the absent instead.
    check not search("abc", re("(?~|b|(a|ab))c")).found
    check not search("axc", re("(?~|x|(a|ax))c")).found
    let m = search("abc", re("(?~|b|(a|ab))b"))
    check m.found
    check m.boundaries[0] == 0 .. 2

suite "Callout verbs":
  test "MAX basic limits repetitions":
    let m = search("aaaaa", re("(?:a(*MAX{3}))*"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "MAX=1 single iteration":
    let m = search("aaa", re("(?:a(*MAX{1}))*"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "MAX with continuation":
    let m = search("aab", re("(?:(*MAX{2})a)+b"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "MAX independent tags":
    let m = search("aabbb", re("(?:a(*MAX[x]{2}))*(?:b(*MAX[y]{3}))*"))
    check m.found
    check m.boundaries[0] == 0 .. 5

  test "COUNT and CMP equal":
    let m = search("aabb", re("(?:a(*COUNT[X]{X}))*(?:b(*COUNT[Y]{Y}))*(*CMP{X,==,Y})"))
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "COUNT and CMP less than":
    let m = search("abbb", re("(?:a(*COUNT[X]{X}))*(?:b(*COUNT[Y]{Y}))*(*CMP{X,<,Y})"))
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "CMP greater than default zero":
    let m = search("aa", re("(?:a(*COUNT[X]{X}))*(*CMP{X,>,Y})"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "CMP fails when condition not met":
    let m = search("", re("(?:a(*COUNT[X]{X}))*(*CMP{X,>,Y})"))
    check not m.found

suite "Grapheme features":
  test "\\X matches single ASCII char":
    let m = search("a", re("\\X"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "\\X matches combining sequence":
    # e + combining acute accent (U+0301) = one grapheme cluster
    let m = search("e\xCC\x81", re("\\X"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "\\X+ matches multiple clusters":
    let m = search("ab", re("\\X+"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "\\X matches CRLF as one cluster":
    let m = search("\r\n", re("^\\X$"))
    check m.found

  test "(?y{g}) dot matches grapheme cluster":
    let m = search("e\xCC\x81", re("(?y{g})."))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "\\y grapheme boundary between base chars":
    let m = search("ab", re("a\\yb"))
    check m.found

  test "\\X breaks before the Mc characters that are not SpacingMark":
    # 31 Mc code points are neither Grapheme_Extend nor SpacingMark, so their
    # GCB is Other and a cluster ends in front of them.  Deriving Extend from
    # the general category instead of GraphemeBreakProperty.txt misses these.
    for cp in [0x102B, 0x1038, 0x1064, 0x108F, 0x109A, 0x1A61, 0xAA7B, 0x11720]:
      let s = $Rune(0x1000) & $Rune(cp)
      let m = search(s, re("^\\X$"))
      check(not m.found)

  test "\\X breaks around GCB=Control characters":
    # Cf is not uniformly Extend: these are Control and break on both sides.
    for cp in [0x202A, 0x202E, 0xFFF9, 0xFFFB, 0x1D173, 0x1D17A, 0xE0001]:
      let s = "a" & $Rune(cp)
      let m = search(s, re("^\\X$"))
      check(not m.found)

  test "\\X uses the GCB jamo ranges, not the composition ranges":
    # GCB=V starts at U+1160 (jungseong filler) and GCB=T runs to U+11FF;
    # the AC00 composition constants cover neither.
    check search($Rune(0x1100) & $Rune(0x1160), re("^\\X$")).found
    check search($Rune(0xAC00) & $Rune(0x1160), re("^\\X$")).found
    check search($Rune(0x1160) & $Rune(0x11A8), re("^\\X$")).found

  test "(?y{w}) applies WB4 before the look-back rules":
    # Each pair is one word segment only if the rule that joins it looks past
    # the Extend/Format run at the character *before* it (WB7, WB11, WB15).
    for s in [
      "a" & $Rune(0x3A) & $Rune(0x0308) & "b", # WB7  AHLetter MidLetter x AHLetter
      "a" & $Rune(0x27) & $Rune(0x2060) & "b", # WB7  with a Format
      "1" & $Rune(0x2E) & $Rune(0x2060) & "1", # WB11 Numeric MidNum x Numeric
      $Rune(0x1F1E6) & $Rune(0x0308) & $Rune(0x1F1E6), # WB15 RI pair across an Extend
    ]:
      check search(s, re("^(?y{w})\\X$")).found

  test "\\X joins GCB=Extend characters that are not marks":
    # Emoji_Modifier and the halfwidth voiced sound marks are Extend without
    # being in any M* general category.
    for cp in [0x1F3FB, 0x1F3FF, 0xFF9E, 0xFF9F]:
      let s = "a" & $Rune(cp)
      let m = search(s, re("^\\X$"))
      check m.found

suite "Special escapes":
  test "\\K resets match start":
    let m = search("ab", re("a\\Kb"))
    check m.found
    check m.boundaries[0] == 1 .. 2

  test "\\K in longer pattern":
    let m = search("abc123", re("[a-z]+\\K\\d+"))
    check m.found
    check m.boundaries[0] == 3 .. 6

  test "\\K in replace":
    check replace("xyz", re("x\\Ky"), "!") == "x!z"

  test "a plain \\K scans on what the attempt consumed":
    # ``a\K`` reports an empty span at the end of every ``a`` it ran over, so
    # a loop testing the *reported* span for zero width steps a rune past it
    # and skips the next ``a``.  The attempt consumed a character, though, so
    # stepping on ``consumedSpan`` resumes right after it and every ``a`` is
    # matched.  Oniguruma's own ``gsub`` skips here and its ``split`` does
    # not; these answers are the self-consistent ones.
    var found: seq[string] = @[]
    for m in findAll("aaa", re("a\\K")):
      found.add $m.boundaries[0] & "@" & $m.startChar
    check found == @[$(1 .. 1) & "@0", $(2 .. 2) & "@1", $(3 .. 3) & "@2"]
    check replace("aaa", re("a\\K"), "!") == "a!a!a!"
    check replace(
      "aaa",
      re("a\\K"),
      proc(m: Match, s: string): string =
        "!",
    ) == "a!a!a!"
    check split("aaa", re("a\\K")) == @["a", "a", "a", ""]

  test "a positive lookaround keeps its \\K the way it keeps its captures":
    # Oniguruma lets a ``\K`` inside a positive assertion move the match
    # start even though the assertion itself is zero-width, so the kept
    # side of a lookaround is ``keepStart`` plus the captures, not the
    # captures alone.  Each of these answers ``0 .. 2`` when the scalar
    # rollback takes ``keepStart`` back down with ``pos``.
    check search("ab", re("(?=a\\Kb)ab")).boundaries[0] == 1 .. 2
    check search("ab", re("(?=(a)\\Kb)ab")).boundaries[0] == 1 .. 2
    check search("xab", re("x(?=a\\K)ab")).boundaries[0] == 2 .. 3
    check search("ab", re("ab(?<=a\\Kb)")).boundaries[0] == 1 .. 2
    check search("ab", re("ab(?<=(a)\\Kb)")).boundaries[0] == 1 .. 2
    # Alternation lookbehind commits through its own path: a fixed-length
    # alternative retries from the entry snapshot, a variable one writes the
    # rollback over the entry.  Both have to keep ``\K`` as well.
    check search("ab", re("ab(?<=(x)|a\\Kb)")).boundaries[0] == 1 .. 2
    check search("aab", re("aab(?<=(x)|a+\\Kb)")).boundaries[0] == 2 .. 3
    # A negative assertion keeps nothing, ``\K`` included.
    check search("ab", re("(?!a\\Kq)ab")).boundaries[0] == 0 .. 2
    check search("ab", re("(?<!a\\Kq)ab")).boundaries[0] == 0 .. 2
    # And the kept ``\K`` is still undone by backtracking past it: the
    # lookahead holds here, ``q`` does not, and the optional group is
    # skipped -- with the start it moved restored along with the captures.
    check search("ab", re("(?:(?=a\\Kb)q)?ab")).boundaries[0] == 0 .. 2
    check search("ab", re("(?:(?=(a)\\Kb)q)?ab")).boundaries[0] == 0 .. 2

  test "a kept \\K never starts a match past its end":
    # The lookaround body can run past where the outer match stops, so the
    # ``\K`` it keeps can sit ahead of the end.  Oniguruma clamps the start
    # to the end there (``(pkeep > s) ? s : pkeep``); without that the span
    # comes out inverted, and an inverted empty match never advances.
    check search("ab", re("(?=ab\\K)a")).boundaries[0] == 1 .. 1
    check search("ab", re("(?=ab\\K)")).boundaries[0] == 0 .. 0
    check search("abc", re("(?=\\w+\\K)a")).boundaries[0] == 1 .. 1
    check search("ab", re("((?=ab\\K))a")).boundaries[0] == 1 .. 1
    check matchAt("ab", re("(?=ab\\K)a")).boundaries[0] == 1 .. 1
    var found: seq[string] = @[]
    for m in findAll("abab", re("(?=ab\\K)")):
      found.add $m.boundaries[0]
    check found == @[$(0 .. 0), $(2 .. 2)]
    check replace("abababab", re("(?=ab\\K)"), "!") == "!ab!ab!ab!ab"
    check replace("abcdefx", re("(?=abcdef\\K)a"), "!") == "a!bcdefx"

  test "a kept \\K behind the scan start still lets a scan advance":
    # A ``\K`` inside a lookbehind is the one shape whose kept start lands
    # *behind* the position the attempt began at.  The reported span is then
    # wide where the scan stood still, so a loop stepping on it would hand
    # back the same match forever and slice text it has already written out.
    # ``Match.startChar`` is what the attempt consumed, and the scanning
    # loops step on that instead of on what the match reports.
    let m = search("abab", re("(?<=\\Kab)"), start = 2)
    check m.boundaries[0] == 0 .. 2
    check m.startChar == 2
    var found: seq[string] = @[]
    for x in findAll("abab", re("(?<=\\Kab)")):
      found.add $x.boundaries[0]
    check found == @[$(0 .. 2), $(2 .. 4)]
    # Reported start behind ``pos``: the text it covers is already in the
    # output, so the match replaces only what is left of it -- rather than
    # slicing backwards, which is a ``RangeDefect``, not a catchable error.
    check replace("abcabcabc", re("c(?<=\\Kabcabc)"), "!") == "!!"
    check replace(
      "abcabcabc",
      re("c(?<=\\Kabcabc)"),
      proc(m: Match, s: string): string =
        "!",
    ) == "!!"
    check split("abcabcabc", re("c(?<=\\Kabcabc)")) == @["", "", ""]
    # A zero-width match whose reported start sits behind where the scan
    # stood.  The character the scan stepped over to make progress is not the
    # output's to keep on its own: the next match reports over it, and
    # replacing it is what ``split`` says too -- its fields here are
    # ``["xx", "", ""]`` and its separators ``2..4`` and ``4..6``, which do
    # lay end to end over the subject.  The case above is the one where they
    # do not: separators ``0..6`` and ``3..9`` over nine bytes.
    check replace("xxabab", re("(?<=\\Kab)"), "!") == "xx!!"
    check replace(
      "xxabab",
      re("(?<=\\Kab)"),
      proc(m: Match, s: string): string =
        "!",
    ) == "xx!!"
    check split("xxabab", re("(?<=\\Kab)")) == @["xx", "", ""]

  test "the scan's divergence from Ruby over a \\K is pinned, not accidental":
    # The scanning API steps on what an attempt *consumed*; Ruby's ``scan``
    # and ``gsub`` step on what it *reported*.  The two rules cannot differ
    # for a pattern that reports what it consumed, so the divergence is
    # confined to ``\K``.  These are the shapes it takes, recorded against
    # Ruby 3.4 so that moving one is a visible edit rather than a silent one.
    # ``tests/test_fuzz_oniguruma.nim`` compares single matches only and
    # cannot reach any of this; these expectations are the contract.
    #
    # Agreeing, because the report ends where the attempt did:
    check replace("ab", re("a\\Kb"), "!") == "a!" # Ruby: "a!"
    # Agreeing, because a report *at* the end of the attempt leaves the scan
    # where the report leaves it -- a nullable prefix changes neither rule:
    check replace("aaa", re("a*\\K"), "!") == "aaa!" # Ruby: "aaa!"
    check replace("x1y", re("[0-9]*\\K"), "!") == "!x1!y!" # Ruby: "!x1!y!"
    # Parting, because the report is shorter than the attempt: Ruby resumes
    # at the report and so steps over text this scan still reaches.
    check replace("aa", re("a\\K"), "!") == "a!a!" # Ruby's gsub: "a!a"
    check replace("aaa", re("a\\K"), "!") == "a!a!a!" # Ruby's gsub: "a!aa!"
    var n = 0
    for _ in findAll("aaa", re("a\\K")):
      n += 1
    check n == 3 # Ruby's scan: 2
    # ``split`` is not on the parting list: it takes the text *before* a
    # report, which is where Ruby's ``split`` takes its field from too.
    check split("aaa", re("a\\K")) == @["a", "a", "a", ""] # Ruby: the same
    # And where Ruby has no answer to diverge from.  A report that reaches
    # back behind the scan leaves Ruby with nowhere to resume that is ahead
    # of where it stood: ``"aa".scan(/(?<=\Ka)/)`` never terminates there and
    # ``"abcabcabc".gsub(/c(?<=\Kabcabc)/, "!")`` raises ``ArgumentError:
    # negative string size``.  Stepping on the consumed span ends both.
    check replace("aa", re("(?<=\\Ka)"), "!") == "!!"
    check replace("abcabcabc", re("c(?<=\\Kabcabc)"), "!") == "!!"

  test "a \\K after a nullable prefix is one answer, not two":
    # ``a*\K`` reports an empty span at the end of what it ran over.  Resuming
    # there is right -- the attempt consumed text -- but the next attempt
    # stands exactly where that empty report sat, matches empty, and reports
    # it again.  The second attempt is a different attempt with the same
    # answer, and a scan hands it back once.  Oniguruma agrees on all of
    # these; Ruby's ``scan`` is the reference for the spans.
    var found: seq[string] = @[]
    for m in findAll("aaa", re("a*\\K")):
      found.add $m.boundaries[0]
    check found == @[$(3 .. 3)]
    check replace("aaa", re("a*\\K"), "!") == "aaa!"
    check split("aaa", re("a*\\K")) == @["aaa", ""]
    check replace("aaa", re(".*\\K"), "!") == "aaa!"
    check replace("abcabc", re("\\w*\\K"), "!") == "abcabc!"
    # The suppression is of a repeat, not of every empty report: an empty
    # report at a position the previous one did not cover is its own answer.
    found = @[]
    for m in findAll("x1y", re("[0-9]*\\K")):
      found.add $m.boundaries[0]
    check found == @[$(0 .. 0), $(2 .. 2), $(3 .. 3)]
    check replace("a b", re("\\s*\\K"), "!") == "!a !b!"
    check replace("a_b", re("\\s*\\K"), "!") == "!a!_!b!"
    found = @[]
    for m in findAll("aabab", re("a*\\K(?=b)")):
      found.add $m.boundaries[0]
    check found == @[$(2 .. 2), $(4 .. 4)]

  test "a scanner drives a hand-written loop the way findAll does":
    # ``MatchScanner`` is what the library's own loops run on, and what a
    # caller running its own scan needs: the cursor rule is not a function of
    # one match's span, so it cannot live in the caller.
    let ctx = newMatchContext()
    for (subject, pattern) in [
      ("a1 b22 c333", "\\d+"),
      ("aaa", "a*\\K"),
      ("aaa", "a\\K"),
      ("x1y", "[0-9]*\\K"),
      ("xxabab", "(?<=\\Kab)"),
      ("abc", "x*"),
    ]:
      let rx = re(pattern)
      var sc = initMatchScanner(subject)
      var m: Match
      var spans: seq[Span]
      while scanNext(sc, ctx, subject, rx, m):
        spans.add m.matchSpan
      var expected: seq[Span]
      for em in findAll(subject, rx):
        expected.add em.matchSpan
      check spans == expected

  test "a scanner owns both cursors and is bound to one subject":
    # The scan cursor and the output cursor move through the scanner, not
    # through a loop that has to remember to move them, and the offsets they
    # hold mean nothing in another string.
    let ctx = newMatchContext()
    let rx = re("\\d+")
    let subject = "a1b22c"
    var sc = initMatchScanner(subject)
    var m: Match
    check scanNext(sc, ctx, subject, rx, m)
    check m.matchSpan == 1 .. 2
    check sc.takeGap(m) == 0 .. 1
    expect ValueError:
      discard scanNext(sc, ctx, "zzz", rx, m)
    expect ValueError:
      discard initMatchScanner("abc", start = 4)
    expect ValueError:
      discard initMatchScanner("abc", start = -1)
    # A match that is not there covers nothing and moves nothing.
    var missing: Match
    check sc.takeGap(missing) == 2 .. 2

  test "a yielded match is already stepped past":
    # The scan cursor a caller reads beside a match is the one the next
    # attempt starts from, and not the one that produced the match it is
    # holding: the step is made before the match is handed over, so the scan
    # never stands at a position it has already answered from.
    let ctx = newMatchContext()
    let rx = re("\\d")
    let subject = "1a2"
    var sc = initMatchScanner(subject)
    var m: Match
    check scanNext(sc, ctx, subject, rx, m)
    check m.matchSpan == 0 .. 1
    check sc.scanPos == 1
    check scanNext(sc, ctx, subject, rx, m)
    check m.matchSpan == 2 .. 3
    check sc.scanPos == 3
    check not scanNext(sc, ctx, subject, rx, m)
    # A match that ends the subject leaves the scan standing at the end of
    # it, rather than back where the attempt behind that match began.
    let kept = re("b\\K")
    var sc2 = initMatchScanner("ab")
    check scanNext(sc2, ctx, "ab", kept, m)
    check m.matchSpan == 2 .. 2
    check sc2.scanPos == 2

  test "a scan's reported ends never decrease":
    # This is what makes one step of memory enough to catch a repeated
    # answer: a report ends where its attempt did, and attempts only ever
    # start further along, so an answer left behind cannot come back.
    for (subject, pattern) in [
      ("aaa", "a*\\K"),
      ("aaa", "a\\K"),
      ("x1y", "[0-9]*\\K"),
      ("xxabab", "(?<=\\Kab)"),
      ("abcabcabc", "c(?<=\\Kabcabc)"),
      ("aabab", "a*\\K(?=b)"),
      ("abc", "x*"),
    ]:
      var prev = -1
      for m in findAll(subject, re(pattern)):
        check m.boundaries[0].b >= prev
        prev = m.boundaries[0].b

  test "consumedSpan answers like matchSpan on a match that is not there":
    # Both are reached for before the ``found`` test in an ordinary loop, and
    # an ``IndexDefect`` out of one of them is not catchable by default.
    var m: Match
    check consumedSpan(m) == UnsetSpan
    check matchSpan(m) == UnsetSpan
    let miss = search("abc", re("z"))
    check consumedSpan(miss) == UnsetSpan
    let hit = search("xab", re("a\\Kb"))
    check consumedSpan(hit) == 1 .. 3
    check matchSpan(hit) == 2 .. 3

  test "a failed negative assertion keeps its captures but not its \\K":
    # ``condHolds`` keeps the captures of a negative-lookahead condition whose
    # body matched, since the branch it selects may read them.  The assertion
    # did not hold, though, so nothing else of the body survives -- a ``\K``
    # it ran over least of all.
    check search("ab", re("a(?(?!\\Kb)x|b)")).boundaries[0] == 0 .. 2

  test "\\R matches CRLF":
    let m = search("\r\n", re("\\R"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "\\R matches LF":
    let m = search("\n", re("\\R"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "\\R does not match letter":
    let m = search("a", re("\\R"))
    check not m.found

  test "\\N matches non-newline":
    let m = search("a", re("\\N"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "\\N does not match newline":
    let m = search("\n", re("\\N"))
    check not m.found

  test "\\O matches newline":
    let m = search("\n", re("\\O"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "\\Q..\\E treats metacharacters as literals":
    let m = search(".+*", re("\\Q.+*\\E"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "\\Q..\\E pipe is literal":
    let m = search("a|b", re("\\Qa|b\\E"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "\\Q..\\E no alternation":
    let m = search("a", re("\\Qa|b\\E"))
    check not m.found

suite "Python syntax and extended mode":
  test "(?P<name>) named capture":
    let m = search("admin@server", re("(?P<user>\\w+)@(?P<host>\\w+)"))
    check m.found
    check captureText(m, "user", "admin@server", re("(?P<user>\\w+)@(?P<host>\\w+)")) ==
      some("admin")
    check captureText(m, "host", "admin@server", re("(?P<user>\\w+)@(?P<host>\\w+)")) ==
      some("server")

  test "(?P=name) backreference":
    let m = search("'hi'", re("(?P<q>['\"])\\w+(?P=q)"))
    check m.found
    check m.boundaries[0] == 0 .. 4

  test "(?P>name) subroutine call":
    let m = search("42", re("(?P<d>\\d)(?P>d)"))
    check m.found
    check m.boundaries[0] == 0 .. 2

  test "(?x) free-spacing mode":
    let m = search("abc", re("(?x) a  b  # comment\n  c"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "(?x) digits with comment":
    let m = search("123", re("(?x) \\d+ # digits\n"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "(?x:) scoped extended mode":
    let m = search("abc", re("(?x: a  b )c"))
    check m.found
    check m.boundaries[0] == 0 .. 3

suite "Find longest (?L)":
  test "alternation takes longest":
    let m = search("abc", re("(?L)a|abc"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "greedy already longest":
    let m = search("hello", re("(?L)\\w+"))
    check m.found
    check m.boundaries[0] == 0 .. 5

  test "alternation vs quantifier longest":
    let m = search("aab", re("(?L)a+|aab"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "optional takes longest":
    let m = search("x", re("(?L)x?"))
    check m.found
    check m.boundaries[0] == 0 .. 1

  test "scoped form takes longest":
    let m = search("abc", re("(?L:a|abc)"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "scoped form behind transparent wrappers takes longest":
    let m1 = search("abc", re("(?:(?L:a|abc))"))
    check m1.found
    check m1.boundaries[0] == 0 .. 3
    let m2 = search("abc", re("(?i:(?L:a|abc))"))
    check m2.found
    check m2.boundaries[0] == 0 .. 3

  test "scoped mixed flags take longest":
    let m1 = search("abc", re("(?L-i:a|abc)"))
    check m1.found
    check m1.boundaries[0] == 0 .. 3
    let m2 = search("abc", re("(?IL:a|abc)"))
    check m2.found
    check m2.boundaries[0] == 0 .. 3

  test "scoped form preserves captures of longest match":
    let r = re("(?L:(a)|(abc))")
    let m = search("abc", r)
    check m.found
    check m.boundaries[0] == 0 .. 3
    check captureText(m, 2, "abc") == some("abc")

suite "Edge cases":
  test "multiple \\K uses last position":
    let m = search("abc", re("a\\Kb\\Kc"))
    check m.found
    check m.boundaries[0] == 2 .. 3

  test "(?L) with lookahead in alternation":
    let m = search("abc", re("(?L)(?=abc)a|abc"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "(?L) preserves captures of longest match":
    let r = re("(?L)(a)|(abc)")
    let m = search("abc", r)
    check m.found
    check m.boundaries[0] == 0 .. 3
    check captureText(m, 2, "abc") == some("abc")

  test "fixed repetition {n}":
    let m1 = search("aaaa", re("a{3}"))
    check m1.found
    check m1.boundaries[0] == 0 .. 3
    let m2 = search("aa", re("a{3}"))
    check not m2.found

  test "replace with nonexistent group reference raises":
    expect RegexError:
      discard replace("abc", re("(\\w+)"), "$2")

  test "findAll on empty subject with zero-width pattern":
    var count = 0
    for m in findAll("", re("^")):
      inc count
    check count == 1

  test "search with negative start raises":
    expect ValueError:
      discard search("abc", re("a"), start = -1)

  test "search with start beyond length raises":
    expect ValueError:
      discard search("abc", re("a"), start = 10)

  test "search with start at length is valid":
    let m = search("abc", re(""), start = 3)
    check m.found

  test "matchAt with negative pos raises":
    expect ValueError:
      discard matchAt("abc", re("a"), pos = -1)

  test "matchAt with pos beyond length raises":
    expect ValueError:
      discard matchAt("abc", re("a"), pos = 10)

  test "searchBackward with start beyond length raises":
    expect ValueError:
      discard searchBackward("abc", re("a"), start = 10)

  test "large exact quantifier does not stack overflow":
    let s = "a".repeat(5000)
    let m = search(s, re("a{5000}"), stepLimit = 0)
    check m.found

  test "a repetition count in the tens of thousands still matches":
    # The matcher used to give up past an internal repetition cap and report
    # no match on a subject that plainly matches; the count is now bounded
    # only by the subject.
    let s = "a".repeat(20000)
    let m = search(s, re("a{20000}"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 20000

suite "Grapheme mode (?y{w})":
  test "(?y{w}) dot matches word segment":
    # In word mode, . matches one word segment per UAX#29
    let m = search("hello world", re("(?y{w})."))
    check m.found
    check m.boundaries[0] == 0 .. 5 # "hello" is one word segment

  test "(?y{w}) scoped mode":
    let m = search("hello", re("(?y{w}:.)"))
    check m.found
    check m.boundaries[0] == 0 .. 5

  test "(?y{w}) \\X matches word segment":
    let m = search("hello world", re("(?y{w})\\X"))
    check m.found
    check m.boundaries[0] == 0 .. 5

  test "\\Y not-grapheme-boundary between base chars":
    # Two base characters have a grapheme boundary between them, so \Y should NOT match
    let m = search("ab", re("a\\Yb"))
    check not m.found

  test "\\Y matches inside grapheme cluster":
    # e + combining acute accent = one grapheme cluster
    # Between 'e' and combining mark there is no grapheme boundary, so \Y matches
    let m = search("e\xCC\x81", re("e\\Y"))
    check m.found

  test "\\y matches between base chars":
    # Sanity check: \y (grapheme boundary) matches between two base chars
    let m = search("ab", re("a\\yb"))
    check m.found

  test "(?y{w}) letters that are also Extended_Pictographic stay one word":
    # U+1F170 and U+1F171 are Word_Break=ALetter as well as
    # Extended_Pictographic; WB5 keeps them in one segment.
    let m = search("\u{1F170}\u{1F171}", re("(?y{w})."))
    check m.found
    check m.boundaries[0] == 0 .. 8

  test "(?y{w}) WB3c holds for ALetter Extended_Pictographic":
    # ZWJ x Extended_Pictographic: no boundary after the ZWJ.
    let m = search("\u200D\u{1F170}", re("(?y{w})."))
    check m.found
    check m.boundaries[0] == 0 .. 7

suite "ASCII flag modifiers":
  test "(?W) makes \\w ASCII-only":
    let m1 = search("\xe3\x81\x82", re("\\w")) # hiragana 'a'
    check m1.found
    let m2 = search("\xe3\x81\x82", re("(?W)\\w"))
    check not m2.found

  test "(?D) makes \\d ASCII-only":
    # Arabic-Indic digit U+0661
    let m1 = search("\xD9\xA1", re("\\d"))
    check m1.found
    let m2 = search("\xD9\xA1", re("(?D)\\d"))
    check not m2.found

  test "(?S) makes \\s ASCII-only":
    # U+00A0 no-break space
    let m1 = search("\xC2\xA0", re("\\s"))
    check m1.found
    let m2 = search("\xC2\xA0", re("(?S)\\s"))
    check not m2.found

  test "(?I) ASCII-only case insensitive":
    let m = search("A", re("(?Ii)a"))
    check m.found

  test "(?W:...) scoped":
    let m = search("\xe3\x81\x82", re("(?W:\\w)"))
    check not m.found

  test "(?W) affects \\b word boundary":
    # hiragana is a word char in Unicode mode, so \b matches before it
    let m1 = search("\xe3\x81\x82", re("\\b"))
    check m1.found
    # With (?W), hiragana is not a word char, and string start is non-word too => no boundary
    let m2 = search("\xe3\x81\x82", re("(?W)\\b"))
    check not m2.found

  test "re() with flag set argument":
    let m = search("\xe3\x81\x82", re("\\w", {rfAsciiWord}))
    check not m.found

  test "(?P) restricts \\d to ASCII":
    let m = search("\xD9\xA1", re("(?P:\\d)"))
    check not m.found

suite "POSIX character classes (extended)":
  test "[:alnum:] matches letter and digit":
    check search("a", re("[[:alnum:]]")).found
    check search("5", re("[[:alnum:]]")).found
    check not search(" ", re("[[:alnum:]]")).found

  test "[:ascii:] matches ASCII only":
    check search("z", re("[[:ascii:]]")).found
    check not search("\xC3\xA9", re("[[:ascii:]]")).found # é

  test "[:blank:] matches space and tab":
    check search(" ", re("[[:blank:]]")).found
    check search("\t", re("[[:blank:]]")).found
    check not search("\n", re("[[:blank:]]")).found

  test "[:cntrl:] matches control char":
    check search("\x01", re("[[:cntrl:]]")).found
    check not search("a", re("[[:cntrl:]]")).found

  test "[:digit:] matches digit":
    check search("9", re("[[:digit:]]")).found
    check not search("a", re("[[:digit:]]")).found

  test "[:graph:] matches printable non-space":
    check search("!", re("[[:graph:]]")).found
    check not search(" ", re("[[:graph:]]")).found

  test "[:lower:] matches lowercase":
    check search("a", re("[[:lower:]]")).found
    check not search("A", re("[[:lower:]]")).found

  test "[:upper:] matches uppercase":
    check search("A", re("[[:upper:]]")).found
    check not search("a", re("[[:upper:]]")).found

  test "[:print:] matches printable including space":
    check search(" ", re("[[:print:]]")).found
    check search("a", re("[[:print:]]")).found
    check not search("\x01", re("[[:print:]]")).found

  test "[:space:] matches whitespace":
    check search("\n", re("[[:space:]]")).found
    check search("\t", re("[[:space:]]")).found
    check not search("a", re("[[:space:]]")).found

  test "[:xdigit:] matches hex digits":
    check search("f", re("[[:xdigit:]]")).found
    check search("A", re("[[:xdigit:]]")).found
    check not search("g", re("[[:xdigit:]]")).found

  test "[:word:] matches word chars":
    check search("_", re("[[:word:]]")).found
    check search("a", re("[[:word:]]")).found
    check not search(" ", re("[[:word:]]")).found

  test "[:^digit:] negated POSIX class":
    check search("a", re("[[:^digit:]]")).found
    check not search("5", re("[[:^digit:]]")).found

suite "Nested character classes and Unicode properties":
  test "nested character class [[a-z]]":
    check search("m", re("[[a-z]]")).found
    check not search("5", re("[[a-z]]")).found

  test "nested negated class [[^0-9]]":
    check search("a", re("[[^0-9]]")).found
    check not search("5", re("[[^0-9]]")).found

  test "nested class in intersection [a-z&&[[^aeiou]]]":
    check search("b", re("[a-z&&[[^aeiou]]]")).found
    check not search("e", re("[a-z&&[[^aeiou]]]")).found

  test "\\p{Lu} uppercase letter":
    check search("A", re("\\p{Lu}")).found
    check not search("a", re("\\p{Lu}")).found

  test "\\p{Ll} lowercase letter":
    check search("a", re("\\p{Ll}")).found
    check not search("A", re("\\p{Ll}")).found

  test "\\p{Nd} decimal digit":
    check search("7", re("\\p{Nd}")).found
    check not search("a", re("\\p{Nd}")).found

  test "\\p{Sc} currency symbol":
    check search("$", re("\\p{Sc}")).found
    check not search("a", re("\\p{Sc}")).found

  test "\\p{Upper} matches the derived Uppercase property":
    check search("A", re("\\p{Upper}")).found
    check search("\u00c0", re("\\p{Upper}")).found # LATIN CAPITAL LETTER A WITH GRAVE
    # Other_Uppercase, i.e. uppercase but not category Lu
    check search("\u2160", re("\\p{Upper}")).found # ROMAN NUMERAL ONE (Nl)
    check search("\u24b6", re("\\p{Upper}")).found # CIRCLED LATIN CAPITAL A (So)
    check not search("a", re("\\p{Upper}")).found
    check not search("\u2170", re("\\p{Upper}")).found # SMALL ROMAN NUMERAL ONE
    check not search("\u01c5", re("\\p{Upper}")).found # Dz WITH CARON (Lt)
    check not search("1", re("\\p{Upper}")).found

  test "\\p{Lower} matches the derived Lowercase property":
    check search("a", re("\\p{Lower}")).found
    check search("\u00e0", re("\\p{Lower}")).found # LATIN SMALL LETTER A WITH GRAVE
    # Other_Lowercase, i.e. lowercase but not category Ll
    check search("\u2170", re("\\p{Lower}")).found # SMALL ROMAN NUMERAL ONE (Nl)
    check search("\u00aa", re("\\p{Lower}")).found # FEMININE ORDINAL INDICATOR (Lo)
    check search("\u02b0", re("\\p{Lower}")).found # MODIFIER LETTER SMALL H (Lm)
    check not search("A", re("\\p{Lower}")).found
    check not search("\u2160", re("\\p{Lower}")).found # ROMAN NUMERAL ONE
    check not search("\u01c5", re("\\p{Lower}")).found # Dz WITH CARON (Lt)
    check not search("1", re("\\p{Lower}")).found

  test "\\P{Upper} is the complement of \\p{Upper}":
    check search("a", re("\\P{Upper}")).found
    check not search("A", re("\\P{Upper}")).found

  test "\\P{Lower} is the complement of \\p{Lower}":
    check search("A", re("\\P{Lower}")).found
    check not search("a", re("\\P{Lower}")).found

  test "(?P) restricts \\p{Upper}/\\p{Lower} to ASCII":
    check search("A", re("(?P:\\p{Upper})")).found
    check not search("\u00c0", re("(?P:\\p{Upper})")).found
    check search("a", re("(?P:\\p{Lower})")).found
    check not search("\u00e0", re("(?P:\\p{Lower})")).found

  test "\\p{Upper}/\\p{Lower} inside a character class":
    check search("A", re("[\\p{Upper}]")).found
    check not search("a", re("[\\p{Upper}]")).found
    check search("a", re("[\\p{Lower}0-9]")).found
    check search("5", re("[\\p{Lower}0-9]")).found
    check not search("A", re("[\\p{Lower}0-9]")).found

suite "Lookbehind edge cases":
  test "negative lookbehind at string start succeeds":
    let m = search("abc", re("(?<!x)abc"))
    check m.found
    check m.boundaries[0] == 0 .. 3

  test "lookbehind in alternation":
    let m = search("xb", re("(?<=x)b|(?<=y)b"))
    check m.found
    check m.boundaries[0] == 1 .. 2

  test "lookbehind alternation second branch":
    let m = search("yb", re("(?<=x)b|(?<=y)b"))
    check m.found
    check m.boundaries[0] == 1 .. 2

  test "lookbehind alternation no match":
    let m = search("zb", re("(?<=x)b|(?<=y)b"))
    check not m.found

  test "lookbehind with subroutine call containing absent raises":
    expect(RegexError):
      discard re("(?<=(?1))((?~abc))")

  test "lookbehind with named subroutine call containing absent raises":
    expect(RegexError):
      discard re("(?<=(?&g))(?<g>(?~abc))")

  test "lookahead with subroutine call containing absent is ok":
    discard re("(?=(?1))((?~x))")

  test "negative lookbehind with alternation of different fixed lengths":
    # "abcd" (4 bytes) matches before "ef"
    let m1 = search("abcdef", re("(?<!ab|abcd)ef"))
    check not m1.found

    # "ab" (2 bytes) matches before "ef"
    let m2 = search("abef", re("(?<!ab|abcd)ef"))
    check not m2.found

    # neither alternative matches before "ef"
    let m3 = search("xxef", re("(?<!ab|abcd)ef"))
    check m3.found
    check m3.boundaries[0] == 2 .. 4

  test "negative lookbehind with alternation same length":
    let m1 = search("abxy", re("(?<!ab|cd)xy"))
    check not m1.found

    let m2 = search("cdxy", re("(?<!ab|cd)xy"))
    check not m2.found

    let m3 = search("zzxy", re("(?<!ab|cd)xy"))
    check m3.found

suite "Extended mode edge cases":
  test "(?x) whitespace in character class is literal":
    let m = search(" ", re("(?x)[ ]"))
    check m.found

  test "(?-x) disables extended mode":
    let m = search(" ", re("(?x)(?-x: )"))
    check m.found

suite "Error handling":
  test "unmatched closing paren":
    expect(RegexError):
      discard re("a)")

  test "unterminated character class":
    expect(RegexError):
      discard re("[abc")

  test "empty alternation is valid":
    let m = search("", re("|"))
    check m.found

  test "dangling backslash":
    expect(RegexError):
      discard re("\\")

  test "invalid Unicode property name matches nothing":
    # Unknown property names don't raise - they simply never match
    let m = search("a", re("\\p{InvalidPropName}"))
    check not m.found

suite "replace edge cases":
  test "replace ${name with missing closing brace":
    expect ValueError:
      discard replace("abc", re("(\\w+)"), "${1")

  test "replace ${} empty name raises":
    expect RegexError:
      discard replace("abc", re("(\\w+)"), "${}")

  test "replace consecutive named templates":
    check replace("John Smith", re("(?<first>\\w+) (?<last>\\w+)"), "${first} ${last}") ==
      "John Smith"

  test "replace callback with zero-width match":
    let result = replace(
      "abc",
      re(""),
      proc(m: Match, s: string): string =
        "-",
    )
    check result == "-a-b-c-"

  test "replace callback returning empty string":
    let result = replace(
      "a1b2c",
      re("\\d"),
      proc(m: Match, s: string): string =
        "",
    )
    check result == "abc"

  test "replace nonexistent group raises":
    expect RegexError:
      discard replace("abc", re("(\\w+)"), "$2")

suite "split edge cases":
  test "split empty subject":
    check split("", re(",")) == @[""]

  test "split with zero-width pattern":
    # A zero-width separator consumes nothing, so the character the scan has
    # to step over to make progress stays in the field that follows.
    check split("abc", re("(?=\\w)")) == @["", "a", "b", "c"]

suite "graphemeMode backtracking":
  test "graphemeMode does not leak from failed quantifier":
    # (?y{g}) inside a quantifier body that backtracks should not leak
    let m = search("abc", re("(?:(?y{g})x)?abc"))
    check m.found

  test "graphemeMode scoped to flag group body":
    let m = search("abc", re("(?y{g}:x?)abc"))
    check m.found

suite "firstCharInfo optimization":
  test "findAll with fcByte optimization":
    var matches: seq[string]
    for m in findAll("xaxbxaxc", re("xa")):
      matches.add captureText(m, 0, "xaxbxaxc").get("")
    check matches == @["xa", "xa"]

  test "findAll with fcAnchorStart optimization":
    var count = 0
    for m in findAll("abc", re("\\Aabc")):
      inc count
    check count == 1

  test "fcByte optimization with multibyte UTF-8":
    let s = "\xC3\xA9\xC3\xA9a"
    let m = search(s, re("a"))
    check m.found
    check m.boundaries[0].a == 4

  test "findAll no optimization (case insensitive)":
    var matches: seq[string]
    for m in findAll("AaBbAa", re("(?i)aa")):
      matches.add captureText(m, 0, "AaBbAa").get("")
    check matches == @["Aa", "Aa"]

  test "fcByteSet optimization with case-insensitive literal":
    let r = re("(?i)x")
    check r.firstCharInfo.kind == fcByteSet
    check uint8('x') in r.firstCharInfo.bytes
    check uint8('X') in r.firstCharInfo.bytes
    let m = search("abcXdef", r)
    check m.found
    check m.boundaries[0].a == 3

  test "fcByteSet optimization with alternation":
    let r = re("a|b|c")
    check r.firstCharInfo.kind == fcByteSet
    let m = search("xxcyy", r)
    check m.found
    check m.boundaries[0].a == 2

  test "fcByteSet from character class":
    let r = re("[xyz]")
    check r.firstCharInfo.kind == fcByteSet
    let m = search("abcydef", r)
    check m.found
    check m.boundaries[0].a == 3

  test "the hint for a case-insensitive digit stays tight":
    let r = re("(?i)1")
    check r.firstCharInfo.kind == fcByte
    check r.firstCharInfo.byte == uint8('1')

suite "leadRun scan skip":
  # A broken disqualifier silently drops matches, so each is pinned twice:
  # the ``leadRun`` verdict and, where a wrong skip drops a match, the match.
  proc skips(pattern: string, flags: RegexFlags = {}): bool =
    re(pattern, flags).leadRun != nil

  proc all(subject, pattern: string, flags: RegexFlags = {}): seq[string] =
    for m in findAll(subject, re(pattern, flags)):
      result.add captureText(m, 0, subject).get("")

  test "the plain shape skips the leading run":
    check skips("\\w+=")
    # Attempt at 0 ends its run at 3, so the scan resumes at 3.
    check all("aaa bbb=", "\\w+=") == @["bbb="]

  test "zero-width wrappers are peeled":
    check skips("(\\w*)=")
    check skips("(?:\\w*)=")
    check skips("(?<n>\\w*)=")
    check all("aaa bbb=", "(\\w*)=") == @["bbb="]
    check all("aaa bbb=", "(?:\\w*)=") == @["bbb="]
    check all("aaa bbb=", "(?<n>\\w*)=") == @["bbb="]

  test "a bounded maximum is refused":
    # Bounded: on "AAAAA=" the match starts at 1, inside the skipped run.
    check not skips("A{0,4}=")
    check all("AAAAA=", "A{0,4}=") == @["AAAA="]

  test "a lazy repeat does not qualify, a possessive one does":
    # Lazy stops at the shortest run, so a later start is not refuted by the
    # first attempt's failure; possessive has one end for every start inside.
    check not skips("\\w*?=")
    check skips("\\w*+=")
    check all("aaa bbb=", "\\w*+=") == @["bbb="]
    check skips("\\w++=")
    check all("aaa bbb=", "\\w++=") == @["bbb="]

  test "a fixed leaf may lead only while it is a subset of the body":
    check skips("[A-Za-z_][A-Za-z0-9_]*=")
    check all("ab cd=", "[A-Za-z_][A-Za-z0-9_]*=") == @["cd="]
    # Leaves accept digits the body rejects, so on "ab0cd=" the match starts at 1.
    check not skips("[A-Za-z0-9_][A-Za-z0-9_][a-z]*=")
    check all("ab0cd=", "[A-Za-z0-9_][A-Za-z0-9_][a-z]*=") == @["b0cd="]

  test "case folding disqualifies a leading leaf":
    # Folding adds members the atoms never named, so the subset test is void.
    check not skips("[a-z][a-z]*=", {rfIgnoreCase})
    check not skips("(?i)[a-z][a-z]*=")
    # Bare repeat needs no byte set, so it still qualifies.
    check skips("[a-z]*=", {rfIgnoreCase})

  test "a variable-width body is refused":
    check not skips("\\R*=")
    check not skips("\\X*=")

  test "state carried across an attempt disqualifies the skip":
    check not skips("(\\w+)\\s*\\1") # backreference
    check not skips("(\\w+)(?(1)a|b)") # conditional
    check not skips("(\\w+)\\g<1>") # subexpression call
    check not skips("\\w+(?~x)") # absent operator
    check not skips("\\w+(*MAX{2})") # counted callout
    check not skips("\\G\\w+=") # \G anchor
    check all("aa aa", "(\\w+)\\s*\\1") == @["aa aa"]

  test "findLongest disqualifies the skip":
    # findLongest fails every start on purpose, so no skip applies.
    check not skips("\\w*=", {rfFindLongest})
    check not skips("(?L)\\w+=")
    check not skips("(?L:\\w+=)")

  test "a predicate atom in a leaf is refused":
    # Even ASCII-staying ``[\h]`` is refused: its table reports lead bytes
    # (a superset), which cannot prove exactness.
    check not skips("[\\h][0-9a-fA-F]*=")
    check not skips("[\\h][\\h]*=")
    check not skips("[a-f][\\h]*=")
    check all("ab 0f=", "[\\h][0-9a-fA-F]*=") == @["0f="]
    # Bare repeat needs no byte set, so a predicate body still qualifies.
    check skips("[\\h]*=")

  test "\\K only moves a successful attempt's start":
    check skips("\\w+\\K=")
    check all("aaa bbb=", "\\w+\\K=") == @["="]

  test "a mandatory repeat is looked through to its body's run":
    # ``(?:\w+\s+){3,}`` leads with ``\w+`` exactly as ``\w+\s+...`` does,
    # so the skip reaches the leading run through the outer repeat.
    check skips("(?:\\w+\\s+){3,}")
    check skips("(?:\\w+\\s+){3}") # the outer bound does not matter
    check skips("(?:\\w+\\s+){3,}?") # nor does a lazy outer
    check all("aa bb cc dd ", "(?:\\w+\\s+){3,}") == @["aa bb cc dd "]
    # Attempt at 0 gives back to 1 and 2, so starts inside "aaa" are refuted.
    check all("aaa bb=cc dd ee ", "(?:\\w+\\s+){3,}") == @["cc dd ee "]
    check all("aaa bb=cc dd ee ", "(?:\\w+\\s+){3}") == @["cc dd ee "]

  test "an optional repeat is not looked through":
    # ``{0,}`` need not run at all, so its body does not have to match at the
    # start: on "ab=" the match starts at 2, inside the run a skip would jump.
    check not skips("(?:\\w+\\s*){0,}=")
    check all("ab=", "(?:\\w+\\s*){0,}=") == @["ab="]
    check not skips("(?:\\w+\\s+)*=")

  test "an inverted-bound outer repeat is not looked through":
    # ``{n,m}`` with ``n > m`` is normalised by swapping the bounds, so
    # ``{1,0}`` need not run at all -- the same case as ``{0,1}``.
    check not skips("(?:\\w+\\s+){1,0}b=")
    check all("ab=", "(?:\\w+\\s+){1,0}b=") == @["b="]
    check all("ab=", "(?:\\w+\\s+){0,1}b=") == @["b="]
    # ``{3,1}`` turns possessive at match time, which is excluded by design.
    check not skips("(?:\\w+\\s+){3,1}=")

  test "a possessive outer repeat is not looked through":
    # Its body match is atomic, which the skip argument does not cover.
    check not skips("(?:\\w+\\s+)++=")
    # An atomic group is refused for the same reason, one level up.
    check not skips("(?>\\w+\\s+)+=")

  test "the body's own disqualifiers still apply through the outer repeat":
    check not skips("(?:\\w+?\\s+){2,}") # lazy inner repeat
    check not skips("(?:\\w{1,4}\\s+){2,}") # bounded inner repeat
    check not skips("(?:\\X+\\s+){2,}") # variable-width inner body
    check not skips("(?:(?=\\w)\\w+\\s+){2,}") # leading zero-width assertion
    check not skips("(?:(\\w+)\\s+){2,}\\1") # backreference

  test "a fixed leaf may lead at every nesting level":
    # The subset test runs once per level: ``a`` against the body of
    # ``[ab]+`` at the outer concat, ``b`` against the same body inside.
    check skips("a(?:b[ab]+c){2,}")
    check all("xabbcbabc", "a(?:b[ab]+c){2,}") == @["abbcbabc"]
    # The outer leaf accepts what the body rejects, so its starts differ.
    check not skips("c(?:b[ab]+c){2,}")
    check all("xcbbcbabc", "c(?:b[ab]+c){2,}") == @["cbbcbabc"]

suite "lead anchor prefilter":
  # The prefilter only refuses: a wrong verdict drops matches, so pin both
  # the compiled set and the matches found.
  proc leads(pattern: string, flags: RegexFlags = {}): set[AnchorKind] =
    re(pattern, flags).leadAnchors

  proc all(subject, pattern: string, flags: RegexFlags = {}): seq[string] =
    for m in findAll(subject, re(pattern, flags)):
      result.add captureText(m, 0, subject).get("")

  test "a leading assertion is collected":
    check leads("\\bresult\\b") == {akWordBoundary}
    check all("result presulting result", "\\bresult\\b") == @["result", "result"]
    check leads("^foo") == {akLineBegin}
    check leads("\\Afoo") == {akStringBegin}
    check leads("\\Bfoo") == {akNotWordBoundary}
    check all("foo xfoo", "\\Bfoo") == @["foo"]

  test "several assertions are one conjunction":
    check leads("^\\bfoo") == {akLineBegin, akWordBoundary}
    check all("foo\nxfoo\nfoo", "^\\bfoo") == @["foo", "foo"]
    # A contradiction refuses every start, which is the right answer.
    check leads("\\b\\Bfoo") == {akWordBoundary, akNotWordBoundary}
    check all("foo", "\\b\\Bfoo").len == 0

  test "\\K is never collected":
    # ``\K`` writes ``keepStart``, so it cannot run before the attempt.
    check leads("\\Kfoo") == {}
    check leads("\\b\\Kfoo") == {akWordBoundary}
    check all("foo xfoo", "\\b\\Kfoo") == @["foo"]

  test "zero-width company is walked past":
    check leads("(?=f)\\bfoo") == {akWordBoundary}
    check all("foo xfoo", "(?=f)\\bfoo") == @["foo"]
    check leads("\\b(?=f)foo") == {akWordBoundary}

  test "wrappers are peeled":
    check leads("(\\bfoo)") == {akWordBoundary}
    check leads("(?:\\bfoo)") == {akWordBoundary}
    check leads("(?<n>\\bfoo)") == {akWordBoundary}
    check leads("(?>\\bfoo)") == {akWordBoundary}
    check all("foo xfoo", "(\\bfoo)") == @["foo"]

  test "a mandatory repeat is looked through, an optional one is not":
    check leads("(?:\\bfoo\\s*){2,}") == {akWordBoundary}
    check leads("(?:\\bfoo\\s*){0,}") == {}
    check leads("(?:\\bfoo\\s*){1,0}") == {}
    check all("foo foo ", "(?:\\bfoo\\s*){2,}") == @["foo foo "]

  test "an alternation is not looked through":
    # Only one branch has to hold, so neither branch's assertion is required.
    check leads("\\bfoo|bar") == {}
    check all("xbar", "\\bfoo|bar") == @["bar"]
    check leads("(?:\\bfoo|\\bbar)") == {}

  test "an assertion after the first leaf is not collected":
    # It is not evaluated at the start position, so it proves nothing there.
    check leads("foo\\b") == {}
    check leads("f\\boo") == {}

  test "\\G is answered against the search start":
    check leads("\\Gfoo") == {akSearchBegin}
    check all("foofoo bar foo", "\\Gfoo") == @["foo", "foo"]
    check all("xfoofoo", "\\Gfoo").len == 0

  test "an end assertion may lead too":
    check leads("$") == {akLineEnd}
    check leads("\\z") == {akStringEnd}
    check leads("\\Z") == {akStringEndOrNewline}
    check all("ab\ncd", "$") == @["", ""]

  test "a grapheme boundary leads":
    check leads("\\yfoo") == {akGraphemeBoundary}
    check all("foo xfoo", "\\yfoo") == @["foo", "foo"]

  test "a negated grapheme boundary leads":
    check leads("\\Yfoo") == {akNotGraphemeBoundary}
    # No grapheme boundary holds between 'e' and the combining mark, so only
    # position 1 may match.
    check all("e\xCC\x81", "\\Y\xCC\x81") == @["\xCC\x81"]

  test "a reused context after a limit error still answers \\y":
    # ``\y`` reads ``graphemeMode``. A limit-aborted search may leave it dirty;
    # the prefilter must see the attempt-start value.
    let ctx = newMatchContext()
    var m: Match
    expect RegexLimitError:
      discard searchIntoCtx(ctx, "aaaa", re("(?y{w}:a+)"), m, stepLimit = 2)
    check searchIntoCtx(ctx, "aa", re("\\ya"), m, start = 1)
    check m.boundaries[0] == 1 .. 2

suite "UTF-8 validation":
  test "overlong 2-byte encoding (0xC0 0x80)":
    expect RegexError:
      discard re("\xC0\x80")

  test "overlong 2-byte encoding (0xC1 0xBF)":
    expect RegexError:
      discard re("\xC1\xBF")

  test "overlong 3-byte encoding (U+007F as 3 bytes)":
    expect RegexError:
      discard re("\xE0\x81\xBF")

  test "surrogate codepoint U+D800":
    expect RegexError:
      discard re("\xED\xA0\x80")

  test "surrogate codepoint U+DFFF":
    expect RegexError:
      discard re("\xED\xBF\xBF")

  test "overlong 4-byte encoding (U+FFFF as 4 bytes)":
    expect RegexError:
      discard re("\xF0\x8F\xBF\xBF")

  test "codepoint above U+10FFFF":
    expect RegexError:
      discard re("\xF4\x90\x80\x80")

  test "valid 2-byte (U+0080) accepted":
    let m = search("\xC2\x80", re("\xC2\x80"))
    check m.found

  test "valid 3-byte (U+0800) accepted":
    let m = search("\xE0\xA0\x80", re("\xE0\xA0\x80"))
    check m.found

  test "valid 4-byte (U+10000) accepted":
    let m = search("\xF0\x90\x80\x80", re("\xF0\x90\x80\x80"))
    check m.found

  test "valid 4-byte (U+10FFFF) accepted":
    let m = search("\xF4\x8F\xBF\xBF", re("\xF4\x8F\xBF\xBF"))
    check m.found

suite "Step limit":
  test "catastrophic backtracking hits step limit":
    expect(RegexLimitError):
      discard search("a".repeat(30), re("(a+)+b"))

  test "custom step limit":
    expect(RegexLimitError):
      discard search("a".repeat(10), re("(a+)+b"), stepLimit = 100)

suite "Match accessors":
  test "matchSpan returns overall match":
    let m = search("hello world", re("world"))
    check m.found
    check m.matchSpan.a == 6
    check m.matchSpan.b == 11

  test "captureSpan returns group span":
    let m = search("abc123", re("([a-z]+)(\\d+)"))
    check m.found
    check m.captureSpan(1) == 0 .. 3
    check m.captureSpan(2) == 3 .. 6

  test "groupCount returns number of capture groups":
    let m = search("abc", re("(a)(b)(c)"))
    check m.found
    check m.groupCount == 3

  test "groupCount is 0 with no captures":
    let m = search("abc", re("abc"))
    check m.found
    check m.groupCount == 0

suite "stepLimit for replace and split":
  test "replace with stepLimit":
    let r = re("\\w+")
    check replace("hello world", r, "X", stepLimit = 1_000_000) == "X X"

  test "replace with stepLimit raises on catastrophic pattern":
    let r = re("(a+)+$")
    expect(RegexLimitError):
      discard replace("aaaaaaaaaaaaaaaaaab", r, "X", stepLimit = 10_000)

  test "replace callback with stepLimit":
    let r = re("\\d+")
    let result = replace(
      "a1b2c3",
      r,
      proc(m: Match, s: string): string =
        "[" & s[m.matchSpan.a ..< m.matchSpan.b] & "]",
      stepLimit = 1_000_000,
    )
    check result == "a[1]b[2]c[3]"

  test "split with stepLimit":
    let r = re(",")
    check split("a,b,c", r, stepLimit = 1_000_000) == @["a", "b", "c"]

  test "split with stepLimit raises on catastrophic pattern":
    let r = re("(a+)+$")
    expect(RegexLimitError):
      discard split("aaaaaaaaaaaaaaaaaab", r, stepLimit = 10_000)

suite "zero-width match iteration":
  test "findAll with empty pattern matches at each position":
    var spans: seq[Span]
    for m in findAll("abc", re("")):
      spans.add m.matchSpan
    check spans.len == 4 # positions 0, 1, 2, 3
    check spans[0] == 0 .. 0
    check spans[1] == 1 .. 1
    check spans[2] == 2 .. 2
    check spans[3] == 3 .. 3

  test "replace with empty pattern inserts between chars":
    check replace("abc", re(""), "-") == "-a-b-c-"

  test "split with zero-width lookahead":
    check split("abc", re("(?=b)")) == @["a", "bc"]

suite "extractFirstChar with zero-width prefixes":
  test "word boundary before literal":
    let r = re("\\babc")
    check r.firstCharInfo.kind == fcByte
    check r.firstCharInfo.byte == uint8('a')

  test "lookahead before literal":
    let r = re("(?=x)xyz")
    check r.firstCharInfo.kind == fcByte
    check r.firstCharInfo.byte == uint8('x')

  test "line-start anchor before literal extracts literal":
    let r = re("^abc")
    # ^ is akLineBegin (not akStringBegin), so it's skipped as zero-width
    check r.firstCharInfo.kind == fcByte
    check r.firstCharInfo.byte == uint8('a')

  test "\\A anchor before literal gives fcAnchorStart":
    let r = re("\\Aabc")
    check r.firstCharInfo.kind == fcAnchorStart

  test "negative lookahead before literal":
    let r = re("(?!z)abc")
    check r.firstCharInfo.kind == fcByte
    check r.firstCharInfo.byte == uint8('a')

suite "searchBackward firstChar optimization":
  test "backward search finds rightmost literal match":
    let m = searchBackward("abcabc", re("abc"))
    check m.found
    check m.matchSpan == 3 .. 6

  test "backward search with anchored pattern":
    let m = searchBackward("xxxabc", re("\\Axxx"))
    check m.found
    check m.matchSpan == 0 .. 3

  test "backward search anchored pattern no match at non-zero":
    let m = searchBackward("abcxxx", re("\\Axxx"))
    check not m.found

  test "backward search finds rightmost single char":
    let m = searchBackward("aaabbb", re("b"))
    check m.found
    check m.matchSpan == 5 .. 6

  test "backward search with character class":
    let m = searchBackward("xxyz", re("[yz]"))
    check m.found
    check m.matchSpan == 3 .. 4

  test "backward search empty subject":
    let m = searchBackward("", re("a"))
    check not m.found

suite "deep patterns and long runs":
  test "deeply nested alternation raises RegexLimitError":
    # Build a pattern with deep nkConcat nesting using non-mergeable nodes:
    # (?:a.){N} expands to concat chains of [literal, charType] inside groups
    # that cannot be merged into nkString.
    #
    # 700 repetitions is ~2100 levels of nesting, which the recursive matcher
    # could not walk without running out of the stack budget. The machine
    # keeps the nesting on the heap, so the only thing that bounds this is
    # the pattern's own size.
    var pat = ""
    for i in 0 ..< 700:
      pat.add "(?:a.)"
    let subject = "ab".repeat(700)
    let r = re(pat)
    let m = search(subject, r, stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 1400

  test "long literal pattern works after nkString merge":
    var pat = ""
    for i in 0 ..< 500:
      pat.add "a"
    let subject = "a".repeat(500)
    let r = re(pat)
    let m = search(subject, r, stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 500

  test "normal nesting works fine":
    let m = search("abc", re("((a)(b)(c))"))
    check m.found
    check m.matchSpan == 0 .. 3

  test "a long run of absent markers neither aborts nor raises":
    # Consecutive absent ranges in one concat used to hold a native frame
    # per marker past every guard (stepLimit, byte budget, MaxCallDepth),
    # so 1500 of them killed a debug build with an uncatchable call depth
    # abort. The markers now walk iteratively: reaching this check at all
    # is most of the assertion, and the answer is an ordinary match.
    let m = search("b", re("(?~|a)".repeat(1500) & "b"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 1

suite "long repetition runs":
  # Runs long enough that the recursive matcher would have held a native frame
  # per repetition. What they check is the answer, not the mechanism: the
  # captures a long run leaves behind are the ones a short run would.
  test "a capturing body keeps the last repetition's capture":
    let m = search("a".repeat(5_000), re("(a)*"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 5_000
    check m.captureSpan(1) == 4_999 .. 5_000

  test "a multi-element body captures each of its groups":
    let m = search("ab".repeat(3_000), re("(?:(a)(b))*"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 6_000
    check m.captureSpan(1) == 5_998 .. 5_999
    check m.captureSpan(2) == 5_999 .. 6_000

  test "a body with internal choice runs as long as the subject":
    # A body that can match in more than one way needs real backtracking, so
    # the matcher used to answer this with RegexLimitError past a few hundred
    # repetitions. Its choice points are on the heap now, and the length that
    # bounds it is the subject's.
    let m = search("a".repeat(5_000) & "b", re("(?:a|aa)*b"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. 5_001

  test "an ambiguous body backtracks to the answer a short run gives":
    # (?:ab|a)* over "abab..." can take either branch at every step; the
    # trailing "c" forces the run to unwind and re-drive earlier repetitions,
    # which is the case a body committed to its first success answers wrongly.
    for n in [3, 50, 2_000]:
      let m = search("ab".repeat(n) & "c", re("(?:ab|a)*c"), stepLimit = 0)
      check m.found
      check m.matchSpan == 0 .. (2 * n + 1)

suite "subject length is not a matching limit":
  # A quantifier body with any internal choice used to cost native stack per
  # repetition, so these patterns answered RegexLimitError on subjects a user
  # would call short. The ceiling each one had is in its comment; the counts
  # here are two orders of magnitude past them.
  #
  # What is checked is the answer, not that no exception is raised: a run this
  # long has to reach the same span and the same captures a three-character
  # subject does.
  const Reps = 20_000

  test "(a|b)*c":
    # ceiling was 271 repetitions, 542 characters
    let m = search("ab".repeat(Reps) & "c", re("(a|b)*c"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * Reps + 1)
    check m.captureSpan(1) == (2 * Reps - 1) .. (2 * Reps)

  test "(x|y)+z":
    # ceiling was 271 repetitions
    let m = search("xy".repeat(Reps) & "z", re("(x|y)+z"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * Reps + 1)

  test "(?:a|b)*c":
    # ceiling was 321 repetitions
    let m = search("ab".repeat(Reps) & "c", re("(?:a|b)*c"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * Reps + 1)

  test "(?:a(?:b|c))*d":
    # ceiling was 303 repetitions; the choice is nested one level down
    let m = search("ab".repeat(Reps) & "d", re("(?:a(?:b|c))*d"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * Reps + 1)

  test "(?:ab|a)*c":
    # ceiling was 632 repetitions; both branches match at every step, so this
    # one needs the run to stay re-drivable, not just to fit
    let m = search("ab".repeat(Reps) & "c", re("(?:ab|a)*c"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * Reps + 1)

  test "a lazy alternation body repeats as long as the subject":
    let m = search("ab".repeat(Reps) & "c", re("(?:a|b)*?c"), stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * Reps + 1)

suite "captureSpan bounds checking":
  test "captureSpan out of range returns unset span":
    let m = search("abc", re("(a)"))
    check m.found
    # Valid group
    check m.captureSpan(1).a >= 0
    # Out of range
    check m.captureSpan(5).a < 0
    check m.captureSpan(5).b < 0

  test "captureSpan negative index returns unset span":
    let m = search("abc", re("(a)"))
    check m.found
    check m.captureSpan(-1).a < 0
    check m.captureSpan(-1).b < 0

suite "Backreference multi-char case fold":
  test "captured ß matches subject ss via forward fold":
    let m = search("ßss", re("(?i)(ß)\\1"))
    check m.found
    check m.matchSpan == 0 .. 4

  test "captured ss matches subject ß via reverse fold":
    let m = search("ssß", re("(?i)(ss)\\1"))
    check m.found
    check m.matchSpan == 0 .. 4

  test "captured ß matches subject ß (simple)":
    let m = search("ßß", re("(?i)(ß)\\1"))
    check m.found
    check m.matchSpan == 0 .. 4

  test "mismatched capture and subject fails":
    let m = search("ßab", re("(?i)(ß)\\1"))
    check not m.found

  test "ascii-only flag disables multi-char fold in backref":
    # (?iI): ignore-case combined with ASCII-only fold. ß ↔ ss
    # must not fold because ß is outside ASCII.
    let m = search("ßss", re("(?iI)(ß)\\1"))
    check not m.found

  test "ASCII backref still works under ignore-case":
    let m = search("abcABC", re("(?i)(abc)\\1"))
    check m.found
    check m.matchSpan == 0 .. 6

suite "replace invalid reference":
  test "numeric reference out of range raises":
    expect RegexError:
      discard replace("abc", re("(\\w+)"), "$99")

  test "numeric reference beyond captureCount raises":
    expect RegexError:
      discard replace("abc", re("(\\w+)"), "$2")

  test "unknown named reference raises":
    expect RegexError:
      discard replace("abc", re("(?<n>\\w+)"), "${unknown}")

  test "defined group that did not participate returns empty":
    # (a)|(b) — only one branch captures; referring to the other is legal.
    check replace("b", re("(a)|(b)"), "[$1]") == "[]"

  test "callback form is unaffected":
    check replace(
      "ab",
      re("(\\w)"),
      proc(m: Match, s: string): string =
        "x",
    ) == "xx"

  test "valid numeric reference still works":
    check replace("abc", re("(\\w+)"), "[$1]") == "[abc]"

  test "valid named reference still works":
    check replace("abc", re("(?<n>\\w+)"), "[${n}]") == "[abc]"

suite "Mutual recursion detection":
  test "direct self-recursion (?<a>(?&a)) detected":
    expect RegexError:
      discard re("(?<a>(?&a))")

  test "mutual 2-cycle (?<a>(?&b))(?<b>(?&a)) detected":
    expect RegexError:
      discard re("(?<a>(?&b))(?<b>(?&a))")

  test "mutual 3-cycle a→b→c→a detected":
    expect RegexError:
      discard re("(?<a>(?&b))(?<b>(?&c))(?<c>(?&a))")

  test "self-recursion with consumption is valid":
    let r = re("(?<a>x(?&a)?)")
    check r.captureCount == 1

  test "mutual recursion with consumption is valid":
    let r = re("(?<a>x(?&b)?)(?<b>y(?&a)?)")
    check r.captureCount == 2

  test "mutual recursion via optional quantifier is valid":
    let r = re("(?<a>(?&b)?x)(?<b>(?&a)?y)")
    check r.captureCount == 2

  test "self-recursion under an inverted range is valid":
    # ``{2,0}`` behaves like ``{0,2}``, so the body may be skipped and the
    # call is not forced without consuming input.
    let r = re("(?<a>(?&a){2,0})")
    check r.captureCount == 1

  test "recursion after an inverted range is detected":
    # ``b{2,0}`` can match empty, so the call is reachable without consuming
    # input.
    expect RegexError:
      discard re("(?<a>b{2,0}(?&a))")

  test "recursion after an inverted range is detected before a consumer":
    expect RegexError:
      discard re("(?<a>b{2,0}(?&a)c)")

  test "recursion behind a conditional with no else branch detected":
    # /(?(<a>)x)/ matches empty when the condition is false, so \g<a> is
    # reachable without consuming input.  Oniguruma rejects this pattern with
    # ONIGERR_NEVER_ENDING_RECURSION.
    expect RegexError:
      discard re("(?<a>(?(<a>)x)\\g<a>)")

  test "recursion behind a conditional with an else branch is valid":
    # Both branches consume, so the call is only reached after input.
    let r = re("(?<a>(?(<a>)x|y)\\g<a>?)")
    check r.captureCount == 1

suite "matchSpan on non-matching result":
  test "matchSpan returns UnsetSpan when not found":
    let m = search("abc", re("zzz"))
    check not m.found
    check m.matchSpan == UnsetSpan
    check m.matchSpan.a == -1
    check m.matchSpan.b == -1

  test "matchSpan UnsetSpan exported constant":
    check UnsetSpan.a == -1
    check UnsetSpan.b == -1

suite "MatchContext-based API":
  test "searchIntoCtx parity with search on simple literal":
    let ctx = newMatchContext()
    var m: Match
    check searchIntoCtx(ctx, "xxab", re("ab"), m)
    let ref0 = search("xxab", re("ab"))
    check m.found == ref0.found
    check m.boundaries == ref0.boundaries

  test "searchIntoCtx not-found clears boundaries":
    let ctx = newMatchContext()
    var m: Match
    check not searchIntoCtx(ctx, "abc", re("zzz"), m)
    check not m.found
    check m.boundaries.len == 0
    check m.matchSpan == UnsetSpan

  test "reusing ctx across many calls matches fresh search":
    let ctx = newMatchContext()
    var m: Match
    let subjects = @["hello world", "foo bar baz", "", "a", "abcabc"]
    let patterns = @[re("\\w+"), re("o.+"), re("a"), re("z?"), re("(abc)+")]
    for s in subjects:
      for r in patterns:
        let expected = search(s, r)
        discard searchIntoCtx(ctx, s, r, m)
        check m.found == expected.found
        check m.boundaries == expected.boundaries

  test "reusing ctx across patterns with different capture counts":
    let ctx = newMatchContext()
    var m: Match
    # Pattern with 3 groups first, then 1, then 0 — boundaries must shrink/grow.
    check searchIntoCtx(ctx, "2026-04-29", re("(\\d+)-(\\d+)-(\\d+)"), m)
    check m.boundaries.len == 4
    check captureText(m, 1, "2026-04-29").get == "2026"
    check captureText(m, 3, "2026-04-29").get == "29"

    check searchIntoCtx(ctx, "abc123", re("(\\d+)"), m)
    check m.boundaries.len == 2
    check captureText(m, 1, "abc123").get == "123"

    check searchIntoCtx(ctx, "hello", re("ell"), m)
    check m.boundaries.len == 1
    check m.matchSpan.a == 1
    check m.matchSpan.b == 4

  test "reusing ctx with back-reference (captureStacks path)":
    # Back-references touch ctx.captureStacks; reusing must not leak stale
    # frames into the next call.
    let ctx = newMatchContext()
    var m: Match
    let r = re("(\\w+) \\1")
    check searchIntoCtx(ctx, "go go", r, m)
    check captureText(m, 1, "go go").get == "go"
    # Different subject, no back-ref match this time.
    check not searchIntoCtx(ctx, "go stop", r, m)
    # Same regex again should still work after a not-found run.
    check searchIntoCtx(ctx, "ha ha", r, m)
    check captureText(m, 1, "ha ha").get == "ha"

  test "reusing ctx between back-ref pattern and plain pattern":
    let ctx = newMatchContext()
    var m: Match
    discard searchIntoCtx(ctx, "abab", re("(ab)\\1"), m)
    check m.found
    discard searchIntoCtx(ctx, "xxxx", re("x+"), m)
    check m.found
    check m.boundaries.len == 1
    check m.matchSpan.a == 0
    check m.matchSpan.b == 4

  test "reusing ctx across a deep run and the quiet runs after it":
    # The scratch buffers grow with the subject and are handed back only after
    # several small searches in a row. What is checked here is the answer, not
    # the capacity: every search past the growth and past the release must
    # agree with a fresh context. A policy regression that only wastes memory
    # stays invisible to this test by construction.
    let ctx = newMatchContext()
    var m: Match
    let deep = re("(a|b)*c")
    let big = "ab".repeat(20_000) & "c"
    check searchIntoCtx(ctx, big, deep, m, stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * 20_000 + 1)
    # More small searches than the quiet-run mark, each checked for parity so
    # a stale length surviving the release cannot hide.
    let smalls = @["abc", "xxab", "hello", "aab", ""]
    let pats = @[re("abc"), re("ab"), re("(a+?)(b)"), re("z"), re("")]
    for i in 0 ..< 20:
      for s in smalls:
        for r in pats:
          let expected = search(s, r)
          discard searchIntoCtx(ctx, s, r, m)
          check m.found == expected.found
          check m.boundaries == expected.boundaries
    # The deep run again after the release: re-growth must answer the same.
    check searchIntoCtx(ctx, big, deep, m, stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * 20_000 + 1)

  test "scratch buffers are handed back after quiet runs":
    # Upper-bound check on the release policy: a deep run grows the buffers
    # with the subject, and several small searches in a row must hand the
    # capacity back. Only the direction and the order of magnitude are
    # asserted, so retuning the keep marks does not break this test.
    let ctx = newMatchContext()
    var m: Match
    let deep = re("(a|b)*c")
    let big = "ab".repeat(20_000) & "c"
    check searchIntoCtx(ctx, big, deep, m, stepLimit = 0)
    check m.found
    let grown = scratchCaps(ctx)
    # The deep run must actually grow the buffers, or the comparison below
    # would pass vacuously.
    check grown.frames > 16_384
    check grown.choices > 16_384
    # More small searches than the quiet-run mark before the release fires.
    for i in 0 ..< 20:
      discard searchIntoCtx(ctx, "abc", re("abc"), m)
      check m.found
    let handedBack = scratchCaps(ctx)
    check handedBack.frames < grown.frames div 8
    check handedBack.choices < grown.choices div 8
    # The released buffers must still answer correctly.
    check searchIntoCtx(ctx, big, deep, m, stepLimit = 0)
    check m.found
    check m.matchSpan == 0 .. (2 * 20_000 + 1)

  test "searchIntoCtx with start offset":
    let ctx = newMatchContext()
    var m: Match
    check searchIntoCtx(ctx, "abXab", re("ab"), m, start = 1)
    check m.matchSpan.a == 3
    check m.matchSpan.b == 5

  test "searchIntoCtx raises on out-of-range start":
    let ctx = newMatchContext()
    var m: Match
    expect ValueError:
      discard searchIntoCtx(ctx, "abc", re("a"), m, start = -1)
    expect ValueError:
      discard searchIntoCtx(ctx, "abc", re("a"), m, start = 4)

  test "searchBackwardIntoCtx parity with searchBackward (default start)":
    let ctx = newMatchContext()
    var m: Match
    check searchBackwardIntoCtx(ctx, "abXab", re("ab"), m)
    let expected = searchBackward("abXab", re("ab"))
    check m.boundaries == expected.boundaries

  test "searchBackwardIntoCtx with explicit start":
    let ctx = newMatchContext()
    var m: Match
    check searchBackwardIntoCtx(ctx, "abXabYab", re("ab"), m, start = 5)
    let expected = searchBackward("abXabYab", re("ab"), start = 5)
    check m.boundaries == expected.boundaries

  test "searchBackwardIntoCtx raises on out-of-range start":
    let ctx = newMatchContext()
    var m: Match
    expect ValueError:
      discard searchBackwardIntoCtx(ctx, "abc", re("a"), m, start = 4)

  test "matchAtIntoCtx parity with matchAt":
    let ctx = newMatchContext()
    var m: Match
    check matchAtIntoCtx(ctx, "abc", re("ab"), m, pos = 0)
    check m.matchSpan.a == 0 and m.matchSpan.b == 2
    # No forward scan — must fail at pos=1.
    check not matchAtIntoCtx(ctx, "abc", re("ab"), m, pos = 1)
    check not m.found

  test "matchAtIntoCtx raises on out-of-range pos":
    let ctx = newMatchContext()
    var m: Match
    expect ValueError:
      discard matchAtIntoCtx(ctx, "abc", re("a"), m, pos = -1)
    expect ValueError:
      discard matchAtIntoCtx(ctx, "abc", re("a"), m, pos = 4)

  test "captures from previous call do not bleed after not-found":
    let ctx = newMatchContext()
    var m: Match
    check searchIntoCtx(ctx, "key=val", re("(\\w+)=(\\w+)"), m)
    check captureText(m, 1, "key=val").get == "key"
    check not searchIntoCtx(ctx, "no-equals", re("(\\w+)=(\\w+)"), m)
    check not m.found
    check m.boundaries.len == 0

  test "newMatchContext with pre-sized capacity behaves the same":
    let ctx = newMatchContext(maxCapCount = 3)
    var m: Match
    check searchIntoCtx(ctx, "1-2-3", re("(\\d)-(\\d)-(\\d)"), m)
    check m.boundaries.len == 4
    check captureText(m, 2, "1-2-3").get == "2"

  test "loop driven by searchIntoCtx finds all matches like findAll":
    let ctx = newMatchContext()
    var m: Match
    var spans: seq[Span]
    var pos = 0
    let subject = "a1 b22 c333"
    let r = re("\\d+")
    while pos <= subject.len:
      if not searchIntoCtx(ctx, subject, r, m, start = pos):
        break
      spans.add m.matchSpan
      # ``\d+`` has no ``\K``, so every match reports what it consumed and
      # the one-span cursor rule is enough here.  A scan that cannot count on
      # that is what ``MatchScanner`` is for.
      pos =
        if m.matchSpan.b == m.matchSpan.a:
          nextRunePos(subject, m.matchSpan.a)
        else:
          m.matchSpan.b
    var expected: seq[Span]
    for em in findAll(subject, r):
      expected.add em.matchSpan
    check spans == expected

  test "ctx reuse across regex with shrinking capture count keeps captureStacks capacity":
    # First regex has more capture groups; second has fewer.  A bug where
    # ``resetForRegex`` shrinks ``captureStacks`` would discard inner
    # ``seq`` capacity and corrupt subsequent reads if the third regex
    # regrows past the second's capCount.  This test exercises that
    # capacity-preservation contract by alternating sizes.
    let ctx = newMatchContext()
    var m: Match
    let big = re("(\\w)(\\w)(\\w)(\\w)") # captureCount = 4
    let small = re("(\\d)") # captureCount = 1
    check searchIntoCtx(ctx, "abcd", big, m)
    check m.boundaries.len == 5
    check captureText(m, 4, "abcd").get == "d"
    check searchIntoCtx(ctx, "x9y", small, m)
    check m.boundaries.len == 2
    check captureText(m, 1, "x9y").get == "9"
    # Switch back to a big regex — captureStacks must still service group 4.
    check searchIntoCtx(ctx, "wxyz", big, m)
    check m.boundaries.len == 5
    check captureText(m, 4, "wxyz").get == "z"

  test "lookbehind with capture inside, reused via ctx":
    # captureStacks state must not leak past the lookbehind boundary even
    # when the body captures and the same ctx is reused across calls.
    let ctx = newMatchContext()
    var m: Match
    let r = re("(?<=(\\d))\\w")
    check searchIntoCtx(ctx, "1a", r, m)
    check m.matchSpan == 1 .. 2
    check captureText(m, 1, "1a").get == "1"
    check not searchIntoCtx(ctx, "ab", r, m)
    check searchIntoCtx(ctx, "9z", r, m)
    check captureText(m, 1, "9z").get == "9"

  test "negative lookbehind with capture leaves outer captures intact":
    # Body captures inside a negative lookbehind must not be exposed when
    # the lookbehind succeeds (since negative => body did not match).
    let ctx = newMatchContext()
    var m: Match
    let r = re("(?<!(\\d))[a-z]")
    check searchIntoCtx(ctx, "9a b", r, m)
    # At pos 0 ('9'): not a-z, skip. pos 1 ('a'): preceded by '9', neg fails.
    # pos 2 (' '): not a-z. pos 3 ('b'): preceded by ' ', neg succeeds.
    check m.matchSpan == 3 .. 4
    check not captured(m, 1)

  test "lookahead containing capture, reused":
    let ctx = newMatchContext()
    var m: Match
    let r = re("(?=(\\d+))\\w+")
    check searchIntoCtx(ctx, "abc123def", r, m)
    check m.matchSpan == 3 .. 9
    check captureText(m, 1, "abc123def").get == "123"
    # Reuse: same regex, different subject — captureStacks must reset.
    check searchIntoCtx(ctx, "x4y", r, m)
    check captureText(m, 1, "x4y").get == "4"

  test "alternation in lookbehind with captures":
    let ctx = newMatchContext()
    var m: Match
    let r = re("(?<=(a)|(bb))X")
    check searchIntoCtx(ctx, "aX", r, m)
    check captureText(m, 1, "aX").get == "a"
    check not captured(m, 2)
    check searchIntoCtx(ctx, "bbX", r, m)
    check not captured(m, 1)
    check captureText(m, 2, "bbX").get == "bb"

  test "searchBackwardIntoCtx rejects start < -1":
    let ctx = newMatchContext()
    var m: Match
    expect ValueError:
      discard searchBackwardIntoCtx(ctx, "abc", re("a"), m, start = -2)
    expect ValueError:
      discard searchBackwardIntoCtx(ctx, "abc", re("a"), m, start = -100)

  test "searchBackward rejects start < -1":
    expect ValueError:
      discard searchBackward("abc", re("a"), start = -2)

suite "literal alternation trie":
  # A trie answers the alternation in place of its branches, so what it has to
  # preserve is the order the branches were written in -- the matcher owes the
  # continuation the *first* branch that matches here, not the longest -- and
  # it has to keep offering the rest on a backtrack.  Each test therefore
  # pins a shape where a plain "longest wins" or "first found wins" walk gives
  # a different answer, and ``hasTrie`` pins that the trie is what ran.

  proc hasTrie(pattern: string, flags: RegexFlags = {}): bool =
    proc walk(n: Node): bool =
      if n == nil:
        return false
      if n.kind == nkAlternation and n.altTrie != nil:
        return true
      for c in n.childNodes:
        if walk(c):
          return true
      false

    walk(re(pattern, flags).ast)

  test "a trie is built for an alternation of plain literals":
    check hasTrie("(int|int8|uint|float)")
    check hasTrie("a|bb")
    # One branch that is not a literal takes the whole alternation back to the
    # first-byte hints.
    check not hasTrie("(int|int8|\\w|float)")
    check not hasTrie("(int|int8|(u)|float)")
    # An empty branch is zero-width, which the trie does not express.
    check not hasTrie("(int|int8||float)")

  test "case folding takes the alternation off the trie":
    # Folding for the whole match is known when the tree is annotated, so no
    # trie is built at all.
    check not hasTrie("(int|int8|uint|float)", {rfIgnoreCase})
    # A ``(?i)`` inside the pattern is not: the tree is annotated once, under
    # no particular position's flags, so the trie is built and the matcher is
    # what refuses it -- which it must, since the branches would then have to
    # match folded.
    check hasTrie("(?i)(int|int8|uint|float)")
    check search("INT8", re("(?i)(int8|int)")).matchSpan == 0 .. 4
    check search("Int", re("(?i)(int8|int)")).matchSpan == 0 .. 3
    check search("uINT", re("(?i)(int|uint)\\b")).matchSpan == 0 .. 4
    check search("INT8", re("(int8|int)", {rfIgnoreCase})).matchSpan == 0 .. 4
    # Folding switched on past the alternation leaves it on the trie: the
    # scoped group restores the flag on the way out, so a backtrack into the
    # alternation is back to the bytes it was walked with.
    check hasTrie("(int|int8|uint|float)(?i:x)")
    check search("intX", re("(int|int8)(?i:x)")).matchSpan == 0 .. 4

  test "the first branch written wins, not the longest":
    check search("int8", re("(int|int8)")).matchSpan == 0 .. 3
    check search("int8", re("(int8|int)")).matchSpan == 0 .. 4

  test "a longer branch is still reachable through the continuation":
    # ``int`` matches first and the ``\b`` after it fails, so the alternation
    # has to hand back ``int8`` -- the walk found both and kept the order.
    let r = re("\\b(int|int8|int16)\\b")
    check search("int8 ", r).matchSpan == 0 .. 4
    check search("int16 ", r).matchSpan == 0 .. 5
    check search("int ", r).matchSpan == 0 .. 3
    check not search("int32 ", r).found

  test "every prefix is offered, deepest branch first where written first":
    let r = re("(abcd|abc|ab|a)x")
    check search("abcdx", r).matchSpan == 0 .. 5
    check search("abcx", r).matchSpan == 0 .. 4
    check search("abx", r).matchSpan == 0 .. 3
    check search("ax", r).matchSpan == 0 .. 2

  test "two branches spelling the same string are two branches":
    # The second is unreachable in the span it matches, but it is what the
    # group is left holding when the first is rolled back -- both name the
    # same text, so the answer is the same either way and the retry must not
    # crash or drop the match.
    let r = re("(ab|ab|abc)\\b")
    check search("abc ", r).matchSpan == 0 .. 3
    check search("ab ", r).matchSpan == 0 .. 2

  test "a branch is passed over when the subject does not spell it":
    let r = re("(cat|car|cab)")
    check not search("cap", r).found
    check search("carp", r).matchSpan == 0 .. 3

  test "multibyte literals walk the trie by bytes":
    let r = re("(日本|日本語|日)")
    check search("日本語", r).matchSpan == 0 .. 6
    check search("日本", r).matchSpan == 0 .. 6
    check search("日", r).matchSpan == 0 .. 3
    # The branch order decides again: 日本 is written first, so the longer
    # 日本語 is only reached when the continuation refuses the shorter one.
    check search("日本語", re("(日本|日本語)$")).matchSpan == 0 .. 9

  test "the group holds the branch the trie picked":
    let r = re("(int|int8|uint)\\b")
    let m = search("int8 ", r)
    check captureText(m, 1, "int8 ").get == "int8"
    let m2 = search("uint ", r)
    check captureText(m2, 1, "uint ").get == "uint"

  test "a quantified trie alternation repeats and gives back":
    check search("abab", re("^(?:ab|abab)+$")).matchSpan == 0 .. 4
    check search("aaa", re("^(?:a|aa)+$")).matchSpan == 0 .. 3
    check search("ab", re("^(?:ab|a)+b?$")).matchSpan == 0 .. 2

  test "findLongest takes the longest branch, not the first":
    check search("int8", re("(?L)(int|int8)")).matchSpan == 0 .. 4

  test "a trie alternation inside a lookaround":
    check search("int8", re("(?=int8)(int|int8)")).matchSpan == 0 .. 3
    # The assertion refuses position 0, so the scan takes the match one
    # position along rather than not at all.
    check search("into", re("(?!int|uint|float)\\w+")).matchSpan == 1 .. 4
    check search("byte", re("(?!int|uint|float)\\w+")).matchSpan == 0 .. 4

  test "an atomic trie alternation keeps the branch it took":
    # The atomic group refuses to hand ``int8`` back, so the ``\b`` after it
    # has nothing to retry and the whole match fails.
    check not search("int8 ", re("(?>int|int8)\\b")).found
    check search("int ", re("(?>int|int8)\\b")).matchSpan == 0 .. 3

  test "a branch the narrowed end cut short is still offered once it widens":
    # ``(?~|...)`` pulls ``subjectEnd`` in and ``(?~|)`` pushes it back out
    # again, so a branch that does not fit while the end is narrow has to stay
    # reachable afterwards.  The choice point therefore hangs on how many
    # branches are untried, never on which of them the subject spells under
    # the end at hand.
    check hasTrie("(?~|bX)(a|ab)(?~|)X")
    check search("abX", re("(?~|bX)(a|ab)(?~|)X")).matchSpan == 0 .. 3
    check search("abcd", re("(?~|c)(ab|abcd|aa|abx)(?~|)\\b")).matchSpan == 0 .. 4
    check search("abcabc", re("(?~|b)(?:a|abc|abcd)(?~|)ab")).matchSpan == 0 .. 5

  test "nothing matches at the end of the subject":
    check not search("in", re("(int|uint|float)")).found
    check not search("", re("(int|uint|float)")).found
