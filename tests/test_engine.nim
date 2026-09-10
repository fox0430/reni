import std/[unittest, strutils, options, unicode]

import ../reni
import ../reni/engine

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
      pos = advanceAfterMatch(subject, m.matchSpan)
      if pos < 0:
        break
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

suite "captureStacks isolation across lookaround":
  # A lookaround body's recursion-level capture frames must not survive the
  # zero-width boundary.  The result must not depend on whether an earlier
  # group in the same attempt happened to push a frame first, which is what
  # decides whether the length snapshot is taken eagerly or skipped.
  test "level backref cannot see a frame pushed inside a lookahead":
    check not search("aa", re("(?=(a))\\k<1+1>")).found
    check not search("aa", re("(a)(?=(a))\\k<2+1>")).found

  test "level backref cannot see a frame pushed inside a fixed lookbehind":
    check not search("aa", re("(?<=(a))\\k<1+1>")).found
    check not search("aa", re("(a)(?<=(a))\\k<2+1>")).found

  test "level backref cannot see a frame pushed inside an alternation lookbehind":
    check not search("aa", re("(?<=(a)|(bb))\\k<1+1>")).found
    check not search("xaa", re("(x)(?<=(a)|(bb))\\k<2+1>")).found

  test "level backref cannot see a frame pushed inside a variable lookbehind":
    check not search("aa", re("(?<=(a+))\\k<1+1>")).found
    check not search("xaa", re("(x)(?<=(a+))\\k<2+1>")).found

  test "level-0 backrefs still see lookaround captures":
    let m1 = search("aa", re("(?<=(a))\\k<1>"))
    check m1.found
    check m1.matchSpan == 1 .. 2
    let m2 = search("aa", re("(a)(?<=(a))\\k<2>"))
    check m2.found
    check m2.matchSpan == 0 .. 2
    let m3 = search("aa", re("(?=(a))\\k<1>"))
    check m3.found
    check m3.matchSpan == 0 .. 1

  test "isolation holds when the same ctx is reused":
    let ctx = newMatchContext()
    var m: Match
    let leaky = re("(?<=(a))\\k<1+1>")
    let plain = re("(?<=(a))\\k<1>")
    for _ in 0 .. 2:
      check not searchIntoCtx(ctx, "aa", leaky, m)
      check searchIntoCtx(ctx, "aa", plain, m)
      check m.matchSpan == 1 .. 2

suite "levelBackrefs gates the capture history":
  # ``Regex.levelBackrefs`` is what lets the matcher skip the per-group
  # capture history, and a recursion-level backreference is its only reader.
  # The isolation suite above asserts that level backrefs do *not* match, so
  # it stays green even if the flag were never set at all; these tests pin
  # the positive side: the flag itself, and a match that can only succeed
  # while the history is being written.
  test "a level backref matches through a recursion":
    # ``+1`` reads what the enclosing recursion level captured, which lives
    # only in the capture history.
    let numbered = re("(([a-z])\\g<1>?\\k<2+1>)")
    check levelBackrefs(numbered)
    check search("aa", numbered).matchSpan == 0 .. 2
    check search("abba", numbered).matchSpan == 1 .. 3
    check not search("abcd", numbered).found

    let named = re("(?<e>(?<n>[a-z])\\g<e>?\\k<n+1>)")
    check levelBackrefs(named)
    check search("aa", named).matchSpan == 0 .. 2
    check search("abba", named).matchSpan == 1 .. 3
    check not search("abcd", named).found

  test "the flag is set wherever the backref sits":
    for pattern in [
      "(a)(?=\\k<1+1>)", "(a)(?<=\\k<1+1>)", "(a)(?:x|\\k<1+1>)", "(a)(?>\\k<1+1>)",
      "(a)(?(1)\\k<1+1>)", "(a)(?~\\k<1+1>)", "(a)(\\k<1+1>)*", "(?<c>a)(?=\\k<c+1>)",
    ]:
      check levelBackrefs(re(pattern))

  test "the flag stays clear without a level backref":
    check not levelBackrefs(re("(a)\\1"))
    check not levelBackrefs(re("(?<c>a)\\k<c>"))
    check not levelBackrefs(re("(a)\\k<1+0>"))
    check not levelBackrefs(re("(?<c>a)\\k<c+0>"))

suite "malformed UTF-8 above U+10FFFF":
  # A lead byte of 0xF5 or more begins no character at all: it is one byte on
  # its own, the way Oniguruma's length table has it.  0xF4 does lead four
  # bytes, though, and the decode is the naive OR Oniguruma performs, so a
  # continuation byte of 0x90 or more still yields a value above U+10FFFF and
  # every ``unicodedb`` lookup has to be guarded against it.
  const OverMax = "\xFD\xBF\xBF\xBF\xBF\xBF"

  test "it is six one-byte characters":
    check search(OverMax, re("\\X")).matchSpan == 0 .. 1
    check search(OverMax, re(".")).matchSpan == 0 .. 1
    var n = 0
    for _ in findAll(OverMax, re(".")):
      inc n
    check n == 6

  test "property lookups do not abort":
    check not search(OverMax, re("\\p{L}")).found
    check not search(OverMax, re("\\p{Latin}")).found
    check not search(OverMax, re("\\p{InBasicLatin}")).found
    check not search(OverMax, re("\\p{Upper}")).found
    check not search(OverMax, re("[[:alpha:]]")).found

  test "\\w still reads the code point, so 0xFD is the letter U+00FD":
    # Every class above misses it — a one-byte character above U+007F reaches
    # neither container — but \\w bypasses them.
    check search(OverMax, re("\\w")).matchSpan == 0 .. 1
    check search(OverMax & "a", re("(?i)\\w+")).matchSpan == 0 .. 1

  test "case folding does not abort":
    check search("\xF5" & "a", re("(?i)[a-z]+")).matchSpan == 1 .. 2

  test "a 0xF4 lead can decode above U+10FFFF":
    # 0xF4 0xBF 0xBF 0xBF is U+13FFFF: a four-byte character by the length
    # table, past the ceiling by the decode.
    check search("\xF4\xBF\xBF\xBF", re("\\X")).matchSpan == 0 .. 4
    check not search("\xF4\xBF\xBF\xBF", re("\\w")).found
    check not search("\xF4\xBF\xBF\xBF", re("\\p{L}")).found

  test "word segmentation does not abort on one":
    # ``wordBreakProp`` is the lookup ``(?y{w})`` reaches, and an unguarded
    # one aborts with an uncatchable AssertionDefect rather than failing to
    # match.  Spans read off Oniguruma 6.9.10.
    check search("\xF4\xBF\xBF\xBF", re("(?y{w})\\X")).matchSpan == 0 .. 4
    check search("\xF4\x90\x80\x80a", re("(?y{w})\\X")).matchSpan == 0 .. 4
    check search("A\xF4\x7F\xA9\x0D", re("(?y{w})\\X")).matchSpan == 0 .. 1
    check search("a\xF4\xBF\xBF\xBFa", re("(?y{w}).")).matchSpan == 0 .. 1

suite "the \\Z anchor is reached the way Oniguruma reaches it":
  # ``onig_search`` resolves ANCHOR_SEMI_END_BUF by stepping back from the end
  # of the subject over continuation bytes, not by following the forward
  # ``encLen`` chain.  A ``'\\n'`` can sit inside the span its predecessor's
  # lead byte declares, and the chain steps straight over it; the jump is the
  # only thing that puts a start position there.  Spans read off Oniguruma
  # 6.9.10 (ONIG_SYNTAX_ONIGURUMA, UTF-8, onig_search).

  test "a newline hidden inside a lead byte's span is still the anchor":
    check search("\xC2\x0A", re("\\Z")).matchSpan == 1 .. 1
    check search("\xE0\xC2\x0A", re("\\Z")).matchSpan == 2 .. 2
    check search("\xF0a\x0A", re("\\Z")).matchSpan == 2 .. 2
    check search("\xC2\x0A", re("(?m)\\Z")).matchSpan == 1 .. 1

  test "an invalid lead byte still leaves the window off the chain":
    # ``"\xC0\x0A"``: the ``encLen`` chain from 0 runs 0-2, so position 1 is
    # only ever tried via the ``\Z`` window.  ``\Z`` matches at the newline
    # while ``\s\Z`` must consume a character there and does not match
    # ``"\xC0"``.  Read off Oniguruma 6.9.10 and pinned here: the
    # brute-force sweep below shares the window arithmetic, so a common-mode
    # slip of one byte either way would stay green there (too far right turns
    # 1..1 into 2..2; reaching 1 out of band invents 1..2).
    check search("\xC0\x0A", re("\\Z")).matchSpan == 1 .. 1
    check not search("\xC0\x0A", re("\\s\\Z")).found

  test "the jump leaves room for what the pattern consumes":
    check search("\xC2a\x0A", re("a\\Z")).matchSpan == 1 .. 2
    check search("\xC2a\x0A", re(".\\Z")).matchSpan == 0 .. 2

  test "a newline at offset 0 is not jumped to":
    check search("\x0A", re("\\Z")).matchSpan == 0 .. 0

  test "the anchors that get no jump keep the chain's answer":
    # ``$`` is ANCHOR_END_LINE in Oniguruma and ``\\z`` ANCHOR_END_BUF;
    # neither steps back to a newline the chain hid.
    check search("\xC2\x0A", re("$")).matchSpan == 2 .. 2
    check search("\xC2\x0A", re("\\z")).matchSpan == 2 .. 2

  test "\\A wins over \\Z, as it does in onig_search's anchor chain":
    check not search("\xC2\x0A", re("\\A\\Z")).found

  test "well-formed subjects are unaffected":
    check search("ab\x0A", re("\\Z")).matchSpan == 2 .. 2
    check search("ab", re("\\Z")).matchSpan == 2 .. 2
    check search("", re("\\Z")).matchSpan == 0 .. 0

