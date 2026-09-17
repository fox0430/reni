import std/[unittest, strutils, options, unicode]

import ../reni
import ../reni/engine
import ../reni/types
import ../reni/unicode_utils

# How a match is reached, rather than what it answers.  Split from
# ``test_engine.nim`` for the global limit its header names.

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

  test "a fold reached part way into an ASCII run":
    # An ASCII run compares as bytes, so the wider character has to pull it
    # back onto the character walk wherever it falls.  Checked against
    # Oniguruma 6.9.10.
    check search("ma\xC3\x9F", re("(?i)mass")).matchSpan == 0 .. 4
    check search("ma\xC3\x9Fx", re("(?i)mass")).matchSpan == 0 .. 4
    check search("a\xC3\x9Fx", re("(?i)assx")).matchSpan == 0 .. 4
    check search("as\xE2\x84\xAA", re("(?i)ask")).matchSpan == 0 .. 5
    check search("a\xC5\xBFs", re("(?i)ass")).matchSpan == 0 .. 4
    check search("x\xEF\xAC\x83", re("(?i)xffi")).matchSpan == 0 .. 4
    check not search("ma\xC3\x9F", re("(?i)mast")).found

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
    # Inverted ``{n,m}`` swaps its bounds, so the body is optional and no
    # leaf in front of it may be read as leading or as a literal prefix.
    "\xC3\xA9{2,0}",
    "[^a]{2,0}",
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

  test "the step limit bounds the scan and not only the verdict":
    # The run is charged in one go, so the limit has to clamp the scan too:
    # charging afterwards raises on the same input, but only after reading the
    # whole subject.
    let ctx = newMatchContext()
    var m: Match
    expect RegexLimitError:
      discard searchIntoCtx(ctx, "a".repeat(200_000), re("\\w+"), m, stepLimit = 10)
    # One byte past the budget is what it takes to charge over the limit.
    check ctx.stepsUsed == 11
    # Classes, character types and a counted cap wider than the budget all
    # take the scan, and none carries a literal the prefilter could refuse the
    # subject on before a step is charged.
    for pattern in ["[a-z]+", "\\w{1,100000}", "\\S*"]:
      expect RegexLimitError:
        discard searchIntoCtx(ctx, "a".repeat(200_000), re(pattern), m, stepLimit = 10)
      check ctx.stepsUsed == 11

  test "a run the budget covers is charged one step per repetition":
    # A span the budget pays for has to come back whole, and cost what the
    # per-repetition loop charged for it. A literal body never reaches the
    # scan, so every pattern here carries a class or a character type.
    let ctx = newMatchContext()
    var m: Match
    check searchIntoCtx(ctx, "aaaa" & "b", re("\\w+b"), m, stepLimit = 100)
    check m.boundaries[0] == 0 .. 5
    # Exactly on the budget: the last repetition is the last step it can pay.
    check searchIntoCtx(ctx, "aaaa", re("^[a-z]+$"), m, stepLimit = 0)
    let exact = ctx.stepsUsed
    check searchIntoCtx(ctx, "aaaa", re("^[a-z]+$"), m, stepLimit = exact)
    check m.boundaries[0] == 0 .. 4
    check ctx.stepsUsed == exact
    # One step short and it raises.
    expect RegexLimitError:
      discard searchIntoCtx(ctx, "aaaa", re("^[a-z]+$"), m, stepLimit = exact - 1)
    # The literal body goes the per-repetition way: its count is the one the
    # scan has to reproduce.
    check searchIntoCtx(ctx, "aaaa", re("^a+$"), m, stepLimit = 0)
    check ctx.stepsUsed == exact
    # Unlimited stays unlimited -- the budget must not overflow into a clamp.
    check searchIntoCtx(ctx, "a".repeat(50_000) & "b", re("\\S+b"), m, stepLimit = 0)
    check m.boundaries[0] == 0 .. 50_001

  test "it still gives repetitions back one at a time":
    check search("aaa", re("a*a")).boundaries[0] == 0 .. 3
    check search("aaaa", re("^a{2,3}a$")).found
    check not search("aaaaa", re("^a{2,3}a$")).found
    check search("abcbc", re("[a-c]*c")).boundaries[0] == 0 .. 5
    check search("12345", re("\\d*5")).boundaries[0] == 0 .. 5
    check search("aaab", re("a*ab")).boundaries[0] == 0 .. 4
    check not search("aa", re("a{3,}")).found
    # A counted cap bounds the scan, not only the loop behind it.
    check search("aaaaa", re("\\w{3}")).boundaries[0] == 0 .. 3
    check not search("aaaaa", re("^[a-z]{2,3}$")).found
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

