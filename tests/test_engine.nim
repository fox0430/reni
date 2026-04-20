import std/[unittest, strutils, options]

import ../reni

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

  test "backref condition: no else branch fails":
    let m = search("c", re("(a)?(?(1)b)"))
    check not m.found

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
    let m = search(s, re("(a(?1)?)"))
    # Should not crash; may match partially due to MaxRecursionDepth=50
    check m.found

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

  test "quantifier exceeding MaxQuantRepetitions does not crash":
    let s = "a".repeat(20000)
    let m = search(s, re("a{20000}"), stepLimit = 0)
    check not m.found

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
    # Zero-width lookahead splits at each boundary but doesn't capture between-chars text
    check split("abc", re("(?=\\w)")) == @["", "", "", ""]

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

  test "fcByte preserved for case-insensitive digit":
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
    check split("abc", re("(?=b)")) == @["a", "", "c"]

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

suite "matchWithCont call depth guard":
  test "deeply nested alternation raises RegexLimitError":
    # Build a pattern with deep nkConcat nesting using non-mergeable nodes:
    # (?:a.){N} expands to concat chains of [literal, charType] inside groups
    # that cannot be merged into nkString, creating deep call stacks.
    var pat = ""
    for i in 0 ..< 250:
      pat.add "(?:a.)"
    let subject = "ab".repeat(250)
    let r = re(pat)
    expect(RegexLimitError):
      discard search(subject, r, stepLimit = 0)

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