suite "the \\Z jump never skips a start position":
  # The jump to the ``\\Z`` anchor is ``minSemiEnd - semiEndDMax``, so both
  # ends have to be right: the landing position must stay inside the subject,
  # and ``semiEndDMax`` must be a real upper bound on what the pattern eats.
  # Where it is not, the leftmost match is skipped or lost entirely.

  test "a truncated sequence cannot push the start past the end":
    # The lead byte declares four bytes and the subject holds three, so
    # right-adjusting the landing position ran off the end and the scan loop
    # never ran an attempt at all.
    check search("\xF0\x80\x80", re("a?\\Z")).matchSpan == 3 .. 3
    check search("\xF0\x80\x80", re("\\Z")).matchSpan == 3 .. 3
    check search("\xE0\x80", re("a?\\Z")).matchSpan == 2 .. 2
    # ``\z`` gets no jump and always agreed.
    check search("\xF0\x80\x80", re("a?\\z")).matchSpan == 3 .. 3

  test "a grapheme cluster has no byte bound":
    # ``\X`` runs over as many characters as the cluster holds, so no dmax
    # bounds it and the scan must start where it would without the jump.
    check re("\\X\\Z").semiEndDMax == -1
    check search("क्षि", re("\\X\\Z")).matchSpan == 6 .. 12
    check search("क्षि", re("\\X")).matchSpan == 0 .. 6

  test "so does a dot in grapheme or word mode":
    check re("(?y{g}).\\Z").semiEndDMax == -1
    check re("(?y{w}).\\Z").semiEndDMax == -1
    check search("क्षि", re("(?y{g}).\\Z")).matchSpan == 6 .. 12
    check search("क्षि", re("(?y{w}).\\Z")).matchSpan == 0 .. 12
    # Outside those modes a dot is one character wide again.
    check re(".\\Z").semiEndDMax == 4

suite "case folding widens what a pattern character can consume":
  # Under ``(?i)`` a character matches a fold equivalent with a wider encoding
  # (``k`` ↔ U+212A KELVIN SIGN) and the whole of its multi-character fold
  # (``ΐ`` ↔ ``ι``+``◌̈``+``◌́``, six bytes).  Both the ``\Z`` jump and the
  # lookbehind start positions are derived from that width.

  test "a multi-character fold is reachable from the \\Z anchor":
    check search("\xCE\xB9\xCC\x88\xCC\x81", re("(?i)ΐ\\Z")).matchSpan == 0 .. 6
    check search("i\xCC\x87", re("(?i)İ\\Z")).matchSpan == 0 .. 3
    check search("եւ", re("(?i)և\\Z")).matchSpan == 0 .. 4
    check search("ss", re("(?i)ß\\Z")).matchSpan == 0 .. 2

  test "so is a fold equivalent with a wider encoding":
    check search("\xE2\x84\xAA", re("(?i)k\\Z")).matchSpan == 0 .. 3
    check search("\xC5\xBF", re("(?i)s\\Z")).matchSpan == 0 .. 2

  test "an ASCII literal keeps its narrow bound":
    check re("(?i)a\\Z").semiEndDMax == 1
    check re("a\\Z").semiEndDMax == 1

  test "a lookbehind of a folding character is not fixed-length":
    check search("\xCE\xB9\xCC\x88\xCC\x81x", re("(?<=(?i)ΐ)x")).matchSpan == 6 .. 7
    check search("\xC5\xBFx", re("(?<=(?i)s)x")).matchSpan == 2 .. 3
    check search("\xE2\x84\xAAx", re("(?<=(?i)k)x")).matchSpan == 3 .. 4
    # A pair the subject can match with one folded character, and back.
    check search("ßx", re("(?<=(?i)ss)x")).matchSpan == 2 .. 3
    check search("ssx", re("(?<=(?i)ß)x")).matchSpan == 2 .. 3

suite "the reverse fold reads a run of literals, groups and all":
  # One subject character can stand for two or three pattern characters
  # (``ﬀ`` for ``ff``), and what makes a run a run is that the characters are
  # literals next to each other.  A plain ``(?:...)`` around some of them
  # says nothing about the language, so it may not break the run either --
  # Oniguruma 6.9.10 folds through one, and every case below was checked
  # against it.

  const Ff = "\u{FB00}" ## ﬀ, the one character that folds to ``ff``.

  test "a non-capturing group does not break the run":
    for pattern in [
      "(?i)ff", "(?i)f(?:f)", "(?i)(?:f)f", "(?i)(?:f)(?:f)", "(?i)(?:ff)",
      "(?i)f(?:(?:f))", "(?i)(?:f(?:f))", "(?i)a|f(?:f)",
    ]:
      check search(Ff, re(pattern)).matchSpan == 0 .. 3
    # Three characters, and the group may fall at either seam.
    for pattern in ["(?i)ffi", "(?i)ff(?:i)", "(?i)f(?:fi)", "(?i)(?:ff)i"]:
      check search("\u{FB03}", re(pattern)).matchSpan == 0 .. 3

  test "but everything that is not a plain group does":
    # Each of these is ``NONE`` in Oniguruma too.  A capture, a class, a
    # quantifier, an atomic or flag scope, an assertion or an empty group
    # all keep the two characters apart.
    for pattern in [
      "(?i)(f)(f)", "(?i)[f][f]", "(?i)f[f]", "(?i)f{2}", "(?i)f+", "(?i)(f)+",
      "(?i)ff?", "(?i)(?:f){1}", "(?i)f(?>f)", "(?i)f(?i:f)", "(?i)f(?m:f)",
      "(?i)f(?=f)f", "(?i)f\\Kf", "(?i)f(?:)f",
    ]:
      check not search(Ff, re(pattern)).found
    # The expansion has to be consumed whole: ``ffi`` is three characters and
    # two of them are not a match for ﬃ.
    check not search("\u{FB03}", re("(?i)ff")).found

  test "an unnamed capture demoted to a group still breaks it":
    # A named capture anywhere demotes the unnamed ones to ``(?:...)``, but
    # they were written as captures and Oniguruma keeps folding out of them.
    # So the group flattening has to happen before the demotion, not after.
    check not search("z" & Ff, re("(?i)(?<x>z)(f)(f)")).found
    check search("z" & Ff, re("(?i)(?<x>z)ff")).matchSpan == 0 .. 4
    check search("z" & Ff, re("(?i)(?<x>z)f(?:f)")).matchSpan == 0 .. 4

  test "the length analysis follows the run through the groups":
    # A run that can be matched by one wider character is no longer
    # fixed-length, so a lookbehind over it has to scan.  It used to depend
    # on the two ``f``s being written as bare neighbours.
    for pattern in ["(?<=(?i)ff)x", "(?<=(?i)f(?:f))x", "(?<=(?i)(?:f)(?:f))x"]:
      check search(Ff & "x", re(pattern)).matchSpan == 3 .. 4
    # And the ``\Z`` scan may not skip the only position it can start from.
    for pattern in ["(?i)ff\\Z", "(?i)f(?:f)\\Z", "(?i)(?:ff)\\Z"]:
      check search("x" & Ff, re(pattern)).matchSpan == 1 .. 4
    # Three characters: the window has to leave room for the fold width.
    for pattern in ["(?i)ffi\\Z", "(?i)f(?:fi)\\Z"]:
      check search("x" & "\u{FB03}", re(pattern)).matchSpan == 1 .. 4

  test "flattening a group leaves a pattern that folds nothing alone":
    # The wrapper goes whether or not ``(?i)`` is on, so the ordinary
    # readings have to survive it.
    check search("abc", re("a(?:b)c")).matchSpan == 0 .. 3
    check search("abc", re("(?:a)(?:b)(?:c)")).matchSpan == 0 .. 3
    check not search("ac", re("a(?:b)c")).found
    check search("abc", re("a(?:b|x)c")).matchSpan == 0 .. 3
    check search("axc", re("a(?:b|x)c")).matchSpan == 0 .. 3
    check search("abbc", re("a(?:b){2}c")).matchSpan == 0 .. 4
    check search("ab", re("(?:a)(?:b)")).matchSpan == 0 .. 2
    # A backreference still counts the captures it always did.
    check search("abab", re("(?:x)?(ab)\\1")).matchSpan == 0 .. 4