suite "a lazy repeat of a single-way leaf is a scan, not a choice per rep":
  # The mirror image of the greedy scan above.  Greedy takes every repetition
  # it can and hands them back; lazy takes as few as it can and adds them, so
  # the general path pushes a choice and re-enters the dispatch once per
  # character the body steps over.  Where the compiler can name the leaf the
  # continuation must match, the matcher walks the body forward to the next
  # position that leaf admits instead, and pushes one choice for the run.

  proc lazyScanned(pattern: string, flags: RegexFlags = {}): bool =
    ## Whether any lazy repeat in ``pattern`` carries the annotation the scan
    ## is gated on.  What the gates refuse is not visible in an answer -- both
    ## paths answer the same thing -- so read the annotation itself.
    proc walk(n: Node): bool =
      if n == nil:
        return false
      if n.kind == nkQuantifier and n.quantKind == qkLazy and n.quantNextLeaf != nil:
        return true
      for c in n.childNodes:
        if walk(c):
          return true
      false

    walk(re(pattern, flags).ast)

  test "the backtrack stack does not grow with the subject":
    let ctx = newMatchContext()
    var m: Match
    check searchIntoCtx(ctx, "a".repeat(50_000) & "b", re("a*?b"), m, stepLimit = 0)
    check m.boundaries[0] == 0 .. 50_001
    check ctx.scratchCaps.choices <= 16
    check ctx.scratchCaps.frames <= 16

  test "it still takes as few repetitions as it can":
    check search("aaa", re("a*?a")).boundaries[0] == 0 .. 1
    check search("aaaaab", re("a{2,4}?b")).boundaries[0] == 1 .. 6
    check search("aaab", re("a{0,2}?b")).boundaries[0] == 1 .. 4
    check search("aaaab", re("a{3,}?b")).boundaries[0] == 0 .. 5
    check search("12345", re("\\d*?5")).boundaries[0] == 0 .. 5
    check search("abcbc", re("[a-c]*?c")).boundaries[0] == 0 .. 3
    check search("b", re("a*?b")).boundaries[0] == 0 .. 1
    check not search("aaa", re("a*?b")).found

  test "the scan resumes past a position the continuation refused":
    # ``b`` admits position 1, where ``bc`` does not match; the retry has to
    # carry on from there rather than give up or start over.
    check search("xbxbc", re("\\w*?bc")).boundaries[0] == 0 .. 5
    check search("say \"hi\" there", re("\"[^\"]*?\"")).boundaries[0] == 4 .. 8

  test "a scan that cannot reach a minimum or a later position fails":
    # ``qmin`` is not reached: the scan must not start from an under-filled
    # count and hand the continuation repetitions the body never matched.
    check not search("aab", re("a{3,}?b")).found
    # The first leaf the scan admits is refused by the rest of the
    # continuation, and no later repetition reaches another admissible
    # position, so the choice has to be popped and the match fail.
    check not search("abcby", re("\\w*?[b]cx")).found
    # ``maxRep`` is reached before the leaf admits anything.
    check not search("aab", re("a{2}?c")).found

  test "a repetition over malformed bytes still ends where the decoder said":
    check search("\x80\x80x", re("[^a]*?(.)x")).boundaries[1] == 1 .. 2
    # The first case's continuation leaf is ``.``, which the annotation
    # refuses, so only the general path runs.  A leaf the scan does read has
    # to stop where the decoder said too: a stray continuation byte decodes
    # as a code point of its own, and the scan counts those same steps.
    check search("\x80\x80x", re("[^a]*?(x)")).boundaries[1] == 2 .. 3

  test "resuming the scan undoes what ran after it":
    # The repetitions write only ``pos``; the continuation is not so bounded,
    # so the entry carries the scalars the way the general path's snapshot
    # does.  Here ``\K`` moves the match start at a position the continuation
    # then refuses, and the start it reports must not survive into the one
    # that matches.
    check search("xbxbc", re("\\w*?\\Kbc")).boundaries[0] == 3 .. 5
    check search("abcaaaaaaaaaaaa", re("a{1,3}?(?i)a|\\b\\Kab")).boundaries[0] == 3 .. 5

  test "a body or a leaf with two ways to match keeps the general path":
    # Under (?i) ``a`` also matches ``A`` and ``ß`` matches ``ss``, so one
    # variant no longer decides the body or the leaf test.  A leading ``(?i)``
    # is an isolated flag group, and a scoped ``(?i:...)`` restores the flags
    # on its way out, so neither reaches the flags the annotation is chosen
    # under: it is the matcher's own check on the flags in force that refuses
    # these, and the annotation is there.
    check lazyScanned("(?i)a*?B")
    check search("aab", re("(?i)a*?B")).boundaries[0] == 0 .. 3
    check search("aAab", re("(?i)a*?b")).boundaries[0] == 0 .. 4
    check search("\xC3\x9Fss", re("(?i)\xC3\x9F*?ss")).boundaries[0] == 0 .. 2
    check search("aab", re("(?i:a*?B)")).boundaries[0] == 0 .. 3

  test "the runtime gates keep what the annotation cannot see":
    # The scan steps the body with one way per repetition, so a body with two
    # ways has to stay on the general path even where the continuation leaf is
    # known: committing to the first branch steps over the match.
    check lazyScanned("(?:abcd|a)*?bc")
    check search("abcdbx", re("(?:abcd|a)*?bc")).boundaries[0] == 0 .. 3
    # Under (?i) a class is not one test, and the scan's leaf test reads the
    # fold variant rather than the plain byte.  The annotation is there, so
    # only the gates keep this case off the scan.
    check lazyScanned("(?i)a*?[b]")
    check search("aab", re("(?i)a*?[b]")).boundaries[0] == 0 .. 3

  test "the leaf has to be one the continuation cannot get past":
    check lazyScanned("a*?b")
    check lazyScanned("(a*?)b") # a capture finishes into its own continuation
    check lazyScanned("(?:a*?|x)b") # and so does an alternation branch
    check lazyScanned("(?>a*?bc)") # ``bc`` is inside the atomic group, not past it
    check search("aabc", re("(?>a*?bc)")).boundaries[0] == 0 .. 4
    # A run of literals is one leaf too, just a wider test.
    check lazyScanned("<!--.*?--\x3ex")
    check search("<!--a--\x3eb<!--c--\x3ex", re("<!--.*?--\x3ex")).boundaries[0] ==
      0 .. 18
    check not lazyScanned("a*?") # nothing follows
    check not lazyScanned("a*?$") # nothing that consumes does
    check not lazyScanned("a*?(?=b)") # nor here: the assertion is zero-width
    check not lazyScanned("a*?.") # ``.`` is no character test
    check not lazyScanned("a*?(?:b|c)") # an alternation is not one leaf either
    check not lazyScanned("a*?b*") # nor is a repeat that need not match

  test "a construct that cuts the backtracking keeps the general path":
    # Inside ``(?>...)`` a repeat that stopped later than it does today could
    # not be asked to stop earlier again, so the scan must not reach past the
    # group's end.
    check not lazyScanned("(?>a*?)b")
    check search("aab", re("(?>a*?)b")).boundaries[0] == 2 .. 3
    check not lazyScanned("(?=a*?)b")
    # A flag group's end restores the flags the leaf would then be read under.
    check not lazyScanned("(?s:a*?)b")
    # ``\\g<...>`` makes a group body's continuation the call site's, so what
    # follows the group lexically proves nothing about what follows the body.
    check not lazyScanned("(a*?)b\\g<1>")
    check lazyScanned("(a*?b)c") # ... but the sibling inside it is still safe
    check search("aabaa", re("(a*?)b\\g<1>")).boundaries[0] == 0 .. 3

