## The compile options a grep's pattern takes besides the line ones:
## ``rfWordBeginEnd`` (``\<`` and ``\>`` as word edges, as GNU grep and rg
## read them) and ``rfSmartCase`` (rg's ``--smart-case``).  The word edges
## follow Oniguruma's ``ONIG_SYN_OP_ESC_LTGT_WORD_BEGIN_END``; smart case
## follows rg 15.2.0 (notes/GREP_WORKLOAD.md §3.5, §3.7).

import std/unittest

import reni

proc spans(s: string, r: Regex): seq[HSlice[int, int]] =
  for m in s.findAll(r):
    result.add m.matchSpan.a .. m.matchSpan.b

proc wbe(pattern: string, flags: RegexFlags = {}): Regex =
  re(pattern, flags + {rfWordBeginEnd})

proc folds(pattern: string): bool =
  rfIgnoreCase in re(pattern, {rfSmartCase}).flags

suite "rfWordBeginEnd":
  test "\\< holds before a word, \\> after one":
    check spans("a foo", wbe(r"\<foo")) == @[2 .. 5]
    check spans("foo foobar foo", wbe(r"foo\>")) == @[0 .. 3, 11 .. 14]
    check spans("ab cd", wbe(r"\<")) == @[0 .. 0, 3 .. 3]
    check spans("ab cd", wbe(r"\>")) == @[2 .. 2, 5 .. 5]
    check spans("a-b", wbe(r"\<\w+\>")) == @[0 .. 1, 2 .. 3]

  test "neither holds where \\b holds between non-words":
    # ``\b`` never holds there either; nor do the edges at an empty subject.
    check spans(" - ", wbe(r"\<|\>")).len == 0
    check not search("", wbe(r"\<")).found
    check not search("", wbe(r"\>")).found

  test "a word character is \\w's":
    check spans("é foo", wbe(r"\<\w")) == @[0 .. 2, 3 .. 4]
    check spans("日本 語", wbe(r"\>")) == @[6 .. 6, 10 .. 10]
    check spans("aé b", wbe(r"(?W)\<\w+")) == @[0 .. 1, 4 .. 5]
    check spans("aé b", wbe(r"(?P)\<\w+")) == @[0 .. 1, 4 .. 5]

  test "without the option they are literals":
    check spans("a foo", re(r"\<foo")).len == 0
    check spans("a <foo", re(r"\<foo")) == @[2 .. 6]
    check spans("foo>", re(r"foo\>")) == @[0 .. 4]

  test "inside a bracket class they are literals":
    check spans("<a>", wbe(r"[\<\>]")) == @[0 .. 1, 2 .. 3]

  test "as an anchor they take no repeat":
    expect RegexError:
      discard wbe(r"\<*")
    expect RegexError:
      discard wbe(r"a\>+")

  test "inside look-around":
    check spans("foo foo", wbe(r"(?<=\<f)oo")) == @[1 .. 3, 5 .. 7]
    check spans("ab cd", wbe(r"(?!\<)\w")) == @[1 .. 2, 4 .. 5]

  test "\\< needs a character before an absent range's end":
    # Oniguruma's WORD_BEGIN checks ``s < right_range`` first; WORD_END does not.
    check spans(" b", wbe(r"(?~|b| \<)")) == newSeq[Slice[int]]()
    check spans(" b", wbe(r"(?~|b|\<)")) == newSeq[Slice[int]]()
    check spans("a b", wbe(r"(?~|b|a\>)")) == @[0 .. 1]
    check spans("b", wbe(r"(?~|c|\<)b")) == @[0 .. 1]

  test "under rfLineMode a line's edges are a subject's":
    let r = wbe(r"\<bar\>", {rfLineMode})
    check spans("foo\nbar\nxbar", r) == @[4 .. 7]

suite "rfSmartCase":
  test "a pattern of lowercase literals folds":
    check folds("foo")
    check search("FOO", re("foo", {rfSmartCase})).found
    check folds(r"\d\.x")

  test "an uppercase literal keeps the case":
    check not folds("Foo")
    check not search("FOO", re("Foo", {rfSmartCase})).found

  test "an escape for one character is a literal":
    check not folds(r"b\x41r")
    check not folds(r"\x{41}x")
    check not folds(r"Ax")
    check not folds(r"\101x")

  test "a bracket class's characters and range ends are literals":
    check not folds("[A-Z]foo")
    check not folds(r"[\x41-\x5a]x")
    check not folds("[^A]x")
    check not folds("[a&&A]x")
    check not folds("[a[B]]x")

  test "named classes and properties are not literals":
    check folds(r"\Sfoo")
    check folds(r"\p{Lu}foo")
    check folds("[[:upper:]]foo")

  test "a pattern with no literal keeps the case":
    check not folds(r"^\p{Ll}+$")
    check not folds(r"\w+")
    check not search("ABC", re(r"^\p{Ll}+$", {rfSmartCase})).found

  test "uppercase is the Unicode Uppercase property":
    check not folds("ΣA")
    check folds("σ")
    check not folds("Ⅰx") # Nl, Other_Uppercase
    check not folds("Ⓐx") # So, Other_Uppercase
    check folds("ⓐ")

  test "group names, references and comments are not literals":
    check folds(r"(?<Ab>x)\k<Ab>")
    check folds(r"(?<Name>x)(?(Name)y|z)")
    check folds(r"(?<Name>x)(?(<Name>)y|z)")
    check search("XY", re(r"(?<Name>x)(?(Name)y|z)", {rfSmartCase})).found
    # Not a group's name: the condition is a pattern of literals.
    check not folds(r"(?<n>x)(?(Name)y|z)")
    # Kept case: the tree parsed for the scan is the one compiled.
    let kept = re(r"(?<Name>x)?(?(Name)Y|z)", {rfSmartCase})
    check rfIgnoreCase notin kept.flags
    check search("xY", kept).matchSpan == 0 .. 2
    check not search("xy", kept).found
    check search("z", kept).matchSpan == 0 .. 1

  test "without rfWordBeginEnd, \\< and \\> are literals":
    check folds(r"\<\p{Lu}")
    let edges = re(r"\<\p{Lu}", {rfSmartCase, rfWordBeginEnd})
    check rfIgnoreCase notin edges.flags

  test "a byte sequence is the character it encodes":
    check folds(r"caf\xC3\xA9")
    check not folds(r"caf\xC3\x89")
    check not folds(r"\x41")

  test "the \\M of \\M-x is no literal":
    check folds(r"\M-a")
    check not folds(r"\M-A")
    check folds("(?x) # A comment\n foo")
    check not folds(r"(?<=A)x")

  test "an inline flag still wins":
    let r = re("(?-i)foo", {rfSmartCase})
    check rfIgnoreCase in r.flags
    check not search("FOO", r).found

  test "rfIgnoreCase given as well folds regardless":
    check rfIgnoreCase in re("Foo", {rfSmartCase, rfIgnoreCase}).flags

  test "a bad pattern raises":
    expect RegexError:
      discard re("(foo", {rfSmartCase})