suite "extractFirstChar does not look past a consuming ^ subtree":
  # A subtree such as (^a*) reports fcLineStart yet can consume input, so the
  # following child's byte is not the pattern's first byte.  Using it as a
  # scan hint skipped every valid start position.

  test "capture containing ^ and a quantifier still matches":
    let m = search("aab", re("(^a*)b"))
    check m.found
    check m.matchSpan == 0 .. 3
    check m.boundaries[1].a == 0
    check m.boundaries[1].b == 2

  test "hint is fcLineStart, not the byte after the subtree":
    let r = re("(^a*)b")
    check r.firstCharInfo.kind == fcLineStart

  test "per-alternative hints are sound too":
    let m = search("aab", re("z|(^a*)b"))
    check m.found
    check m.matchSpan == 0 .. 3

  test "a bare ^ is still looked past for a byte hint":
    let r = re("^(a)b")
    check r.firstCharInfo.kind == fcByte
    check r.firstCharInfo.byte == uint8('a')

suite "a character's length comes from its lead byte alone":
  # Oniguruma reads the length out of a table indexed by the lead byte and
  # never checks the bytes after it.  ``encLen`` is that table, and the
  # matcher, both scan loops and the first-byte hints are all defined in
  # terms of it.

  test "a stray continuation byte is a character of its own":
    check search("\x0A\x85", re("\\N")).matchSpan == 1 .. 2
    check search("\x80", re("[^a]")).matchSpan == 0 .. 1
    check search("\xFF", re("\\w")).matchSpan == 0 .. 1

  test "the bytes after a lead byte are not checked":
    # 0xE3 declares three bytes, so "a" is swallowed into the character at 0.
    check search("\xE3\x81\x61", re(".")).matchSpan == 0 .. 3
    check not search("\xE3\x81\x61", re("[a]")).found

  test "0xF5 and up begin nothing, so they are one byte":
    check search("\xF5\x80\x80\x80", re(".")).matchSpan == 0 .. 1
    check search("\xF8", re(".")).matchSpan == 0 .. 1

  test "a sequence truncated by the end of the subject is no character":
    check not search("\xE0\x83", re(".")).found
    check not search("\xC0", re("\\X")).found
    check search("\x61\xC0", re("a")).matchSpan == 0 .. 1
    check not search("\x61\xC0", re("a.")).found

  test "the scan steps a whole character at a time":
    # 0xC0 declares two bytes, so offset 1 is inside it and never tried.
    check not search("\xC0\x31", re("[0-9]")).found
    check search("\xC0\xC0\x31", re("[0-9]")).matchSpan == 2 .. 3

suite "a class picks its container by encoded length":
  # A compiled class keeps its members below U+0080 in a byte set and the
  # rest in a code-point range list, and chooses between them by the
  # character's *length*, not its value.  So an overlong sequence that spells
  # an ASCII code point reaches the range list, which cannot hold it.

  test "an overlong sequence matches no ASCII class member":
    # "\xC0\xB1" spells U+0031 to the decoder, yet no ASCII class sees it.
    check not search("\xC0\xB1", re("[0-9]")).found
    check not search("\xC0\xB1", re("\\d")).found
    check not search("\xC0\xB1", re("\\h")).found
    check not search("\xC0\xB1", re("[[:xdigit:]]")).found
    check not search("\xC0\xB1", re("[[:ascii:]]")).found
    check not search("\xC0\xB1", re("\\x{31}")).found

  test "but negation still applies over the miss":
    check search("\xC0\xB1", re("[^1]")).matchSpan == 0 .. 2
    check search("\xC0\xB1", re("\\D")).matchSpan == 0 .. 2
    check search("\xC0\xB1", re("[^a]")).matchSpan == 0 .. 2

  test "an overlong sequence above U+007F does reach the ranges":
    # "\xE0\x83\xA9" spells U+00E9, which the range list can hold.
    check search("\xE0\x83\xA9", re("[\xC3\xA9]")).matchSpan == 0 .. 3
    check search("\xE0\x83\xA9", re("\\p{L}")).matchSpan == 0 .. 3
    check search("\xE0\x83\xA9", re("[[:alpha:]]")).matchSpan == 0 .. 3

  test "a one-byte character above U+007F reaches neither container":
    check not search("\x85", re("[\\x{85}]")).found
    check not search("\x80", re("[[:^ascii:]]")).found
    check not search("\xFE", re("[[:alpha:]]")).found

  test "except through a range written across the ASCII boundary":
    # Oniguruma fills the byte set up to 0xFF when the range starts below
    # U+0080, so [a-ÿ] accepts a stray 0xFF byte that [ÿ] rejects.
    check search("\xFF", re("[a-\xC3\xBF]")).matchSpan == 0 .. 1
    check search("\x80", re("[a-\xC3\xBF]")).matchSpan == 0 .. 1
    check not search("\xFF", re("[\xC3\xBF]")).found
    check not search("\x80", re("[\\x{80}-\\x{FF}]")).found

  test "\\w and \\W read the code point instead of a container":
    # OP_WORD tests the decoded value directly, so it disagrees with the
    # class spelling of the same thing.  Oniguruma does too.
    check search("\xC0\xB1", re("\\w")).matchSpan == 0 .. 2
    check not search("\xC0\xB1", re("[\\w]")).found
    check not search("\xC0\xB1", re("[[:word:]]")).found
    # 0xFE is U+00FE, a letter, so \\W rejects it while \\W accepts 0x80.
    check not search("\xFE", re("\\W")).found
    check search("\x80", re("\\W")).matchSpan == 0 .. 1

suite "a case-sensitive literal is compared as bytes":
  test "an overlong spelling of the same code point does not match":
    check not search("\xC0\xB1", re("1")).found
    check not search("\xE0\x83\xA9", re("\xC3\xA9")).found

  test "but (?i) compares code points, through the class containers":
    check search("\xE0\x83\xA9", re("(?i)\xC3\xA9")).matchSpan == 0 .. 3
    check not search("\xC1\xA1", re("(?i)a")).found

  test "a literal prefix is searched for as bytes, so it may start mid-character":
    # Oniguruma's exact-string optimization ignores character boundaries.
    check search("\xC0\x31", re("1")).matchSpan == 1 .. 2
    check search("\xC0\x61\x62", re("ab")).matchSpan == 1 .. 3
    # A pattern that gets no such prefix walks characters instead.
    check not search("\xC0\x31", re("[1]")).found
    check not search("\xC0\x31", re("1|2")).found

  test "a backreference is compared as bytes too":
    check search("\xC0\xB1\xC0\xB1", re("(.)\\1")).matchSpan == 0 .. 4
    check not search("\xC3\xA9\xE0\x83\xA9", re("(.)\\1")).found

  test "a run longer than the bulk-compare threshold is compared the same way":
    # A long run goes through ``memcmp``, a short one through a byte loop.
    let long = "abcdefghijklmnopqrst" # 20 bytes
    check search("xx" & long & "yy", re(long)).matchSpan == 2 .. 22
    check not search("xx" & long[0 ..^ 2] & "Zyy", re(long)).found
    check not search("Zbcdefghijklmnopqrst", re(long)).found
    check not search("abcdefghijklmnopqrsZ", re(long)).found
    # A run that reaches the threshold only with its multibyte characters.
    let wide = "日本語日本語" # 18 bytes
    check search("x" & wide, re(wide)).matchSpan == 1 .. 19
    # A subject of the run's own length, differing in one byte, so the
    # comparison itself has to reject it rather than the length check.
    check not search(wide[0 ..^ 4] & "\xE8\xAA\x9A", re(wide)).found
    check not search("x" & wide[0 ..^ 4] & "\xE8\xAA\x9A", re(wide)).found

  test "a run that runs off the end of the subject does not match":
    check not search("abcdefghijklmnop", re("abcdefghijklmnopq")).found
    check not search("abc", re("abcd")).found
    # Nor off the end of a narrowed subject: (?~|...) caps where it may read.
    check not search("abcdef", re("(?~|cd)abcdef")).found

  test "segmentation steps back over the same characters the matcher does":
    # The character before offset 2 is the stray ``\x80``, U+0080, a GCB
    # Control that GB4 breaks after — not the ``a`` a raw continuation-byte
    # walk would land on.
    var spans: seq[string]
    for m in findAll("a\x80\xCC\x81", re("\\X")):
      spans.add($m.matchSpan.a & ".." & $m.matchSpan.b)
    check spans == @["0..1", "1..2", "2..4"]