suite "the ASCII class bitset and the atom walk agree by construction":
  # ``classAdvance`` answers a one-byte class member test from a bitset the
  # compiler precomputed, instead of walking the class's atoms.  The bitset is
  # sound only because of one claim, made by [exactAsciiClassSet]: below
  # U+0080 every atom reads the same whatever the ASCII-restriction flags say,
  # so the set is *exact* there and a negated class may complement it.  That
  # claim is the whole safety argument, and it is the kind that decays quietly
  # -- an atom kind that does read a flag below U+0080 breaks it with every
  # existing test still green.
  #
  # So the invariant is checked against the walk the bitset replaced, run
  # directly: [matchCcAtom] over the class's own atoms is what the matcher
  # would have called, and the suite asserts byte for byte that the compiled
  # pattern agrees with it.  The oracle needs the flags in hand, so each
  # prefix carries its own; under ``(?i)`` the bitset is not consulted at all
  # (the matcher gates it on the flag's absence) and folding puts the answer
  # out of [matchCcAtom]'s reach, so those prefixes are cross-checked against
  # the nested spelling ``[[C]]`` instead, which parses to a different tree
  # and matches the same thing.

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
    # The atom kinds the bitset only started admitting once the exactness
    # probe could clear them: a property, whose ASCII half has to be shown
    # flag-invariant one byte at a time, and the two composites, which are
    # exact only if every part they are built from is.
    "\\p{Word}",
    "\\p{Space}",
    "\\p{Alpha}",
    "\\P{Alpha}",
    "[a-z]",
    "[^a-z]",
    "a-z&&[:alpha:]",
    "\\p{Word}&&[^0-9]",
  ]

  const FlagPrefixes = [
    ("", {}),
    ("(?i)", {rfIgnoreCase}),
    ("(?I)", {rfIgnoreCaseAscii}),
    ("(?iI)", {rfIgnoreCase, rfIgnoreCaseAscii}),
    ("(?W)", {rfAsciiWord}),
    ("(?D)", {rfAsciiDigit}),
    ("(?S)", {rfAsciiSpace}),
    ("(?P)", {rfAsciiPosix}),
    ("(?W)(?D)(?S)(?P)", {rfAsciiWord, rfAsciiDigit, rfAsciiSpace, rfAsciiPosix}),
    (
      "(?i)(?W)(?D)(?S)(?P)",
      {rfIgnoreCase, rfAsciiWord, rfAsciiDigit, rfAsciiSpace, rfAsciiPosix},
    ),
    (
      "(?iI)(?W)(?D)(?S)(?P)",
      {
        rfIgnoreCase, rfIgnoreCaseAscii, rfAsciiWord, rfAsciiDigit, rfAsciiSpace,
        rfAsciiPosix,
      },
    ),
  ]
    ## Every flag a class atom can read.  ``(?W)``/``(?D)``/``(?S)``/``(?P)``
    ## are the ASCII restrictions the exactness claim is about; ``(?i)`` is the
    ## one the fast path steps aside for.  ``(?I)`` alone is not: it narrows a
    ## fold that ``(?i)`` has to turn on first, so it folds nothing by itself
    ## and leaves the bitset answering -- which is why its row carries
    ## ``rfIgnoreCaseAscii`` alone and is cross-checked against the atom walk
    ## like the unfolded rows, not against the nested spelling.
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

  proc unannotate(node: Node) =
    ## Clear ``asciiSetOk`` everywhere in the tree, so [classBitmapAnswers]
    ## turns every class down and the matcher has to reach ``classHasByte``.
    if node == nil:
      return
    if node.kind == nkCharClass:
      node.asciiSetOk = false
    for child in node.childNodes:
      unannotate(child)

  proc withoutBitset(pattern: string): Regex =
    ## The same pattern compiled and then stripped of its annotation.  The
    ## oracle for the unfolded rows has to stay the *engine's* atom walk: a
    ## reimplementation over ``cls.atoms`` would agree with a ``classHasByte``
    ## that had drifted, and since [exactAsciiClassSet] annotates both ``[C]``
    ## and ``[[C]]`` there is no spelling left that reaches the slow path on
    ## its own.  ``re()`` builds a fresh tree per call, so nothing else sees
    ## this one.
    result = re(pattern)
    unannotate(result.ast)

  test "the bitset really is what answers these classes":
    # Guards the differential below: if the compiler stops annotating them,
    # the comparison still passes while comparing nothing.
    for body in ClassBodies:
      for caret in ["", "^"]:
        for spelling in ["[" & caret & body & "]", "[" & caret & "[" & body & "]]"]:
          let cls = firstCharClass(re(spelling).ast)
          require cls != nil
          checkpoint("spelling=" & spelling)
          check cls.asciiSetOk

  test "only a property atom can read an ASCII restriction below U+0080":
    # What lets [exactAsciiClassSet] skip the probe for every other atom kind.
    # ``matchPosixClass`` answers ASCII from its table above its ``asciiOnly``
    # argument, and so do ``isWordChar`` / ``isDigitChar`` / ``isSpaceChar``;
    # a literal and a range never see a restriction flag at all.  Move any of
    # those ASCII short-circuits and the skip becomes unsound with the rest of
    # the suite still green, so the reading is asserted here directly.
    const Restrict = {rfAsciiWord, rfAsciiDigit, rfAsciiSpace, rfAsciiPosix}
    const NonPropBodies = [
      "a", "a-z", "\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "\\h", "\\H", "\\R",
      "[:word:]", "[:^word:]", "[:digit:]", "[:space:]", "[:alpha:]", "[:alnum:]",
      "[:ascii:]", "[:^ascii:]", "[:punct:]", "[:graph:]", "[:print:]", "[:cntrl:]",
      "[:blank:]", "[:lower:]", "[:upper:]", "[:xdigit:]",
    ]
    for body in NonPropBodies:
      let cls = firstCharClass(re("[" & body & "]").ast)
      require cls != nil
      for atom in cls.atoms:
        require atom.kind notin {ccUnicodeProp, ccNegUnicodeProp}
        for b in 0 .. 127:
          let r = Rune(int32(b))
          if matchCcAtom(r, atom, {}) != matchCcAtom(r, atom, Restrict):
            checkpoint("body=" & body & " byte=" & $b)
            fail()

  test "which rows the bitset actually answers is what the differential assumes":
    # The annotation above is only half the guard: [classBitmapAnswers] is the
    # gate both readers consult, and the differential's oracle depends on which
    # way it goes.  Without ``(?i)`` the bitset must answer, or the comparison
    # compares the atom walk with itself; under ``(?i)`` it must *not*, because
    # there the oracle is the nested spelling, which is only a second path as
    # long as neither spelling reaches the bitset.  Widen the gate to folded
    # input and both halves of those rows would run the same new code with the
    # suite still green -- so the assumption is pinned here instead.
    for (prefix, flags) in FlagPrefixes:
      for body in ClassBodies:
        for caret in ["", "^"]:
          let cls = firstCharClass(re(prefix & "[" & caret & body & "]").ast)
          require cls != nil
          for b in 0'u8 .. 127'u8:
            if classBitmapAnswers(cls, b, flags) != (rfIgnoreCase notin flags):
              checkpoint(
                "prefix=" & prefix & " body=" & body & " caret=" & caret & " byte=" & $b
              )
              fail()

  test "every ASCII byte reads the same through the bitset and through the atoms":
    for (prefix, flags) in FlagPrefixes:
      for body in ClassBodies:
        for caret in ["", "^"]:
          let spelling = prefix & "[" & caret & body & "]"
          let fast = re(spelling)
          require firstCharClass(fast.ast) != nil
          # Both oracles run the whole engine, so a divergence anywhere on the
          # slow path -- not only in the bitset -- shows up here.
          let slow =
            if rfIgnoreCase in flags:
              # Under a fold neither spelling reaches the bitset anyway, and
              # the nested one answers the same question through a different
              # tree, so it stays the second path here.
              re(prefix & "[" & caret & "[" & body & "]]")
            else:
              withoutBitset(spelling)
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

suite "a positive lookaround's captures are rolled back like any other":
  # A positive lookaround keeps what its (zero-width) body captured.  Those
  # captures are written inside a nested machine, which releases its own
  # ``chUndoCapture`` entries on the way out, so unless the lookaround leaves
  # a rollback of its own nothing ever takes them back: a repetition that
  # backtracks past the lookaround reports a group the winning path never set,
  # and a later ``(?(1)...)`` or backreference reads it.  Every case below is
  # checked against PCRE2 and Python, which both leave the group unset.
  test "a repetition backtracking past a lookahead unsets what it captured":
    # ``(?:aa)*`` reaches pos 4, the lookahead takes its ``(x)`` branch there,
    # then ``aax`` fails; the repetition drops to one rep and the continuation
    # succeeds through the capture-free ``a`` branch.
    let m = search("aaaax", re("(?:aa)*(?=(x)|a)aax"))
    check m.matchSpan == 0 .. 5
    check m.boundaries[1].a == -1
    # Same shape with a body the compiler treats as a single-way leaf, which
    # backtracks through ``chSimpleRepeat`` instead.
    let s = search("aaaax", re("a*(?=(x)|a)aax"))
    check s.matchSpan == 0 .. 5
    check s.boundaries[1].a == -1
    # ...and lazily, which re-enters from the other side.
    let l = search("aaxxaay", re("^(?:..)*?(?=(x)|a)aay"))
    check l.matchSpan == 0 .. 7
    check l.boundaries[1].a == -1

  test "a leaked lookahead capture would flip a conditional":
    # Not cosmetic: with group 1 left set, ``(?(1)...)`` takes the ``b``
    # branch on the retry and the whole match is lost.  A backreference reads
    # it the same way.
    check search("aaaax", re("^(?:aa)*(?(1)b|(?=(x)|a))aax")).matchSpan == 0 .. 5
    check search("aaaax", re("^a*(?(1)b|(?=(x)|a))aax")).matchSpan == 0 .. 5

  test "the same holds for every lookbehind shape that keeps captures":
    # Fixed-length, non-leaf body.
    let f = search("aaxxaay", re("^(?:..)*(?(1)q|(?<=(xx)))aay"))
    check f.matchSpan == 0 .. 7
    check f.boundaries[1] == 2 .. 4
    # Alternation, fixed alternative: retried through ``chLookbehindAlt``.
    let a = search("aaxxaay", re("^(?:..)*(?(1)q|(?<=(x)|a))aay"))
    check a.matchSpan == 0 .. 7
    check a.boundaries[1] == 3 .. 4
    # Alternation, variable alternative: commits, so the entry it committed
    # from has to become the rollback.
    let v = search("aaaxaay", re("^(?:..)*(?(1)q|(?<=(a+x)|a))aay"))
    check v.matchSpan == 0 .. 7
    check v.boundaries[1] == 2 .. 4
    # A lookbehind that never matches leaves nothing behind either.
    check not search("aaxxaay", re("^(?:..)*(?(1)q|(?<=(a)))aay")).found

  test "a retried lookbehind alternative drops the previous one's captures":
    # The first alternative matches and its ``(a)`` is kept, the continuation
    # fails on the branch ``(?(2)...)`` chose for it, and the entry is
    # re-entered for the second alternative.  Group 1 belongs to the
    # alternative that was abandoned, so nothing downstream may still read
    # it -- left set, it flips a ``(?(1)...)`` the same way a leaked
    # lookahead capture does.
    # Only that bookkeeping is pinned: whether the assertion is retried at all
    # is left open.  Oniguruma and PCRE2 read a lookbehind as atomic, so they
    # never reach the second alternative and report no match for this pattern;
    # reni does retry it and matches.  The test therefore accepts either
    # answer, and checks the captures only when a match is reported, so making
    # the lookbehind atomic later needs no change here.
    # Neither of these needs the retry -- the first alternative's capture
    # answers the condition in the first, the first alternative simply fails
    # in the second -- so they hold under either reading and keep the entry,
    # the rewind and the conditional itself under assertion even if the
    # retry-dependent check below stops running.
    let f = search("ax", re(r"^.(?<=(a)|(\w))(?(1)x|q)"))
    check f.matchSpan == 0 .. 2
    check f.boundaries[1] == 0 .. 1
    check f.boundaries[2].a == -1
    let s = search("ax", re(r"^.(?<=(q)|(\w))(?(2)x|q)"))
    check s.matchSpan == 0 .. 2
    check s.boundaries[1].a == -1
    check s.boundaries[2] == 0 .. 1
    let r = search("ax", re(r"^.(?<=(a)|(\w))(?(2)x|q)"))
    if r.found:
      check r.matchSpan == 0 .. 2
      check r.boundaries[1].a == -1
      check r.boundaries[2] == 0 .. 1

  test "a negative lookaround condition keeps its captures undoable":
    # ``(?(?!(x))...)`` deliberately preserves what the body captured when the
    # assertion fails, which needs the same rollback as the positive forms.
    check search("xaay", re("^(?:.)*?(?(1)q|(?(?!(x))a|a))ay")).matchSpan == 0 .. 4
    check search("xaay", re("^(?:.)*?(?(1)q|(?!(x))a)ay")).matchSpan == 0 .. 4

  test "a pure lookaround body still costs no rollback":
    # Nothing to undo, so the snapshot is dropped as before; these only pin
    # that the gate did not change what they answer.
    check search("aaaax", re("(?:aa)*(?=x|a)aax")).matchSpan == 0 .. 5
    check search("aaxxaay", re("^(?:..)*(?<=x|a)aay")).matchSpan == 0 .. 7
    check not search("aaaax", re("(?:aa)*(?=z)aax")).found

  test "a retained snapshot is a whole capture vector, not one span":
    # ``capSaves`` is a flat ``Span`` region, so keeping a snapshot alive has
    # to retain ``captures.len`` entries.  Retaining one let the next push
    # overwrite the rest, and the later rollback read a shifted vector: the
    # groups below came back holding another attempt's spans.
    let a = search("aaaax", re("^(?:aa)*(?=(x)|a)(?:(q)b)*aax"))
    check a.matchSpan == 0 .. 5
    check a.boundaries[1] == UnsetSpan
    check a.boundaries[2] == UnsetSpan # ``(q)`` cannot match; "aaaax" has no q
    # Same arithmetic on the variable-alternative lookbehind commit path.
    let b = search("qzzaxz", re("^.*(?<=(a+x)|q)(?:(r)b)*zz"))
    check b.matchSpan == 0 .. 3
    check b.boundaries[1] == UnsetSpan # the ``q`` alternative is the one that ran
    check b.boundaries[2] == UnsetSpan

  test "a consuming condition's captures are undoable too":
    # The general ``(?(...)...)`` branch kept what its condition captured but
    # left it with no rollback entry, so a scalar-only rollback upstream --
    # here a pure-bodied repetition -- could not take it back.
    check search("abab", re("^(?:.)*(?(?=(a))a|b)(a)(?(1)a|b)")).matchSpan == 0 .. 4
    let a = search("aaaax", re("^(?:(?:a))*(?(?=(x)|a)|q)(a).{1,2}"))
    check a.matchSpan == 0 .. 5
    check a.boundaries[1] == UnsetSpan
    let b = search("aabbaab", re("^a{0,3}b?{1,2}(?(?=(a))a|b)(b)"))
    check b.matchSpan == 0 .. 4
    check b.boundaries[1] == UnsetSpan

  test "a pure condition body still costs no rollback":
    # The same gate ``keepLookCaptures`` has, on the condition that consumes:
    # a body that writes nothing needs no entry, only its slot back.  These
    # pin that adding the gate did not change what they answer.
    let a = search("aabbaab", re("^a{0,3}b?{1,2}(?(?=a)a|b)(b)"))
    check a.matchSpan == 0 .. 4
    check a.boundaries[1] == 3 .. 4
    # Under a pure-bodied repetition, so the rollback upstream is scalar-only
    # -- the shape that made the unguarded path necessary in the first place.
    let b = search("aaaax", re("^(?:(?:a))*(?(?=x|a)|q)(a).{1,2}"))
    check b.matchSpan == 0 .. 5
    check b.boundaries[1] == 3 .. 4
    # A consuming condition, which advances ``pos`` past itself either way.
    let c = search("aaab", re("^(?:a)*(?(a)a|q)(b)"))
    check c.matchSpan == 0 .. 4
    check c.boundaries[1] == 3 .. 4

  test "a kept body's rollback reaches every group it wrote":
    # Whether the entry carries the whole capture vector or just the groups
    # the body changed is a size decision, and a wide vector takes the second
    # path.  Both have to put back exactly what the body overwrote: these are
    # the two tests above with enough spare groups to cross that line.
    let a = search("aaaax", re("^(?:aa)*(?=(x)|a)(?:(q)b)*(?:(y))?(?:(z))?(?:(w))?aax"))
    check a.matchSpan == 0 .. 5
    for i in 1 .. 5:
      check a.boundaries[i] == UnsetSpan
    let b = search("qzzaxz", re("^.*(?<=(a+x)|q)(?:(r)b)*(?:(y))?(?:(z))?(?:(w))?zz"))
    check b.matchSpan == 0 .. 3
    for i in 1 .. 5:
      check b.boundaries[i] == UnsetSpan