suite "the hints and the scans agree by construction":
  # The soundness property the whole first-byte machinery has to keep: the
  # scan may never skip a position at which a match begins.  Checked against
  # a brute-force walk of the same character chain, over every one- and
  # two-byte subject.

  # Every skip the forward scan makes is keyed on one of two things: the
  # anchor the pattern carries, or the first character it can begin with.  So
  # the patterns these invariants run over are *generated* from those two
  # axes instead of listed.  A list has to be remembered: the ``\Z`` skip
  # went in while the four-byte test below still had no ``\Z`` pattern, and
  # the skip could jump off the character chain unnoticed.  Generating means
  # a skip added for a new anchor is covered the day it lands.
  const Bodies = [
    "",
    "1",
    "a",
    "\xC3\xA9",
    "\\d",
    "\\D",
    "\\w",
    "\\W",
    "\\s",
    "\\S",
    "\\h",
    "\\H",
    ".",
    "\\N",
    "\\R",
    "\\X",
    "[0-9]",
    "[a-z]",
    "[^a]",
    "[^0-9]",
    "[[:ascii:]]",
    "[[:^ascii:]]",
    "[[:alpha:]]",
    "[[:xdigit:]]",
    "[a-\xC3\xBF]",
    "\\x{85}",
    "[\\x{85}]",
    "\\p{L}",
    "a|1",
    "\\d+",
    "(?i)A",
    "(?i)[A-Z]",
    "(?i)ff",
    "..",
    "\\s*",
    # Alternations whose branches carry *different* first-byte hints, so the
    # branch filter is live here and a branch it wrongly passes over shows up
    # as a disagreement with the brute-force walk (which runs a hintless AST,
    # see ``hintless``).
    "a|\xC3\xA9|1",
    "\\d|\\s|[^a]",
  ]

  const Anchors = ["", "\\z", "\\Z", "$", "^", "\\b", "\\B", "(?m)^", "(?m)$", "\\A"]
    ## ``\G`` is deliberately absent: it is defined against the position the
    ## search *started* from, so ``matchAt`` at any other position asks a
    ## different question and neither invariant below can read the answer.

  proc generatedPatterns(
      bodies: openArray[string] = Bodies, pairBodies: openArray[string] = Bodies
  ): seq[string] =
    ## ``Anchors`` x ``bodies``, with the anchor on each side.  An anchor that
    ## trails is what drives the ``\Z`` skip; one that leads is what drives
    ## the ``^`` skip.
    for a in Anchors:
      for b in bodies:
        if a.len == 0 and b.len == 0:
          continue
        result.add(a & b)
        if a.len > 0 and b.len > 0:
          result.add(b & a)
    # Then both at once, over ``pairBodies``.  A pattern anchored on one side
    # exercises one skip; the two skips only *meet* when a pattern carries
    # both, because the leading anchor re-bases the walk that the trailing
    # anchor's window starts from.  This axis multiplies by the square of
    # ``Anchors``, so a caller with a large subject set passes a smaller
    # ``pairBodies``.
    for lead in Anchors:
      if lead.len == 0:
        continue
      for tail in Anchors:
        if tail.len == 0:
          continue
        for b in pairBodies:
          result.add(lead & b & tail)

  let Patterns = generatedPatterns()

  proc withoutAltHints(n: Node) =
    ## Clear the alternation branch filter's hints in place.
    if n == nil:
      return
    if n.kind == nkAlternation:
      n.altFirst = @[]
    for c in n.childNodes:
      withoutAltHints(c)

  proc hintless(pattern: string): Regex =
    ## ``re`` with the branch filter's hints stripped, for the brute-force
    ## oracles below.  An oracle that ran the same ``altFirst`` through the
    ## same matcher could not check the filter: a hint that passes over a
    ## branch the pattern needs would be passed over by both sides, and the
    ## two would still agree.  These oracles must stay filter-independent.
    result = re(pattern)
    withoutAltHints(result.ast)

  proc semiEndWindowStart(subject: string, rx: Regex): int =
    ## Where ``onig_search`` begins for a ``\Z``-anchored pattern:
    ## ``min_semi_end - dmax``, adjusted right to a character head.
    ##
    ## The test spells this out rather than reading it off the engine because
    ## it is the *model* of which positions the scan visits, and on malformed
    ## input there is no subject-only rule to derive it from -- the window
    ## starts wherever the arithmetic lands, on the chain from 0 or not, and
    ## the walk that follows is the chain from there.  The skip-independent
    ## statement of the same property is the well-formed test above; this one
    ## is the model, and the differential run against Oniguruma is the
    ## backstop for both.
    if not rx.semiEndAnchored or subject.len == 0:
      return 0
    let dmax = rx.semiEndDMax
    if dmax < 0:
      return 0
    var preEnd = subject.len - 1
    while preEnd > 0 and (subject[preEnd].uint8 and 0xC0'u8) == 0x80'u8:
      dec preEnd
    let minSemiEnd =
      if subject[preEnd] == '\n':
        if preEnd == 0:
          return 0
        preEnd
      else:
        subject.len
    if minSemiEnd <= dmax:
      return 0
    result = minSemiEnd - dmax
    if result < subject.len:
      # Right-adjust to a character head.
      var q = result
      while q > 0 and (subject[q].uint8 and 0xC0'u8) == 0x80'u8:
        dec q
      if q < result:
        result = min(q + encLen(subject[q].uint8), subject.len)

  proc bruteForce(subject: string, rx: Regex): Match =
    ## Walk the character chain from the window start and take the first
    ## position that matches.  See [semiEndWindowStart] for why the walk does
    ## not simply begin at 0.
    var p = semiEndWindowStart(subject, rx)
    while p <= subject.len:
      let m = matchAt(subject, rx, p)
      if m.found:
        return m
      if p >= subject.len:
        break
      # Clamped, like ``nextScanPos``: a sequence truncated by the end must
      # not step over the end position, where the end anchors match.
      p = min(p + encLen(subject[p].uint8), subject.len)
    result.found = false

  proc bruteForceBackward(subject: string, rx: Regex): Match =
    ## Walk back from the end with Oniguruma's ``ONIGENC_STEP_BACK(.., 1)``
    ## and take the first position that matches.
    ##
    ## This is deliberately not ``bruteForce`` read in reverse.  Oniguruma
    ## steps forward along the ``encLen`` chain and back along the
    ## continuation-byte rule, and on malformed input the two visit different
    ## positions -- so ``search`` and ``searchBackward`` may disagree about
    ## whether a match exists at all, exactly as ``onig_search`` does.
    var p = subject.len
    while true:
      let m = matchAt(subject, rx, p)
      if m.found:
        return m
      if p <= 0:
        break
      var q = p - 1
      while q > 0 and (subject[q].uint8 and 0xC0'u8) == 0x80'u8:
        dec q
      p = q
    result.found = false

  proc subjects(): seq[string] =
    const Bytes = [
      '\x00', '\x0A', '\x31', '\x61', '\x7F', '\x80', '\xA9', '\xBF', '\xC0', '\xC1',
      '\xC2', '\xC3', '\xDF', '\xE0', '\xE3', '\xEF', '\xF0', '\xF4', '\xF5', '\xF8',
      '\xFE', '\xFF',
    ]
    for b in Bytes:
      result.add($b)
      for b2 in Bytes:
        result.add($b & $b2)

  proc wellFormedSubjects(): seq[string] =
    ## Well-formed UTF-8 only, so every character start is on the chain and
    ## the scan owes the caller *every* matching position -- no model of
    ## which ones it visits is needed to check it.  The pieces are the ones
    ## the skips key on: a newline for ``^``, an end for ``\Z``, wide
    ## characters for the character walk, and ﬀ / ß for the case folds whose
    ## width the length analysis has to bound.
    const Pieces =
      ["", "a", "1", "\n", " ", "\u{00E9}", "\u{3042}", "\u{FB00}", "\u{00DF}"]
    for p1 in Pieces:
      for p2 in Pieces:
        result.add(p1 & p2)
        for p3 in Pieces:
          result.add(p1 & p2 & p3)

  test "search agrees with matchAt at every position, on well-formed input":
    # The property every skip has to keep, stated without reference to how
    # the scan walks: ``search`` returns the first position ``matchAt``
    # accepts.  A skip that jumps too far fails this whatever it keys on,
    # which is what makes it worth having next to the brute-force walk --
    # that one has to be taught about each new skip, and this one does not.
    for pattern in Patterns:
      let rx = re(pattern)
      let plain = hintless(pattern)
      for subject in wellFormedSubjects():
        var want = -1
        for p in 0 .. subject.len:
          # On well-formed input a match can only begin at a character start.
          if p < subject.len and (subject[p].uint8 and 0xC0'u8) == 0x80'u8:
            continue
          if matchAt(subject, plain, p).found:
            want = p
            break
        let got = search(subject, rx)
        check got.found == (want >= 0)
        if got.found and want >= 0:
          check got.matchSpan.a == want

  test "search never skips a position a brute-force walk would match":
    for pattern in Patterns:
      let rx = re(pattern)
      # The literal byte search deliberately reaches positions off the chain,
      # so it is a superset and only checked one way below.
      if rx.literalScan:
        continue
      let plain = hintless(pattern)
      for subject in subjects():
        let got = search(subject, rx)
        let want = bruteForce(subject, plain)
        check got.found == want.found
        if got.found and want.found:
          check got.matchSpan == want.matchSpan

  test "a literal scan only ever reaches more positions, never fewer":
    for pattern in Patterns:
      let rx = re(pattern)
      if not rx.literalScan:
        continue
      let plain = hintless(pattern)
      for subject in subjects():
        if bruteForce(subject, plain).found:
          check search(subject, rx).found

  test "searchBackward walks back the way Oniguruma steps back":
    # The backward scan owes the caller Oniguruma's positions, not the
    # forward scan's.  It is *not* checked against ``search`` here: the two
    # visit different positions on malformed input, and so do Oniguruma's.
    for pattern in Patterns:
      let rx = re(pattern)
      # The literal byte search reaches positions off either rule, so it is a
      # superset and only checked one way.
      if rx.literalScan:
        continue
      let plain = hintless(pattern)
      for subject in subjects():
        let got = searchBackward(subject, rx)
        let want = bruteForceBackward(subject, plain)
        check got.found == want.found
        if got.found and want.found:
          check got.matchSpan == want.matchSpan

  test "a literal backward scan only ever reaches more positions, never fewer":
    for pattern in Patterns:
      let rx = re(pattern)
      if not rx.literalScan:
        continue
      let plain = hintless(pattern)
      for subject in subjects():
        if bruteForceBackward(subject, plain).found:
          check searchBackward(subject, rx).found

  test "the end of the subject is a start position, however it is reached":
    # A sequence truncated by the end declares more bytes than are there.
    # Stepping by the declared length would jump over ``subject.len``, and
    # the anchors that only match there would stop matching.
    for pattern in ["\\z", "\\Z", "$"]:
      let rx = re(pattern)
      for subject in ["a\xC0", "a\xE3\x81", "\x00\x00\xC0", "\xF0\x9F"]:
        check search(subject, rx).matchSpan == subject.len .. subject.len
    # ``\b`` holds at the end after a word character, and the forward and
    # backward scans have to agree that the position is reachable.
    let wb = re("\\b")
    for subject in ["\x00\x00\xC0", "a\xC0"]:
      check searchBackward(subject, wb).matchSpan == subject.len .. subject.len
      check search(subject, wb, start = subject.len).matchSpan ==
        subject.len .. subject.len

  test "a zero-width match at a truncated tail stays inside the subject":
    # ``replace`` and ``split`` slice at the position ``nextRunePos`` hands
    # back, so it may never point past the end: it used to, and both raised.
    for pattern in ["x*", "\\N*", "\\G", "\\b", "\\B", "^", "(?m)^"]:
      let rx = re(pattern)
      for subject in ["a\xC0", "a\xE3\x81", "\xC0", "ab\xF0\x9F\x98"]:
        for m in findAll(subject, rx):
          check m.matchSpan.b <= subject.len
        discard replace(subject, rx, "-")
        discard split(subject, rx)

  test "findAll steps to the positions search would start at":
    # ``nextRunePos`` and ``nextScanPos`` share the length rule, so a
    # zero-width match never skips a position ``search`` would visit.
    for pattern in ["\\N*", "\\N", "a*", "[^a]*"]:
      let rx = re(pattern)
      for subject in subjects():
        var n = 0
        for m in findAll(subject, rx):
          check m.matchSpan.a >= 0
          check m.matchSpan.b <= subject.len
          inc n
          # A zero-width match must not stall: the iterator advances by
          # ``nextRunePos``, which follows the same length rule as the scan.
          check n <= subject.len + 1

  test "the ^ skip lands on a position the character walk visits":
    # ``^`` jumps to the next line instead of trying every position.  A
    # ``'\n'`` can sit inside the span its lead byte declares, so the byte
    # after it need not be on the chain the walk visits; landing there
    # reported matches at mid-character offsets that the backward scan --
    # which makes no such skip -- never offered.
    check not search("A\xE0\n\nB", re("^$")).found
    check not search("A\xE0\n\nB", re("^\\s*$")).found
    check not search("A\xE0\nB", re("^[^A]")).found
    # The skip still has to reach the line starts that are on the chain.
    check search("A\xE0\xB1\xB1\n\nB", re("^$")).matchSpan == 5 .. 5
    check search("ab\ncd", re("(?m)^c")).matchSpan == 3 .. 4

  test "the scans agree on subjects long enough to hide a newline":
    # Reaching the ``^`` skip's failure needs a lead byte, a ``'\n'`` inside
    # the span it declares, and a failed attempt at an earlier position --
    # three bytes more than ``subjects()`` offers.
    const Bytes =
      ['\x0A', '\x61', '\x41', '\x31', '\x80', '\xC0', '\xC3', '\xE0', '\xF0']
    # Generated the same way, over a small body set: this loop already runs
    # over 9^4 subjects, so it takes the anchors -- where the skips live --
    # and only a handful of bodies to go with them.
    let linePatterns =
      generatedPatterns(["", "a", ".", "\\w", "\\s*", "[^A]"], ["", "\\s*", "[^A]"])
    for pattern in linePatterns:
      let rx = re(pattern)
      let plain = hintless(pattern)
      for b0 in Bytes:
        for b1 in Bytes:
          for b2 in Bytes:
            for b3 in Bytes:
              let subject = $b0 & $b1 & $b2 & $b3
              let got = search(subject, rx)
              if not rx.literalScan:
                let want = bruteForce(subject, plain)
                check got.found == want.found
                if got.found and want.found:
                  check got.matchSpan == want.matchSpan
              if not rx.literalScan:
                let wantBack = bruteForceBackward(subject, plain)
                let gotBack = searchBackward(subject, rx)
                check gotBack.found == wantBack.found
                if gotBack.found and wantBack.found:
                  check gotBack.matchSpan == wantBack.matchSpan

suite "backward stepping and zero-width iteration":
  test "prevCharStart gives Oniguruma's answer, not the forward chain's":
    # The forward ``encLen`` chain over "\xC0\xC3\xA9" runs 0 -> 2 -> 3, so the
    # character ending at 3 is the lone byte 0xA9, not a word char.  Stepping
    # back lands on 1 instead and validates it, because 1 + encLen(0xC3) == 3 —
    # this is ``left_adjust_char_head``, and the engine keeps its answer.
    const S = "\xC0\xC3\xA9"
    check search(S, re("(?<=\\w)")).found
    check matchAt(S, re("\\b"), 3).found

  test "a byte covered by nothing reads as itself, not as a sequence past pos":
    # In "\xC0\xC2\xA9" nothing ends at offset 2, so the byte before it stands
    # for itself and reads as 0xC2 = U+00C2 (a word char), not as the U+00A9
    # (not a word char) that the sequence starting at 1 would run *past* 2 to
    # spell.  The character at 2 is the lone byte 0xA9, also not a word char,
    # so \b sees exactly one word side and matches.  (Lookbehind asks a
    # stricter question — the character it consumes must *end* at 2 — and so
    # matches at neither reading.)
    const S = "\xC0\xC2\xA9"
    check matchAt(S, re("\\b"), 2).found
    check not matchAt(S, re("(?<=\\w)"), 2).found

  test "grapheme and word segmentation step back the same way":
    # The look-back scans inside \X and (?y{w}) used to walk continuation
    # bytes raw and could start decoding at an offset no forward walk visits.
    # The point here is that malformed input is handled without a crash or an
    # out-of-range span; on these subjects the two scans also happen to agree,
    # which they are not obliged to do in general.
    const Subjects = [
      "\xC0\xC3\xA9a", "\xC0\x80\xE2\x80\x8D\xC0",
      "\xF0\x9F\x87\xA6\xC0\xF0\x9F\x87\xA7",
    ]
    for s in Subjects:
      for rx in [re("\\X"), re("(?y{w})\\X"), re("\\y"), re("\\Y")]:
        # No crash, no out-of-range span, and forward and backward agree.
        let m = search(s, rx)
        if m.found:
          check m.matchSpan.a >= 0
          check m.matchSpan.b <= s.len
        check m.found == searchBackward(s, rx).found

  test "a zero-width match past the scan start is yielded once":
    var spans: seq[Span]
    for m in findAll("ab", re("\\b")):
      spans.add m.matchSpan
    check spans == @[Span(a: 0, b: 0), Span(a: 2, b: 2)]

  test "zero-width iteration matches Oniguruma's findAll/replace/split":
    check replace("ab", re("\\b"), "-") == "-ab-"
    check split("ab", re("\\b")) == @["", "ab", ""]
    check replace("abc", re("(?=b)"), "-") == "a-bc"
    check split("abc", re("(?=b)")) == @["a", "bc"]

# Regression for the worker-thread stack overflow: deep delegation must raise
# RegexLimitError before it exhausts the thread's native stack. A worker
# stack is 2 MiB against the main thread's 8 MiB, and under
# --exceptions:setjmp a delegation level costs ~10 KB, so this used to
# segfault instead of raising.
#
# The outcome crosses the thread boundary as an enum written through a pointer
# to a main-thread local: under --mm:refc each thread owns its heap and frees
# it at thread exit, so a string assigned on the worker would dangle by the
# time the main thread read it.
type
  DeepQuantOutcome = enum
    dqMatched
    dqNoMatch
    dqLimit
    dqUnexpected

  DeepQuantArg = tuple[reps: int, maxDepth: int, outcome: ptr DeepQuantOutcome]

proc deepQuantOnThread(arg: DeepQuantArg) {.thread.} =
  {.cast(gcsafe).}:
    try:
      # A subroutine call per subject character. Subexpression calls run as
      # loop turns holding no native frame, so unlike the still-delegated
      # shapes below this is paced by ``maxRecursionDepth``, not by the
      # byte-budget guard.
      let m = search(
        "a".repeat(arg.reps),
        re("(a(?1)?)"),
        stepLimit = 0,
        maxRecursionDepth = arg.maxDepth,
      )
      arg.outcome[] = if m.found: dqMatched else: dqNoMatch
    except RegexLimitError:
      arg.outcome[] = dqLimit
    except CatchableError:
      arg.outcome[] = dqUnexpected

proc outcomeAt(reps: int, maxDepth: int = DefaultMaxRecursionDepth): DeepQuantOutcome =
  var t: Thread[DeepQuantArg]
  result = dqUnexpected
  createThread(
    t, deepQuantOnThread, (reps: reps, maxDepth: maxDepth, outcome: addr result)
  )
  joinThread(t)

proc deepFullOnThread(arg: DeepQuantArg) {.thread.} =
  {.cast(gcsafe).}:
    try:
      # Fully anchored, so only a full-depth nesting can match: a depth cap
      # below the nesting answers no-match instead of raising.
      let m = search(
        "a".repeat(arg.reps),
        re("\\A(a(?1)?)\\z"),
        stepLimit = 0,
        maxRecursionDepth = arg.maxDepth,
      )
      arg.outcome[] = if m.found: dqMatched else: dqNoMatch
    except RegexLimitError:
      arg.outcome[] = dqLimit
    except CatchableError:
      arg.outcome[] = dqUnexpected

proc outcomeFullAt(
    reps: int, maxDepth: int = DefaultMaxRecursionDepth
): DeepQuantOutcome =
  var t: Thread[DeepQuantArg]
  result = dqUnexpected
  createThread(
    t, deepFullOnThread, (reps: reps, maxDepth: maxDepth, outcome: addr result)
  )
  joinThread(t)

suite "call depth guard on a worker thread":
  test "a shallow recursion still matches":
    # Under a tiny budget even 20 delegation levels exceed it, so keep the
    # "still matches" shape inside the budget on every build.
    when engine.MaxStackBytes <= 64 * 1024:
      check outcomeAt(5) == dqMatched
    else:
      check outcomeAt(20) == dqMatched

  test "deep recursion is bounded by maxRecursionDepth, not the native stack":
    # Subexpression calls hold no native frame per level, so 2000 levels fit
    # every worker stack on every build: the depth cap answers instead of the
    # byte budget. A stack overflow takes the whole test binary down, so
    # reaching the checks at all is most of the assertion; the anchored pair
    # pins the cap itself (a silent no-match past it, never a raise).
    check outcomeAt(2000, maxDepth = 2000) == dqMatched
    check outcomeFullAt(2000, maxDepth = 2000) == dqMatched
    check outcomeFullAt(2000, maxDepth = 100) == dqNoMatch

  test "a shallow delegation already exceeds a small stack budget":
    # MaxStackBytes is a compile-time budget, so this only pins the
    # first-interval probing when built small (e.g.
    # -d:reniMaxStackBytes=16384): a few re-entry levels already exceed
    # such a budget, and the guard must raise before the native stack is
    # gone. Sampling every sixteenth level from the start would let the
    # overrun precede the first reading instead. Under the default budget
    # this shape matches, which the other guard tests already cover. No
    # construct holds a native frame per repetition anymore, so the probe
    # uses pattern-nested lookaheads: 60 closed re-entries.
    when engine.MaxStackBytes <= 64 * 1024:
      var pat = "a"
      for i in 0 ..< 60:
        pat = "(?=" & pat & ")"
      expect RegexLimitError:
        discard search("a", re(pat), stepLimit = 0)

# These shapes once held a native frame per quantifier repetition -- one frame
# chain per subject character -- and only the byte budget in ``runMachine``
# stood between them and a stack overflow. Every construct runs in the loop
# now, so they match at any repetition count on a 2 MiB worker thread; what
# the suite pins is that none of them regresses into holding native stack
# again.
type DelegatedArg = tuple[pattern: string, reps: int, outcome: ptr DeepQuantOutcome]

proc delegatedOnThread(arg: DelegatedArg) {.thread.} =
  {.cast(gcsafe).}:
    try:
      let m = search("a".repeat(arg.reps) & "b", re(arg.pattern), stepLimit = 0)
      arg.outcome[] = if m.found: dqMatched else: dqNoMatch
    except RegexLimitError:
      arg.outcome[] = dqLimit
    except CatchableError:
      arg.outcome[] = dqUnexpected

proc delegatedOutcome(pattern: string, reps: int): DeepQuantOutcome =
  var t: Thread[DelegatedArg]
  result = dqUnexpected
  createThread(
    t, delegatedOnThread, (pattern: pattern, reps: reps, outcome: addr result)
  )
  joinThread(t)

suite "a delegated construct in a quantifier body stays inside the budget":
  test "a range marker in a quantifier body matches a long subject":
    # ``(?~|x)`` in a sequence used to be walked by ``matchSeqCont`` through
    # a delegate site of its own (~6 native frames a level), so 10_000
    # repetitions exceeded the budget by design. The loop answers consecutive
    # markers inline now, holding no native frame per repetition.
    check delegatedOutcome("(?:(?~|x)a)*b", 10_000) == dqMatched

  test "an alternation lookbehind repeats without overflowing the stack":
    # The last delegated shape: its fixed alternatives used to be retried
    # from a native loop counter, so 10_000 levels could not fit any budget.
    # The remainder lives in a heap entry now, holding no native frame per
    # repetition.
    check delegatedOutcome("(?:(?<=a|xy)?a)*b", 10_000) == dqMatched

  test "delegated shapes match well inside the budget":
    # Small repetition counts match on every build: no remaining shape holds
    # a native frame per repetition, so no guard is left to fire early here.
    check delegatedOutcome("(?:(?~|x)a)*b", 10) == dqMatched
    check delegatedOutcome("(?:(?<=a|xy)?a)*b", 10) == dqMatched
    check delegatedOutcome("(?:(?~|x)a)*b", 100) == dqMatched
    check delegatedOutcome("(?:(?<=a|xy)?a)*b", 100) == dqMatched

  test "a group around a lookbehind repeats without overflowing the stack":
    # ``runCont`` used to walk continuation-chain links by native recursion,
    # so one capture group around the lookbehind cost ~8 native frames per
    # repetition against the six the depth guard budgets per level. Nothing
    # in the loop walks the chain natively anymore, so this matches on every
    # build; the depth guard below now only paces direct ``runCont`` callers.
    check delegatedOutcome("(?:((?<=a|xy))a)*b", 400) == dqMatched

suite "lookbehind repeats in the loop rather than on the native stack":
  test "a negative lookbehind in a quantifier body matches a long subject":
    # Every repetition used to hold a ``matchLookaround`` frame open, so this
    # answered ``RegexLimitError`` at best and segfaulted at worst. Neither a
    # match nor a rejection needs a frame: the predicate keeps nothing.
    let m = search("a".repeat(20_000) & "b", re("(?:(?<!xy)a)*b"), stepLimit = 0)
    check m.found
    check m.boundaries[0] == 0 .. 20_001

  test "a variable-length positive lookbehind in a quantifier body does too":
    let m = search("a".repeat(20_000) & "b", re("(?:(?<=a?)a)*b"), stepLimit = 0)
    check m.found
    check m.boundaries[0] == 0 .. 20_001

  test "and on a 2 MiB worker stack":
    check delegatedOutcome("(?:(?<!xy)a)*b", 20_000) == dqMatched
    check delegatedOutcome("(?:(?<=a?)a)*b", 20_000) == dqMatched

  test "the loop answers the same lookbehinds as the recursive matcher did":
    check search("xab", re("(?<=x)ab")).found
    check not search("yab", re("(?<=x)ab")).found
    check search("ab", re("(?<!x)ab")).found
    check not search("xab", re("(?<!x)ab"), start = 1).found
    check search("aab", re("(?<=a+)b")).found
    check not search("b", re("(?<=a+)b")).found
    # Captures a positive lookbehind body writes survive it, as a lookahead's do.
    let m = search("xab", re("(?<=(x))ab"))
    check m.found
    check m.boundaries[1] == 0 .. 1
    # A negative lookbehind keeps nothing, not even a matching body's captures.
    let n = search("ab", re("(?<!(y))ab"))
    check n.found
    check n.boundaries[1].a < 0

suite "a greedy repeat of a single-way leaf is a scan, not a choice per rep":
  test "the backtrack stack does not grow with the subject":
    # The general greedy path pushes a choice, a continuation frame and a
    # capture snapshot per repetition; a single-way leaf body needs none of
    # them, only the position each repetition ended at.
    let ctx = newMatchContext()
    var m: Match
    check searchIntoCtx(ctx, "a".repeat(50_000) & "b", re("a*b"), m, stepLimit = 0)
    check ctx.scratchCaps.choices <= 16
    check ctx.scratchCaps.frames <= 16

  test "it still gives repetitions back one at a time":
    check search("aaa", re("a*a")).boundaries[0] == 0 .. 3
    check search("aaaa", re("^a{2,3}a$")).found
    check not search("aaaaa", re("^a{2,3}a$")).found
    check search("abcbc", re("[a-c]*c")).boundaries[0] == 0 .. 5
    check search("12345", re("\\d*5")).boundaries[0] == 0 .. 5
    check search("aaab", re("a*ab")).boundaries[0] == 0 .. 4
    check not search("aa", re("a{3,}")).found
    check search("aaaa", re("a{3,}")).boundaries[0] == 0 .. 4
    # Zero-width body: one repetition, then the continuation.
    check search("b", re("(?:)*b")).found

  test "a repetition over malformed bytes is given back one at a time":
    # The differential above quantifies only ``\d+`` and ``\s*``, neither of
    # which matches a stray 0x80..0xBF byte, so no generated pattern builds a
    # run *over* malformed input and then forces a give-back.  A stray
    # continuation byte decodes as a code point of its own, and each
    # repetition has to end where the decoder said it ended -- give back two
    # characters at once and the count desynchronises from the position it
    # counts, reporting the wrong span and then indexing out of range.
    check search("\x0A\x85", re("[^a]*(.)")).boundaries[1] == 1 .. 2
    check search("\x80\x80", re("\\W*(\\S)")).boundaries[1] == 1 .. 2
    check search("\x85\xE3\x81\x82x", re("[^a]*(x)")).boundaries[1] == 4 .. 5

  test "handing a repetition back undoes what ran after it":
    # The repetitions write only ``pos``, but the continuation is not so
    # bounded: ``\K`` moves the match start and nothing pushes an undo for it,
    # so the entry has to carry the scalars the way the general path's snapshot
    # does. With only ``pos`` rolled back, a ``\K`` on the branch that failed
    # kept its ``keepStart`` and moved the reported start of the branch that
    # matched.
    check search("aaa", re("a{1,3}(?i)a|\\b\\Kab")).boundaries[0] == 0 .. 3
    check search("abcaaaaaaaaaaaa", re("a{1,3}(?i)a|\\b\\Kab")).boundaries[0] == 3 .. 7
    # The flags a continuation changed have to come back too.
    check search("aab", re("a*(?i:B)")).boundaries[0] == 0 .. 3

  test "a body with two ways to match keeps the general path":
    # Under (?i) ``ß`` also matches ``ss``, so the repetition has to be
    # re-driven on backtracking and must not take the scan.
    check search("ßss", re("(?i)ß*$")).boundaries[0] == 0 .. 4
    check search("aAa", re("(?i)a*$")).boundaries[0] == 0 .. 3
    check search("ss", re("(?i)ß*ss")).boundaries[0] == 0 .. 2

  test "grapheme repetition still steps by grapheme":
    check search("áb", re("\\X*b")).found

suite "the ASCII class bitset and the atom walk agree by construction":
  # ``classHasByte`` answers a one-byte class member test from a bitset the
  # compiler precomputed, instead of walking the class's atoms.  The bitset is
  # sound only because of one claim, made by [classAsciiMatches]: below U+0080
  # every atom reads the same whatever the ASCII-restriction flags say, so the
  # set is *exact* there and a negated class may complement it.  That claim is
  # the whole safety argument, and it is the kind that decays quietly -- an
  # atom kind added to ``classAsciiMatches`` later that does read a flag below
  # U+0080 breaks it with every existing test still green.
  #
  # So the invariant is checked against the walk the bitset replaced, using a
  # property of ``classAsciiMatches`` itself: it gives up on a nested class,
  # leaving ``asciiSetOk`` false.  ``[[C]]`` therefore matches exactly what
  # ``[C]`` does while taking the atom walk, which makes the pair a
  # same-semantics differential over the two paths.  The pairing is asserted
  # below, not assumed: a change that starts annotating nested classes would
  # otherwise turn this whole suite into a tautology.

  const ClassBodies = [
    "a",
    "az",
    "a-z",
    "0-9",
    "A-Za-z0-9_",
    " ",
    " \\n",
    "\\t\\r\\f\\v",
    "-",
    "\\d",
    "\\D",
    "\\w",
    "\\W",
    "\\s",
    "\\S",
    "\\h",
    "\\H",
    "[:alpha:]",
    "[:^alpha:]",
    "[:alnum:]",
    "[:space:]",
    "[:punct:]",
    "[:ascii:]",
    "[:^ascii:]",
    "[:xdigit:]",
    "[:upper:]",
    "[:lower:]",
    "[:word:]",
    "[:cntrl:]",
    "[:graph:]",
    "[:print:]",
    "[:blank:]",
    "\\w\\s",
    "0-9[:alpha:]",
    "a-z\\d_",
    "\\D\\S",
    # Ranges that cross the ASCII boundary: the byte container fills to 0xFF,
    # not to 0x7F, and the low half still has to read the same both ways.
    "a-\xC3\xBF",
    "\x00-\xC2\x85",
    "\\x{41}-\\x{5A}",
  ]

  const FlagPrefixes = [
    "", "(?i)", "(?I)", "(?iI)", "(?W)", "(?D)", "(?S)", "(?P)", "(?W)(?D)(?S)(?P)",
    "(?i)(?W)(?D)(?S)(?P)", "(?iI)(?W)(?D)(?S)(?P)",
  ]
    ## Every flag a class atom can read.  ``(?W)``/``(?D)``/``(?S)``/``(?P)``
    ## are the ASCII restrictions the exactness claim is about; ``(?i)``/``(?I)``
    ## are the ones the fast path steps aside for.
    ##
    ## Ignore-case-ASCII is spelled ``(?iI)``, not ``(?i)(?I)``.  Oniguruma
    ## takes only the combined form -- it rejects the split one as an invalid
    ## group option -- so the combined form is the one a conformance
    ## expectation can be written against, and it stays correct if reni ever
    ## follows suit and rejects the split spelling too.
    ##
    ## This axis was held out for a while: a fold bug made the pair disagree
    ## on its own, ``[A-Z]`` missing ``y`` where ``[[A-Z]]`` matched it, so it
    ## was not a same-semantics oracle under these flags and could say nothing
    ## about the bitset.  That is fixed; the axis is back.

  proc firstCharClass(node: Node): Node =
    ## The first ``nkCharClass`` in the tree, or nil.
    if node == nil:
      return nil
    if node.kind == nkCharClass:
      return node
    for child in node.childNodes:
      let found = firstCharClass(child)
      if found != nil:
        return found
    nil

  test "the paired patterns really do take the two different paths":
    # Guards the differential below: if either half stops holding, the
    # comparison still passes while comparing nothing.
    for body in ClassBodies:
      for caret in ["", "^"]:
        let fast = firstCharClass(re("[" & caret & body & "]").ast)
        let slow = firstCharClass(re("[" & caret & "[" & body & "]]").ast)
        require fast != nil
        require slow != nil
        check fast.asciiSetOk
        check not slow.asciiSetOk

  test "every ASCII byte reads the same through the bitset and through the atoms":
    for prefix in FlagPrefixes:
      for body in ClassBodies:
        for caret in ["", "^"]:
          let fast = re(prefix & "[" & caret & body & "]")
          let slow = re(prefix & "[" & caret & "[" & body & "]]")
          for b in 0 .. 127:
            let subject = $chr(b)
            let viaBitset = search(subject, fast).found
            let viaAtoms = search(subject, slow).found
            if viaBitset != viaAtoms:
              checkpoint(
                "prefix=" & prefix & " body=" & body & " caret=" & caret & " byte=" & $b
              )
            check viaBitset == viaAtoms

  test "a class the bitset answers still reads non-ASCII through the atoms":
    # The bitset covers only b < 0x80; everything above it has to keep
    # reaching the range walk, negation included.
    check search("é", re("[^a-z]")).found
    check search("é", re("[a-\xC3\xBF]")).found
    check not search("\xC3\xBF", re("[a-z]")).found
    check search("日", re("[^\\d]")).found
    check search("日", re("[[:^ascii:]]")).found
    check not search("日", re("[[:ascii:]]")).found
suite "ASCII-only case folding is a restriction on both ends":
  # ``(?I)`` narrows ``(?i)`` to ASCII.  That is a statement about *pairs*: a
  # fold applies only when the subject and the character it folds to are both
  # ASCII.  Getting only the subject half right lets an ASCII subject reach its
  # non-ASCII variants -- ``k`` is a case fold of U+212A KELVIN SIGN and ``s``
  # of U+017F LATIN SMALL LETTER LONG S -- so ``[[:^ascii:]]`` would match
  # ``k``.  Every expectation here is Oniguruma 6.9.10's answer.
  #
  # Oniguruma rejects ``(?i)(?I)`` as an invalid group option and takes only
  # the combined ``(?iI)``, so that is the spelling these use.

  test "a range folds in both directions, not just toward the folded case":
    # ``simpleFold`` maps toward one case, so testing it against the range's
    # own endpoints answered only for a range written in that case: ``[a-z]``
    # matched ``Y`` while ``[A-Z]`` missed ``y``.
    check search("y", re("(?iI)[A-Z]")).found
    check search("Y", re("(?iI)[a-z]")).found
    check search("k", re("(?iI)[A-Z]")).found
    check search("K", re("(?iI)[a-z]")).found
    check search("y", re("(?iI)[0-9A-Z]")).found
    check search("y", re("(?iI)[\\x{41}-\\x{5A}]")).found
    # The unrestricted spelling has always held; it is here so a fix that
    # collapses the two arms cannot quietly change it.
    check search("y", re("(?i)[A-Z]")).found
    check search("Y", re("(?i)[a-z]")).found

  test "an ASCII subject does not reach its non-ASCII fold variants":
    check not search("k", re("(?iI)[\\x{212A}]")).found
    check not search("s", re("(?iI)[\\x{17F}]")).found
    check not search("k", re("(?iI)[\\x{2120}-\\x{2130}]")).found
    # Through a nested class and through a predicate atom, which fold on a
    # different path than a bare range does.
    check not search("k", re("(?iI)[[\\x{212A}]]")).found
    check not search("s", re("(?iI)[[\\x{17F}]]")).found
    check not search("k", re("(?iI)[[\\x{2120}-\\x{2130}]]")).found
    check not search("k", re("(?iI)[[:^ascii:]]")).found
    check not search("s", re("(?iI)[[:^ascii:]]")).found
    check not search("k", re("(?iI)[[^\\x{00}-\\x{7F}]]")).found
    # And the other direction: a non-ASCII subject reaches no ASCII member.
    check not search("\u212A", re("(?iI)[k]")).found
    check not search("å", re("(?iI)[Å]")).found

  test "plain (?i) still reaches them":
    check search("k", re("(?i)[\\x{212A}]")).found
    check search("s", re("(?i)[\\x{17F}]")).found
    check search("k", re("(?i)[\\x{2120}-\\x{2130}]")).found
    check search("k", re("(?i)[[\\x{212A}]]")).found
    check search("k", re("(?i)[[:^ascii:]]")).found
    check search("\u212A", re("(?i)[k]")).found
    check search("å", re("(?i)[Å]")).found

  test "the ASCII folds themselves keep working":
    check search("k", re("(?iI)[K]")).found
    check search("K", re("(?iI)[k]")).found
    check search("y", re("(?iI)[[A-Z]]")).found
    check search("k", re("(?iI)[[[:upper:]]]")).found
    check search("k", re("(?iI)[\\p{Lu}]")).found
    check search("a", re("(?iI)[\\p{Ll}]")).found
    check search("y", re("(?iI)Y")).found
    check not search("k", re("(?iI)[[:^word:]]")).found

  test "(?I) without (?i) folds nothing":
    check not search("y", re("(?I)[A-Z]")).found
    check not search("Y", re("(?I)[a-z]")).found
    check not search("k", re("(?I)[K]")).found

suite "an alternation passes over branches whose first byte cannot match":
  # Each alternative carries a first-byte hint, and the matcher skips a branch
  # whose hint excludes the byte in front of it.  The hint is a *superset* of
  # what the branch can start with, so a skip is only ever a branch that
  # provably could not have matched -- the invariant the whole thing rests on.
  # The generated differential above runs alternations with distinct hints
  # against a brute-force walk; the cases here are the ones a generator over
  # short subjects does not reach.

  proc altHints(pattern: string): int =
    ## How many hints the compiler stored for the pattern's first
    ## alternation, 0 when it stored none.
    proc find(n: Node): Node =
      if n == nil:
        return nil
      if n.kind == nkAlternation:
        return n
      for c in n.childNodes:
        let r = find(c)
        if r != nil:
          return r
      nil

    let a = find(re(pattern).ast)
    if a == nil: 0 else: a.altFirst.len

  test "a branch is only skipped when it could not have matched":
    # Every branch is reachable through the filter at the byte that starts it.
    let rx = re("(?:alpha|bravo|charlie|delta)")
    check search("xx alpha", rx).matchSpan == 3 .. 8
    check search("xx bravo", rx).matchSpan == 3 .. 8
    check search("xx charlie", rx).matchSpan == 3 .. 10
    check search("xx delta", rx).matchSpan == 3 .. 8
    # Order still decides: the first branch that matches wins, not the
    # longest or the last one the filter admitted.
    check search("abcd", re("(?:a|ab|abc)")).matchSpan == 0 .. 1
    check search("abcd", re("(?:abc|ab|a)")).matchSpan == 0 .. 3

  test "a zero-width branch survives the end of the subject":
    # At the end there is no byte to test.  A branch that must consume one
    # cannot match, but an empty branch still can -- and an empty branch
    # yields no byte hint, so the filter has to let it through.
    check search("", re("(?:abc|)")).matchSpan == 0 .. 0
    check search("z", re("z(?:abc|)")).matchSpan == 0 .. 1
    check search("z", re("z(?:abc|\\b)")).matchSpan == 0 .. 1
    check not search("z", re("z(?:abc|def)")).found

  test "a branch the analysis cannot read is always tried":
    # ``fcNone`` means "no hint", never "no match": a backreference leads a
    # branch the filter must not touch, and a leading lookahead or bare
    # anchor is read through to the byte that follows it.
    check search("ab", re("(?:(?=a)ab|zz)")).matchSpan == 0 .. 2
    check search("aa", re("(a)(?:\\1|zz)")).matchSpan == 0 .. 2
    check search("ab", re("(?:^ab|zz)")).matchSpan == 0 .. 2

  test "an (?i) switched on at match time skips nothing it should not":
    # Hints are computed as if ``(?i)`` were on, so they stay a superset when
    # the pattern turns it on partway through -- which no walk of the tree at
    # compile time sees at the alternation's own position.
    check search("abc", re("(?:(?i)ABC|zz)")).matchSpan == 0 .. 3
    check search("ABC", re("(?:(?i)abc|zz)")).matchSpan == 0 .. 3
    check search("ss", re("(?:(?i)\xC3\x9F|zz)")).matchSpan == 0 .. 2
    check search("\xC3\x9F", re("(?:(?i)ss|zz)")).matchSpan == 0 .. 2

  test "a malformed byte reaches the branch that admits it":
    # A stray continuation byte is a character of its own, and the hint for a
    # negated or non-ASCII branch has to keep every byte above 0x7F in.
    check search("\x80", re("(?:[^a]|zz)")).matchSpan == 0 .. 1
    check search("\x80", re("(?:\\W|zz)")).matchSpan == 0 .. 1
    check search("\xC3\xA9", re("(?:\xC3\xA9|zz)")).matchSpan == 0 .. 2
    check search("\xF5\x80\x80\x80", re("(?:.|zz)")).matchSpan == 0 .. 1

  test "hints are stored only when they can tell branches apart":
    # Branches that all carry the same hint can never be told apart: whatever
    # byte is in front, either all of them survive the test or none does.
    # Storing hints there would buy a lookup per branch per visit and nothing
    # else, so the compiler leaves them off -- and the matcher then runs the
    # path it ran before any of this existed.
    check altHints("(?:foo|fob|foc)") == 0
    check altHints("(?:a|a)") == 0
    check altHints("(?:\\w|\\w)") == 0
    check altHints("(?:foo|bar|baz)") == 3
    check altHints("(?:a|\\d)") == 2
    # A branch with no hint differs from one with a hint, so the pair is
    # still worth filtering: the hinted branch can be skipped, and the
    # unhinted one is still tried where only it can match.
    check altHints("(?:a|(?=x))") == 2
    check search("x", re("(?:a|(?=x))")).matchSpan == 0 .. 0
    # A leading lookahead is read through, so both branches here carry a hint
    # taken from the byte after it.
    check altHints("(?:a|(?=x)y)") == 2

  test "an alternation every branch of which is skipped fails at once":
    check not search("zzzz", re("(?:aaa|bbb|ccc)")).found
    check not search("zzzz", re("z(?:aaa|bbb|ccc)")).found
    # ...and does not disturb what follows it on the way back out.
    check search("zzzz", re("z(?:aaa|bbb|ccc)|zz")).matchSpan == 0 .. 2

  test "a branch passed over under a narrow end is retried once it widens":
    # ``(?~|b)`` narrows the subject end to the byte before ``b``, and
    # ``(?~|)`` clears the limit for good.  At the narrow end there is no byte
    # in front of the matcher, so the ``b`` branch cannot be admitted; when
    # the continuation clears the end and then fails, the branch has to be
    # there to backtrack into.  A hint decision cached from entry time -- the
    # end it was made under is not the end backtracking sees -- loses it.
    check search("b", re("\\A(?~|b)(?:|b)(?~|)\\z")).matchSpan == 0 .. 1
    check search("b", re("(?~|b)(?:|b)(?~|)\\z")).matchSpan == 0 .. 1
    # The passed-over branch need not be the one right after the first.
    check search("b", re("(?~|b)(?:|b|b)(?~|)\\z")).matchSpan == 0 .. 1
    # ``(?~)`` clears the limit the same way.
    check search("b", re("(?~|b)(?:|b)(?~)\\z")).matchSpan == 0 .. 1