suite "a zero-width repetition retries from its own choice point":
  test "the continuation's position does not carry into the next attempt":
    # ``(b{0,2})+`` matches empty, so the repetition is driven by
    # ``chZeroWidthRep``: each retry re-runs the body to make it capture
    # something new.  The retry has to start where the choice was made.  It
    # used to start wherever the continuation had failed, which let the body
    # match at a position the repetition never reached -- and then the
    # continuation ran on from there, reporting a match that began before
    # anything matched.
    let a = search("aax", re("(b{0,2})+.x"))
    check a.matchSpan == 1 .. 3
    check a.boundaries[1] == 1 .. 1
    let b = search("xaaxbax", re("(b{0,2})+[^bq]x"))
    check b.matchSpan == 2 .. 4
    check b.boundaries[1] == 2 .. 2
    # A literal continuation took a different path and was always right; it
    # is here so the two stay in step.
    check search("aax", re("(b{0,2})+ax")).matchSpan == 1 .. 3

  test "an exhausted zero-width repetition leaves no captures behind":
    # Every attempt is rolled back when the construct gives up, so a pure
    # repetition upstream -- which restores scalars only -- cannot inherit
    # them.
    check not search("aay", re("^(?:.)*(b{0,2})+x")).found
    let m = search("aax", re("^(?:.)*?(b{0,2})+x"))
    check m.matchSpan == 0 .. 3
    check m.boundaries[1] == 2 .. 2

suite "a name reference resolves to every group that declares it":
  # A name may be declared more than once, so ``\k<name>``, ``\g<name>`` and
  # ``(?(<name>)...)`` each resolve to a run of groups rather than to one.
  # Every expectation here was read off Oniguruma 6.9.10
  # (ONIG_SYNTAX_ONIGURUMA, UTF-8, onig_search), except where noted.

  test "a named backreference tries each group of that name":
    # The first alternative declares ``w``, the second declares it again; the
    # backreference has to reach whichever one actually captured.
    let pat = "(?:(?<w>[a-z]+)|(?<w>[0-9]+))\\s+\\k<w>"
    check search("abc abc", re(pat)).matchSpan == 0 .. 7
    check search("12 12", re(pat)).matchSpan == 0 .. 5
    check not search("12 ab", re(pat)).found

  test "a named backreference over one group still matches that group":
    check search("aa", re("(?<w>a)\\k<w>")).matchSpan == 0 .. 2
    check not search("ab", re("(?<w>a)\\k<w>")).found

  test "a name no group captured fails rather than matching empty":
    # ``w`` is declared, so the reference is not an error; nothing captured
    # into it, so it matches nothing.
    check not search("x", re("(?:(?<w>a))?\\k<w>")).found

  test "a named condition holds when any group of that name captured":
    let pat = "(?:(?<a>x)|(?<a>y))(?(<a>)z|q)"
    check search("xz", re(pat)).matchSpan == 0 .. 2
    check search("yz", re(pat)).matchSpan == 0 .. 2

  test "a named condition fails over when no group of that name captured":
    check search("e", re("(?<a>q)?(?(<a>)w|e)")).matchSpan == 0 .. 1
    check search("qw", re("(?<a>q)?(?(<a>)w|e)")).matchSpan == 0 .. 2

  test "a named subexpression call enters the first group of that name":
    # Oniguruma rejects a call to a name declared twice outright ("multiplex
    # definition name <p> call"); reni calls the first declaration, which is
    # what these pin -- change them with the behaviour, not around it.
    check search("aba", re("(?<p>a)(?<p>b)\\g<p>")).matchSpan == 0 .. 3
    check not search("abb", re("(?<p>a)(?<p>b)\\g<p>")).found
    # The single-declaration form is the one Oniguruma also answers.
    check search("aa", re("(?<p>a)\\g<p>")).matchSpan == 0 .. 2

  test "a numeric reference resolves by index, not through the name table":
    # A pattern with named groups may not use a numbered reference at all
    # (Oniguruma: "numbered backref/call is not allowed"), so the numeric
    # forms are checked on their own pattern.  Nothing about them should
    # reach the name table.
    check search("aa", re("(a)\\1")).matchSpan == 0 .. 2
    check search("aa", re("(a)\\g<1>")).matchSpan == 0 .. 2
    expect RegexError:
      discard re("(?<p>a)\\1")

  test "two patterns with the same name do not share a resolution":
    # Each ``Regex`` carries its own name table, so compiling a second
    # pattern cannot move the first one's answer.
    let first = re("(?<n>a)\\k<n>")
    let second = re("(?:(?<n>b)|(?<n>c))\\k<n>")
    check search("aa", first).matchSpan == 0 .. 2
    check search("cc", second).matchSpan == 0 .. 2
    check search("aa", first).matchSpan == 0 .. 2

suite "the leading-leaf prefilter refuses only what no match can start with":
  # The scan tests the pattern's leading leaf at a candidate position and
  # skips the position outright when it fails.  These pin what may be read as
  # "leading" -- the shapes where a leaf looks required but is not are the
  # ones a wrong prefilter answers "no match" on.

  proc leadLeafOf(pattern: string, flags: RegexFlags = {}): bool =
    re(pattern, flags).leadLeaf != nil

  test "a leading repeat that may run zero times requires nothing":
    # ``\s`` refuses ``a``, so a prefilter that looked through the ``*``
    # would skip the only position this matches at.
    check not leadLeafOf("\\s*abc")
    check not leadLeafOf("\\d*x")
    check not leadLeafOf("[^q]{0,3}q")
    check search("abc", re("\\s*abc")).matchSpan == 0 .. 3
    check search("x", re("\\d*x")).matchSpan == 0 .. 1
    check search("q", re("[^q]{0,3}q")).matchSpan == 0 .. 1
    # ``{2,0}`` swaps to ``{0,2}``, so the body may not appear and the leaf
    # behind it is what the first character must match.  The bodies here are
    # non-ASCII or a class, which the walker would otherwise admit as the
    # leading leaf; an ASCII body would be refused by the exact-ASCII rule
    # for the wrong reason and hide the guard.
    check not leadLeafOf("漢{2,0}字")
    check not leadLeafOf("\\d{2,0}x")
    check not leadLeafOf("[^a]{2,0}")
    check search("字", re("漢{2,0}字")).matchSpan == 0 .. 3
    check search("x", re("\\d{2,0}x")).matchSpan == 0 .. 1
    check search("b", re("[^a]{2,0}")).matchSpan == 0 .. 1
    # The literal scan must not reach past an optional body either: a byte
    # scan would visit positions the character walk (and Oniguruma) does not.
    check not re("x{2,0}y").literalScan
    # ``é{2,0}`` is ``é{0,2}``, so the ``\Z`` window must reach back two é
    # widths; a maximum read off ``quantMax`` would start the scan at the end
    # and lose the match at the front.
    check search("é", re("é{2,0}\\Z")).matchSpan == 0 .. 2
    check search("aé", re("é{2,0}\\Z")).matchSpan == 1 .. 3
    check search("éé", re("é{2,0}\\Z")).matchSpan == 0 .. 4

  test "a leading repeat that must run once still admits the leaf":
    check leadLeafOf("\\s+abc")
    check search("  abc", re("\\s+abc")).matchSpan == 0 .. 5
    check not search("abc", re("\\s+abc")).found

  test "a folded leading literal is not refused by one variant":
    # ``ß`` matches ``ss`` under ``(?i)`` through a multi-character fold, so
    # the plain compare the prefilter would make is not the whole answer.
    check search("ss", re("(?i)ß")).matchSpan == 0 .. 2
    check search("K", re("(?i)k")).matchSpan == 0 .. 1
    # The guard has to catch the flag spelled as an argument too, not only an
    # inline ``(?i)``, which the parser wraps in a flag group the walker
    # cannot see through.  ``[ß]`` also matches plain ``ß``, so one variant
    # is never the whole answer.
    check not leadLeafOf("ß", {rfIgnoreCase})
    check not leadLeafOf("[ß]", {rfIgnoreCase})
    check search("ss", re("ß", {rfIgnoreCase})).matchSpan == 0 .. 2
    check search("ß", re("[ß]", {rfIgnoreCase})).matchSpan == 0 .. 2
    check search("ss", re("[ß]", {rfIgnoreCase})).matchSpan == 0 .. 2

  test "a prefiltered scan still finds a match further along":
    # Every skipped position here is one the first-byte hint admits: the
    # kana and the kanji share a lead byte.
    check search("かな漢字です", re("\\p{Han}+")).matchSpan == 6 .. 12
    check search("   x  ", re("[^ \\n]+")).matchSpan == 3 .. 4

  test "a non-ASCII leading literal is refused by the prefilter itself":
    # A single non-ASCII rune stays an ``nkLiteral`` (a longer run parses as
    # ``nkString`` and gets no prefilter), so this is the shape that reaches
    # the literal arm.  ``え`` shares its lead byte with ``あ``: the
    # first-byte hint admits position 0 and only the leaf test skips it.
    check leadLeafOf("あ")
    check search("えあ", re("あ")).matchSpan == 3 .. 6

  test "a zero-width prefix still admits the leaf behind it":
    # ``^``, ``\b``, a lookaround and an atomic group consume nothing, so the
    # first consumed character is the one the prefilter must test.
    check search("x\n漢字", re("^\\p{Han}+")).matchSpan == 2 .. 8
    check search("  abc", re("\\b\\S+")).matchSpan == 2 .. 5
    check search(" 漢字", re("(?<!\\w)\\p{Han}+")).matchSpan == 1 .. 7
    check search("a漢字", re("(?>\\p{Han}+)")).matchSpan == 1 .. 7

  test "the prefilter turning itself off does not change the answers":
    # A leaf that accepts nearly every position saves nothing, and the scan
    # stops testing it after a trial run.  The answers either side of that
    # switch must be the same, so this crosses it: the trial is 32 positions
    # and these subjects hold many times that.
    var words: seq[string]
    for i in 0 ..< 60:
      words.add "alpha beta gamma delta"
    let subject = words.join(" ")
    var wordRuns = 0
    for m in findAll(subject, re("\\w+")):
      inc wordRuns
    check wordRuns == 240
    var nonSpaceRuns = 0
    for m in findAll(subject, re("[^ \\n]+")):
      inc nonSpaceRuns
    check nonSpaceRuns == 240

  test "an off prefilter is retried later in the subject":
    # The first matches accept the leaf at every candidate; the long kana
    # tail refuses every one.  A verdict kept for the life of the context
    # must not change the answers, and the trial must come back for the tail.
    let subject = "12 ".repeat(40) & "か".repeat(300_000)
    var runs = 0
    for m in findAll(subject, re("\\d+")):
      inc runs
    check runs == 40
    # The counters outlive a single search, so a ``findAll`` over many short
    # runs crosses ``LeadLeafCapacity`` repeatedly while every position of
    # the kana prefix is refused.  Each match still has to come back.
    let runs2 = ("か".repeat(1000) & "漢, ").repeat(300)
    var han = 0
    for m in findAll(runs2, re("\\p{Han}+")):
      inc han
      check captureText(m, 0, runs2).get("") == "漢"
    check han == 300

  test "a prefiltered scan agrees under findLongest":
    # The prefilter guards both the normal and the longest paths, so a shape
    # the first-byte hint admits but only the leaf test skips must answer the
    # same either way. The kana and the kanji share a lead byte here. The
    # flags-argument spelling keeps the leaf (the inline ``(?L)`` wraps the
    # body in a flag group the walker does not see through, so it stays off
    # there -- same answers, just no prefilter).
    check leadLeafOf("\\p{Han}+", {rfFindLongest})
    check search("かな漢字です", re("\\p{Han}+")).matchSpan == 6 .. 12
    check search("かな漢字です", re("\\p{Han}+", {rfFindLongest})).matchSpan ==
      6 .. 12
    check search("かな漢字です", re("(?L)\\p{Han}+")).matchSpan == 6 .. 12
    check leadLeafOf("あ", {rfFindLongest})
    check search("えあ", re("あ")).matchSpan == 3 .. 6
    check search("えあ", re("あ", {rfFindLongest})).matchSpan == 3 .. 6
    check search("えあ", re("(?L)あ")).matchSpan == 3 .. 6

suite "the leading-repeat prefilter refuses only what no match can start with":
  # ``(X)\1`` fixes the second character to the first rather than to a set,
  # so the scan compares bytes at a candidate start instead of entering the
  # matcher.  These pin what may be read as that shape: a capture that holds
  # more than the one leaf, or a backreference to something else, makes the
  # comparison say nothing about a match.

  proc leadRepeatOf(pattern: string, flags: RegexFlags = {}): bool =
    re(pattern, flags).leadRepeat != nil

  test "the repeat shape is recognized and subsumes the leading leaf":
    check leadRepeatOf("(\\w)\\1")
    check leadRepeatOf("(a)\\1")
    check leadRepeatOf("([abc])\\1")
    check leadRepeatOf("(\\w)\\1x")
    # The leaf test is the repeat test's own first half, so it is not run
    # twice: where the repeat applies, the leading leaf is left unset.
    check re("(\\w)\\1").leadLeaf == nil

  test "a recognized repeat answers what the matcher answers":
    check search("abccde", re("(\\w)\\1")).matchSpan == 2 .. 4
    check not search("abcde", re("(\\w)\\1")).found
    check search("xaay", re("(a)\\1")).matchSpan == 1 .. 3
    # A multibyte character repeats as its whole byte sequence, and the
    # comparison must not answer on the lead byte alone: 本 and 語 share one.
    check search("日本語語", re("(\\w)\\1")).matchSpan == 6 .. 12
    check not search("日本語", re("(\\w)\\1")).found
    # The second character running past the end is a refusal, not a read.
    check not search("a", re("(\\w)\\1")).found
    check not search("", re("(\\w)\\1")).found

  test "a capture holding more than the one leaf is not the shape":
    # The backreference then spans what the leaf test did not measure, so the
    # comparison would be made against the wrong width.
    check not leadRepeatOf("(\\w\\w)\\1")
    check not leadRepeatOf("(\\w+)\\1")
    check not leadRepeatOf("(\\w?)\\1")
    check not leadRepeatOf("(\\w|ab)\\1")
    check not leadRepeatOf("((\\w))\\1")
    check not leadRepeatOf("(.)\\1")
    check search("abab", re("(\\w\\w)\\1")).matchSpan == 0 .. 4
    check search("abcabc", re("(\\w+)\\1")).matchSpan == 0 .. 6
    check search("x", re("(\\w?)\\1")).matchSpan == 0 .. 0
    check search("abab", re("(\\w|ab)\\1")).matchSpan == 0 .. 4
    check search("qaa", re("((\\w))\\1")).matchSpan == 1 .. 3
    check search("a\nx", re("(.)\\1")).matchSpan == -1 .. -1

  test "a backreference to another group is not the shape":
    check not leadRepeatOf("(\\w)(\\d)\\1")
    check search("a1a", re("(\\w)(\\d)\\1")).matchSpan == 0 .. 3

  test "case folding disqualifies the shape":
    # ``\1`` then compares folds, not bytes, so ``aA`` matches and a byte
    # comparison would skip it.
    check not leadRepeatOf("(\\w)\\1", {rfIgnoreCase})
    check not leadRepeatOf("(?i)(\\w)\\1")
    check search("aA", re("(\\w)\\1", {rfIgnoreCase})).matchSpan == 0 .. 2
    check search("aA", re("(?i)(\\w)\\1")).matchSpan == 0 .. 2

  test "ascii case folding disqualifies the shape":
    # The guard excludes both folding flags. Combined with ``rfIgnoreCase``,
    # ASCII folds, so ``aA`` matches and a byte comparison would skip it.
    check not leadRepeatOf("(\\w)\\1", {rfIgnoreCaseAscii})
    check not leadRepeatOf("(?I)(\\w)\\1")
    check not leadRepeatOf("(\\w)\\1", {rfIgnoreCase, rfIgnoreCaseAscii})
    check not leadRepeatOf("(?iI)(\\w)\\1")
    check search("aa", re("(\\w)\\1", {rfIgnoreCaseAscii})).matchSpan == 0 .. 2
    check search("aA", re("(\\w)\\1", {rfIgnoreCase, rfIgnoreCaseAscii})).matchSpan ==
      0 .. 2
    check search("aA", re("(?iI)(\\w)\\1")).matchSpan == 0 .. 2

  test "a level backreference is not the shape":
    # ``\k<n+1>`` reads the recursion history, not the capture the pattern
    # just wrote, so the byte comparison would answer a different question.
    check not leadRepeatOf("(\\w)\\k<1+1>")
    check search("aa", re("(\\w)\\k<1+1>")).matchSpan == 0 .. 2

  test "a zero-width prefix still admits the repeat behind it":
    check leadRepeatOf("^(\\w)\\1")
    check leadRepeatOf("\\b(\\w)\\1")
    check leadRepeatOf("(?<=x)(\\w)\\1")
    check search("x\naab", re("^(\\w)\\1")).matchSpan == 2 .. 4
    check search(" aab", re("\\b(\\w)\\1")).matchSpan == 1 .. 3
    check search("yaaxaab", re("(?<=x)(\\w)\\1")).matchSpan == 4 .. 6

  test "a transparent group around the repeat still admits it":
    # Groups that add no capture are entered at the start position.
    check leadRepeatOf("(?:(\\w)\\1)")
    check leadRepeatOf("(?>(\\w)\\1)")
    check search("abccde", re("(?:(\\w)\\1)")).matchSpan == 2 .. 4
    check search("abccde", re("(?>(\\w)\\1)")).matchSpan == 2 .. 4

  test "a repeat prefilter agrees across the switch that turns it off":
    # The counters are shared with the leading leaf's, so the repeat crosses
    # the same trial and cooldown.  A subject long enough to cross it must
    # answer the same on either side.
    let subject = "aa bb cd ".repeat(200)
    var runs = 0
    for m in findAll(subject, re("(\\w)\\1")):
      inc runs
    check runs == 400
    check search(subject & "zz", re("(z)\\1")).found

  test "a repeat prefilter agrees under findLongest":
    check leadRepeatOf("(\\w)\\1", {rfFindLongest})
    check search("abccd", re("(\\w)\\1", {rfFindLongest})).matchSpan == 2 .. 4

suite "the first-byte hint is a superset of what can start a match":
  # A hint that is too narrow makes the scan step over a position the pattern
  # matches, and nothing else in the suite notices -- the match is simply never
  # found.  So it is checked exhaustively over the byte range: whenever the
  # pattern matches at a lead byte, the hint has to admit that byte.
  # ``matchAt`` is the oracle because ``matchAtImpl`` reads no hint at all.
  const HintPatterns = [
    # A range written across the ASCII boundary, mixed with the atoms that
    # send ``classFirstChar`` down the ``asciiSet`` fallback: the class then
    # accepts stray bytes up to ``rangeTo`` that no lead byte stands for.
    r"[a-\x{FF}\p{Han}]",
    r"[^a-\x{FF}\p{Han}]",
    r"[\p{Han}a-\x{FF}]+",
    r"[a-\x{10FFFF}\p{Han}]",
    r"[\x{7F}-\x{80}\p{Nd}]",
    r"[a-\x{FF}&&\p{L}]",
    r"[^a-\x{FF}&&\p{L}]",
    r"[[a-c][x-\x{FF}]]",
    r"(?i)[a-\x{FF}\p{Han}]",
    r"(?-i:[a-\x{FF}\p{Han}])",
    r"[a-\x{FF}\p{Han}]+x",
    # The same shape through an alternation, where the branches' hints union.
    r"x|[a-\x{FF}\p{Han}]",
    r"\p{Han}|[a-\x{FF}\p{Nd}]",
    # The boundary-crossing range on its own, and the fallback without it.
    r"[a-\x{FF}]",
    r"[^a-\x{FF}]",
    r"[\p{Han}a-z]",
    r"[^\p{Han}]",
    r"[\p{L}\d_]",
    # The fallback shapes no atom of which reaches U+0080, where the hint is
    # the ASCII set alone and one stray lead byte would be a missed match.
    r"[[a-c][x-z]]",
    r"[^[a-c][x-z]]",
    r"[a-z&&[^aeiou]]",
    r"[[:alpha:]&&[a-c]]",
    r"[\d&&[0-5]]",
    r"[[\h]]",
    r"[[\w]]",
    r"[[a-c]&&[b-z]]",
    r"[[\x{100}]&&[a-z]]",
    r"[[a-z]&&[\x{100}]]",
    r"\p{Han}",
    r"\P{L}",
    r"\w",
    r"\W",
    r".",
  ]
  # Enough continuation bytes for a lead byte to decode, plus the one-byte
  # reading and an ASCII tail for the patterns that need a second character.
  const Tails = ["", "\xA9", "\x80\x80", "\xA9\xB0\xB0", "x", "\xA9x"]

  proc admits(fc: FirstCharInfo, b: uint8): bool =
    ## Whether the hint lets the scan try a position holding ``b``.  ``fcNone``
    ## filters nothing and the anchor kinds gate on position, not the byte.
    case fc.kind
    of fcByte:
      fc.byte == b
    of fcByteSet:
      b in fc.bytes
    else:
      true

  proc report(bad: seq[string]): string =
    ## The whole sweep in one line, so a failure names every byte that broke.
    if bad.len <= 8:
      bad.join(", ")
    else:
      bad[0 .. 7].join(", ") & ", ... (" & $bad.len & " total)"

  test "no lead byte the pattern matches is missing from the hint":
    for pat in HintPatterns:
      let r = re(pat)
      let fc = firstCharInfo(r)
      var bad: seq[string]
      for b in 0'u8 .. 255'u8:
        for tail in Tails:
          let subject = $char(b) & tail
          if matchAt(subject, r, 0).found and not admits(fc, b):
            bad.add("0x" & toHex(b) & "+" & escape(tail))
      checkpoint("pattern=" & pat & " dropped=" & report(bad))
      check bad.len == 0

  test "the scan reaches the same first position a sweep does":
    # End to end, so a hint wrong for a reason other than the class bitmap
    # shows up too.  The sweep steps with [nextScanPos] rather than a rule of
    # its own: a position the scan never visits is not one it owes an answer
    # at, though ``matchAt`` answers there anyway (``\w`` on "\x01\xF1\xA9x"
    # matches the ``x`` the lead byte's declared length steps over).
    for pat in HintPatterns:
      let r = re(pat)
      var bad: seq[string]
      for b in 0'u8 .. 255'u8:
        let subject = "\x01" & $char(b) & "\xA9x"
        var sweep = -1
        var i = 0
        while i <= subject.len:
          if matchAt(subject, r, i).found:
            sweep = i
            break
          if i == subject.len:
            break
          i = nextScanPos(subject, i)
        let m = search(subject, r)
        let scanned = if m.found: m.matchSpan.a else: -1
        if scanned != sweep:
          bad.add("0x" & toHex(b) & " sweep=" & $sweep & " scan=" & $scanned)
      checkpoint("pattern=" & pat & " diverged=" & report(bad))
      check bad.len == 0
