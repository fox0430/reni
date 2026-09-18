import std/[unittest, options, strutils, unicode]

import ../reni
import ../reni/engine
import ../reni/types
import ../reni/unicode_utils

# What the compiler's rewriting passes leave behind: the first-character
# prefilter, the leading-run skip, auto-possessification, the range and
# repeat normalisations, and the lead-anchor prefilter.  Split out of
# ``test_engine.nim`` because ``refc`` allows 3500 module-level globals and a
# ``unittest`` body is module-level.

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

suite "auto-possessification":
  # A wrong rewrite drops matches silently, so each shape is pinned twice:
  # the kind the compiler left on the quantifier, and, where a wrong rewrite
  # would lose a give-back, the matches found.
  proc kinds(pattern: string, flags: RegexFlags = {}): seq[QuantKind] =
    ## Every quantifier's kind, outermost first.
    proc walk(node: Node, into: var seq[QuantKind]) =
      if node == nil:
        return
      if node.kind == nkQuantifier:
        into.add node.quantKind
      for child in node.childNodes:
        walk(child, into)

    walk(re(pattern, flags).ast, result)

  proc all(subject, pattern: string, flags: RegexFlags = {}): seq[string] =
    for m in findAll(subject, re(pattern, flags)):
      result.add captureText(m, 0, subject).get("")

  test "a follower that rejects the body possessifies the repeat":
    check kinds("(\\w+)\\s*=\\s*(\\w+)") ==
      @[qkPossessive, qkPossessive, qkPossessive, qkGreedy]
    check all("a = b, cc=dd", "(\\w+)\\s*=\\s*(\\w+)") == @["a = b", "cc=dd"]
    check kinds("[A-Za-z_][A-Za-z0-9_]*\\s*=") == @[qkPossessive, qkPossessive]
    check all("x1 = 2, _y=3", "[A-Za-z_][A-Za-z0-9_]*\\s*=") == @["x1 =", "_y="]

  test "a positive lookahead is the follower, not a node to walk past":
    check kinds("\\w+(?=\\()") == @[qkPossessive]
    check all("f(x) g y(", "\\w+(?=\\()") == @["f", "y"]

  test "the last repeat of a repeated group keeps its greedy exits":
    # ``(?:\w+\s+){3,}``: what follows ``\s+`` is the next iteration or
    # whatever follows the group, neither of which this pass reads.
    check kinds("(?:\\w+\\s+){3,}") == @[qkGreedy, qkPossessive, qkGreedy]
    check all("aa bb cc dd ", "(?:\\w+\\s+){3,}") == @["aa bb cc dd "]

  test "nothing after the repeat proves nothing":
    check kinds("\\w+") == @[qkGreedy]
    check kinds("\\w+$") == @[qkGreedy] # an anchor is zero-width, not a follower
    check kinds("(\\w+)\\s*") == @[qkGreedy, qkGreedy]

  test "a follower that shares a character is refused":
    check kinds("\\w+x") == @[qkGreedy]
    check all("aax", "\\w+x") == @["aax"] # the give-back this rewrite would lose
    check kinds("\\w+\\d") == @[qkGreedy]
    check kinds("\\d+\\w") == @[qkGreedy]
    check kinds("\\w+\\W") == @[qkGreedy] # a complement is claimed disjoint from nothing
    check kinds("[a-c]+[c-e]") == @[qkGreedy]
    check kinds("[a-c]+[d-e]") == @[qkPossessive]

  test "an optional follower is walked past, and joins the union":
    # ``x?`` may match empty, so ``=`` speaks too -- and ``x`` still counts.
    # ``x?`` is a repeat of its own, which ``=`` refuses just the same.
    check kinds("\\s+x?=") == @[qkPossessive, qkPossessive]
    check kinds("\\w+x?=") == @[qkGreedy, qkPossessive]
    check all("aax=", "\\w+x?=") == @["aax="]
    check kinds("\\w+x?x") == @[qkGreedy, qkGreedy]
    check all("aax", "\\w+x?x") == @["aax"]

  test "an inverted range follower is mandatory, not optional":
    # ``x{3,1}`` is ``x{1,3}`` possessive by then: mandatory, and it speaks
    # first, so ``\w+`` may not be told that ``=`` is all that follows.
    check kinds("\\w+x{3,1}=") == @[qkGreedy, qkPossessive]
    check all("aaxx=", "\\w+x{3,1}=") == @["aaxx="]
    check kinds("a+a{3,1}b") == @[qkGreedy, qkPossessive]
    check all("aaab", "a+a{3,1}b") == @["aaab"]
    check kinds("\\s+x{3,1}=") == @[qkPossessive, qkPossessive]
    # ``{2,0}`` is ``{0,2}``: optional, so ``=`` speaks too and ``x`` counts.
    check kinds("\\w+x{2,0}=") == @[qkGreedy, qkPossessive]
    check all("aax=", "\\w+x{2,0}=") == @["aax="]
    # ``{0,0}`` matches empty whatever else follows, so the walk reads past it
    # -- and ``x{0,0}`` is a repeat ``=`` refuses just the same.
    check kinds("\\s+x{0,0}=") == @[qkPossessive, qkPossessive]

  test "a zero-width follower only restricts, so the walk reads past it":
    check kinds("\\w+(?!x)=") == @[qkPossessive]
    check kinds("\\w+\\b=") == @[qkPossessive]
    check kinds("\\w+\\K=") == @[qkPossessive]
    check all("aa=b", "\\w+\\K=") == @["="]
    check kinds("\\w+(?!x)") == @[qkGreedy] # zero-width, then nothing

  test "an unstatable follower stops the walk":
    check kinds("(a)\\w+\\1") == @[qkGreedy] # a backreference names no set
    check kinds("(a)\\w+(?(1)a|b)") == @[qkGreedy]
    check kinds("\\w+\\X") == @[qkGreedy] # variable width, no fixed set
    check kinds("\\w+.") == @[qkGreedy] # ``.`` follows (?m) at match time

  test "case folding takes the pattern off the pass":
    # The leaf sets are written for folding off, and an inline ``(?i)`` is a
    # flag group, which nothing below is entered for.
    check kinds("(?i)\\w+=") == @[qkGreedy]
    check kinds("\\w+=", {rfIgnoreCase}) == @[qkGreedy]
    check kinds("(?i:\\w+=)") == @[qkGreedy]
    check kinds("(?m:\\w+=)") == @[qkGreedy]

  test "a subexpression call takes the whole pattern off the pass":
    # A called body runs under the continuation at the call, which this walk
    # never sees.
    check kinds("(\\w+=)\\g<1>") == @[qkGreedy]

  test "a body that is not one leaf is left alone":
    check kinds("(?:ab)+=") == @[qkGreedy]
    check kinds("(\\w)+=") == @[qkGreedy]
    check kinds("[^a]+=") == @[qkGreedy] # a negated class states no exact set
    check kinds("\\p{L}+=") == @[qkGreedy]
    check kinds(".+=") == @[qkGreedy]

  test "only a greedy repeat is rewritten":
    check kinds("\\w+?=") == @[qkLazy]
    check kinds("\\w*+=") == @[qkPossessive] # already possessive, untouched
    check kinds("\\w{3,1}=") == @[qkPossessive] # inverted, possessive already

  test "the rewrite reaches inside groups and alternation branches":
    check kinds("(?>\\w+=)") == @[qkPossessive]
    check kinds("(?=\\w+=)") == @[qkPossessive]
    check kinds("(?:\\w+=|\\s+;)") == @[qkPossessive, qkPossessive]
    check kinds("(?<name>\\s+)=") == @[qkPossessive]

  test "the rewritten repeat still drives the leading-run skip":
    # Which is what makes the rewrite pay rather than cost.
    check re("(\\w+)\\s*=").leadRun != nil
    check all("aaa bbb=", "(\\w+)\\s*=") == @["bbb="]

  test "no character is both a word character and a space":
    # What ``nonAsciiDisjoint`` claims and the ASCII sets do not settle.
    for cp in 0 .. 0x10FFFF:
      let r = Rune(cp)
      for asciiOnly in [false, true]:
        check not (isWordChar(r, asciiOnly) and isSpaceChar(r, asciiOnly))
        check not (isDigitChar(r, asciiOnly) and isSpaceChar(r, asciiOnly))

suite "required-byte region":
  # Bound the scan by the next required byte; pin the set and the matches.
  proc region(pattern: string, flags: RegexFlags = {}): RequiredByteInfo =
    re(pattern, flags).requiredByte

  proc asciiPrefix(pattern: string, flags: RegexFlags = {}): string =
    let r = region(pattern, flags)
    for b in 0'u8 .. 127'u8:
      if b in r.prefix:
        result.add char(b)

  proc all(subject, pattern: string, flags: RegexFlags = {}): seq[string] =
    for m in findAll(subject, re(pattern, flags)):
      result.add captureText(m, 0, subject).get("")

  test "the union holds everything a match consumes before the byte":
    let r = region("(\\w+)\\s*=\\s*(\\w+)")
    check r.valid and r.regionOk
    check r.byte == uint8('=')
    check uint8('a') in r.prefix and uint8('_') in r.prefix
    check uint8(' ') in r.prefix and uint8('\t') in r.prefix
    check uint8('=') notin r.prefix
    # Over-approximation only moves the region left.
    check 0xC3'u8 in r.prefix
    check all("a = b, cc=dd", "(\\w+)\\s*=\\s*(\\w+)") == @["a = b", "cc=dd"]
    check asciiPrefix("\\d+\\.\\d+") == "0123456789"
    check all("1.5 x 22.75", "\\d+\\.\\d+") == @["1.5", "22.75"]

  test "an optional or alternated prefix joins the union whole":
    # Nothing required, so all may precede the byte.
    check asciiPrefix("(?:ab)?c") == "ab"
    check all("abc xc", "(?:ab)?c") == @["abc", "c"]
    check asciiPrefix("(?:a|bc)+=") == "abc"
    check all("abc= x", "(?:a|bc)+=") == @["abc="]
    check uint8('.') in region("(?:\\w|\\.)+=").prefix

  test "a positive look-ahead gives the byte, and its own walk-back with it":
    # ``\s*`` lies between the look-ahead position and the ``=``.
    let r = region("\\w+(?=\\s*=)")
    check r.regionOk and r.byte == uint8('=')
    check uint8(' ') in r.prefix
    check all("key = value", "\\w+(?=\\s*=)") == @["key"]
    check all("a = b, cc=dd", "\\w+(?=\\s*=)") == @["a", "cc"]
    check region("\\w+(?=\\()").byte == uint8('(')
    check all("f(x) g y(", "\\w+(?=\\()") == @["f", "y"]
    # Negative forms and look-behinds state no byte.
    check not region("\\w+(?!=)").valid
    check not region("(?<==)\\w+").valid

  test "a consuming child's byte wins over a look-ahead's":
    # The look-ahead sits where the search already stands.
    check region("(?=a)(\\w+)+b").byte == uint8('b')
    check all("aaaaab x", "(?=a)(\\w+)+b") == @["aaaaab"]
    check search(repeat("a", 30), re("(?=a)(\\w+)+b")).found == false
    # Without one, the look-ahead's byte still stands.
    check region("(?=ab)\\w+").byte == uint8('a')

  test "a leaf the walk cannot state keeps the byte but not the region":
    # The presence test still runs; only the walk-back stands down.
    for p in ["[^a]+=", ".+=", "\\p{L}+=", "(\\w+=)\\g<1>"]:
      let r = region(p)
      check r.valid
      check r.byte == uint8('=')
      check not r.regionOk
    check all("b=c", "[^a]+=") == @["b="]

  test "case folding takes the byte itself off, region and all":
    check not region("(?i)\\w+=").valid
    check not region("\\w+=", {rfIgnoreCase}).valid

  test "a zero-width node between the start and the byte is walked past":
    check region("\\w+\\K=").regionOk
    check all("aa=b", "\\w+\\K=") == @["="]
    check region("x(?<=x)=").byte == uint8('x')
    check all("x= y", "x(?<=x)=") == @["x="]

  test "a stop the decode chain does not bear out skips nothing":
    # Characters vs bytes: on malformed input the stop may fall inside a
    # character or on a consumed tail; it skips nothing.
    proc span(subject, pattern: string, start = 0): string =
      let m = search(subject, re(pattern), start)
      if m.found:
        $m.matchSpan.a & "," & $m.matchSpan.b
      else:
        "-"

    # ``F0`` declares four bytes, so the scan steps 0 -> 3 and never visits 2.
    check span("\xF0\xA9=", "\\t*=") == "-"
    check span("\xE0b=", "\\s*=") == "-"
    check span("\xA9\xC3c=\x80", "(?:ab)?c") == "-"
    # ``\w+`` consumes ``F0 A9 80 20`` whole, so refused ``20`` still precedes ``=``.
    check span("\x80\xF0\xA9\x80 =\xC3\x80", "\\w+=") == "1,6"
    check span("\xA9a=c\xC3 =", "\\w+\\K=", 2) == "6,7"
    check span("\xE0 \x80AAA=\x80Aa", "^\\w+=") == "0,7"
    check span("b\x80\xE0a=x=A \xE0", "(?:\\w(?=x))+") == "2,5"
    # Overlong ``E0 80 0A`` never classifies as ``0A``; the union sees the non-ASCII family.
    check span("\x80\xE0\x80\x0A=", "\\S=") == "1,5"
    check span(
      "\x3B\xF0\x9F\x98\x80 x\xE0\x80 \xC3\xA9=",
      "\\S{1,3}={1,3}(;|([0-9=]|[0-9=])){0,2}",
    ) == "6,13"

  test "a dense byte stands the region down without changing the answer":
    # Dense ``e``: the region stands down after ``RegionTrial``.
    var subject = ""
    for i in 1 .. 200:
      subject.add "the eel eats every egg\n"
    let got = all(subject, "\\w*e\\w*")
    check got.len == 1000
    check got[0 .. 4] == @["the", "eel", "eats", "every", "egg"]

suite "inverted range normalisation":
  # ``{n,m}`` with ``n > m`` is Oniguruma's spelling for the swapped range
  # taken possessively.  The compiler rewrites it once, so everything below
  # reads the bounds and the kind as written -- pin both the rewritten node
  # and the matches, since a wrong rewrite changes what the pattern means.
  proc quant(pattern: string, flags: RegexFlags = {}): Node =
    proc walk(node: Node): Node =
      if node == nil:
        return nil
      if node.kind == nkQuantifier:
        return node
      for child in node.childNodes:
        let q = walk(child)
        if q != nil:
          return q
      nil

    walk(re(pattern, flags).ast)

  proc shape(pattern: string, flags: RegexFlags = {}): (int, int, QuantKind) =
    let q = quant(pattern, flags)
    (q.quantMin, q.quantMax, q.quantKind)

  proc shapes(pattern: string, flags: RegexFlags = {}): seq[(int, int, QuantKind)] =
    ## Every quantifier's bounds and kind, outermost first.
    proc walk(node: Node, into: var seq[(int, int, QuantKind)]) =
      if node == nil:
        return
      if node.kind == nkQuantifier:
        into.add (node.quantMin, node.quantMax, node.quantKind)
      for child in node.childNodes:
        walk(child, into)

    walk(re(pattern, flags).ast, result)

  proc atomicRepeat(pattern: string, flags: RegexFlags = {}): bool =
    ## Whether the outermost quantifier sits under an atomic group of its own.
    proc walk(node: Node): bool =
      if node == nil:
        return false
      if node.kind == nkAtomicGroup and node.atomicBody != nil and
          node.atomicBody.kind == nkQuantifier:
        return true
      if node.kind == nkQuantifier:
        return false # a bare repeat came first
      for child in node.childNodes:
        if walk(child):
          return true
      false

    walk(re(pattern, flags).ast)

  test "an inverted range is rewritten into the possessive swapped range":
    check shape("a{3,1}") == (1, 3, qkPossessive)
    check shape("a{2,0}") == (0, 2, qkPossessive)
    check not atomicRepeat("a{3,1}") # up to one rep the loop is enough

  test "a swapped minimum above one is spelled out as atomic greedy":
    # Possessive is atomic around greedy, and the two part only when the
    # minimum needs the body to give characters back.  The possessive loop
    # takes each iteration's first match and keeps it, so that minimum is
    # matched the long way instead -- see ``normaliseInvertedRanges``.
    check atomicRepeat("a{3,2}")
    check shape("a{3,2}") == (2, 3, qkGreedy)
    # Still atomic: the repeat as a whole gives nothing back afterwards.
    check not search("aaa", re("a{3,2}a")).found

  test "the swapped minimum may split the body to reach itself":
    # ``(?:a+){4,2}`` takes ``"aaa"`` then ``"a"``: two reps, the minimum.
    check search("aaaa", re("(?:a+){4,2}$")).matchSpan == 0 .. 4
    check search("aaaa", re("(?:.a*){3,2}\\b")).matchSpan == 0 .. 4
    check search("aaab", re("a(?:a*a){3,2}")).matchSpan == 0 .. 3
    block:
      let m = search("aaaa", re("((a|)a){5,4}\\b"))
      check m.matchSpan == 0 .. 4
      check m.captureSpan(1) == 3 .. 4
      check m.captureSpan(2) == 3 .. 3
    block:
      let m = search("aaaa", re("(a+a*|b){4,2}"))
      check m.matchSpan == 0 .. 4
      check m.captureSpan(1) == 3 .. 4

  test "a suffix on an inverted range chains onto it":
    # ``?`` and ``+`` after ``{3,1}`` parse as a quantifier of their own, so
    # the rewritten range keeps the kind the bounds gave it.
    check shapes("a{3,1}?") == @[(0, 1, qkGreedy), (1, 3, qkPossessive)]
    check shapes("a{3,1}+") == @[(1, -1, qkGreedy), (1, 3, qkPossessive)]
    check shapes("a{1,3}?") == @[(1, 3, qkLazy)] # not inverted: plain lazy

  test "a range that is not inverted is left as written":
    check shape("a{1,3}") == (1, 3, qkGreedy)
    # A literal body would be written out by ``tuneRepeats``, so this one asks
    # a class instead; ``{3,3}`` is the shape under test either way.
    check shape("[a]{3,3}") == (3, 3, qkGreedy)
    check shape("a{3,}") == (3, -1, qkGreedy) # open-ended, so never inverted
    check shape("a{3,}?") == (3, -1, qkLazy)

  test "the rewrite runs where auto-possessification does not":
    # ``possessifyRepeats`` bails on case folding and on ``\g<...>``; this
    # pass is about what the range means, so it runs regardless.
    check shape("a{3,1}", {rfIgnoreCase}) == (1, 3, qkPossessive)
    check shape("(?i)a{3,1}") == (1, 3, qkPossessive)
    check shape("(x{3,1})\\g<1>") == (1, 3, qkPossessive)

  test "the rewrite reaches every body a quantifier can sit in":
    check shape("(?:a{3,1})") == (1, 3, qkPossessive)
    check shape("(a{3,1})") == (1, 3, qkPossessive)
    check shape("(?=a{3,1})") == (1, 3, qkPossessive)
    check shape("(?>a{3,1})") == (1, 3, qkPossessive)
    check shape("b|a{3,1}") == (1, 3, qkPossessive)

  test "the rewritten range takes its characters without giving them back":
    # Which is what ``{3,1}`` meant all along -- ``a{1,3}`` would give one up.
    check not search("aaa", re("a{3,1}a")).found
    check search("aaa", re("a{1,3}a")).matchSpan == 0 .. 3
    check search("aaa", re("a{3,1}")).matchSpan == 0 .. 3

  test "the swapped minimum is what the match requires":
    check search("aab", re("a{3,2}b")).matchSpan == 0 .. 3
    check search("aaab", re("a{3,2}b")).matchSpan == 0 .. 4
    check not search("b", re("a{3,2}b")).found # two ``a`` are still mandatory
    check search("y", re("x{2,0}y")).matchSpan == 0 .. 1 # ``{0,2}``: none are

  test "a body that matches empty satisfies the swapped minimum":
    # Repeating an empty match would stay empty, so one such iteration answers
    # every rep the minimum still wants -- as ``(?:x?){3,}`` already has it.
    check search("b", re("(?:x?){3,2}")).matchSpan == 0 .. 0
    check search("", re("a?{3,2}")).matchSpan == 0 .. 0
    check search("", re("(?:){5,2}")).matchSpan == 0 .. 0
    # The empty iteration's captures are what the match reports.
    block:
      let m = search("", re("(x*){3,2}"))
      check m.matchSpan == 0 .. 0
      check m.captureSpan(1) == 0 .. 0
    block:
      let m = search("", re("(?:(x)|(y?)){3,2}"))
      check m.matchSpan == 0 .. 0
      check m.captureSpan(1).a < 0
      check m.captureSpan(2) == 0 .. 0
    # A body that can consume still takes what it can before going empty.
    check search("aab", re("(a*){5,2}b")).matchSpan == 0 .. 3
    check search("ac", re("(?:a|){4,2}c")).matchSpan == 0 .. 2

suite "repeat tuning":
  # A repeat over a repeat collapses, and an exact repeat of a literal is
  # written out -- both the way Oniguruma does it, and both identities on
  # their own.  What they are for is the shape the look-behind reduction
  # reads afterwards, so pin the compiled shape and the matches together.
  proc shapes(pattern: string, flags: RegexFlags = {}): seq[(int, int, QuantKind)] =
    ## Every quantifier's bounds and kind, outermost first.
    proc walk(node: Node, into: var seq[(int, int, QuantKind)]) =
      if node == nil:
        return
      if node.kind == nkQuantifier:
        into.add (node.quantMin, node.quantMax, node.quantKind)
      for child in node.childNodes:
        walk(child, into)

    walk(re(pattern, flags).ast, result)

  test "a nested pair collapses to the one repeat that means the same":
    check shapes("(?:a*)*") == @[(0, -1, qkGreedy)]
    check shapes("(?:a*)+") == @[(0, -1, qkGreedy)]
    check shapes("(?:a?)+") == @[(0, -1, qkGreedy)]
    check shapes("(?:a+)?") == @[(0, -1, qkGreedy)]
    check shapes("(?:a+)+") == @[(1, -1, qkGreedy)]
    check shapes("(?:a?)?") == @[(0, 1, qkGreedy)]
    check shapes("(?:a+?)*?") == @[(0, -1, qkLazy)]
    check shapes("(?:a*?)*") == @[(0, -1, qkLazy)]
    # Three deep is two collapses, innermost first.
    check shapes("(?:(?:a*)*)*") == @[(0, -1, qkGreedy)]

  test "every reduce-table cell collapses to its rule":
    # The six ``??`` cells are pinned in their own test; the other twenty
    # cells of the 6x6 table are pinned here. Each pair becomes the shape
    # its cell dictates, so a mistranscribed cell changes one of these.
    # Inner ``?`` row: the three cells the first test leaves out.
    check shapes("(?:a?)*") == @[(0, -1, qkGreedy)] # raStar
    check shapes("(?:a?)??") == @[(0, 1, qkLazy)] # raLazyOpt
    check shapes("(?:a?)*?") == @[(0, -1, qkLazy)] # raLazyStar
    # Inner ``*`` row.
    check shapes("(?:a*)?") == @[(0, -1, qkGreedy)] # raDel
    check shapes("(?:a*)*?") == @[(0, 1, qkLazy), (1, -1, qkGreedy)] # raPlusLazyOpt
    check shapes("(?:a*)+?") == @[(0, -1, qkGreedy)] # raDel
    # Inner ``+`` row.
    check shapes("(?:a+)*") == @[(0, -1, qkGreedy)] # raStar
    check shapes("(?:a+)??") == @[(0, 1, qkLazy), (1, -1, qkGreedy)] # raAsIs
    check shapes("(?:a+)*?") == @[(0, 1, qkLazy), (1, -1, qkGreedy)] # raPlusLazyOpt
    check shapes("(?:a+)+?") == @[(1, -1, qkGreedy)] # raDel
    # Inner ``*?`` row: every cell keeps the inner ``*?``.
    check shapes("(?:a*?)?") == @[(0, -1, qkLazy)] # raDel
    check shapes("(?:a*?)+") == @[(0, -1, qkLazy)] # raDel
    check shapes("(?:a*?)??") == @[(0, -1, qkLazy)] # raDel
    check shapes("(?:a*?)*?") == @[(0, -1, qkLazy)] # raDel
    check shapes("(?:a*?)+?") == @[(0, -1, qkLazy)] # raDel
    # Inner ``+?`` row.
    check shapes("(?:a+?)?") == @[(0, 1, qkGreedy), (1, -1, qkLazy)] # raAsIs
    check shapes("(?:a+?)*") == @[(0, -1, qkGreedy)] # raStar
    check shapes("(?:a+?)+") == @[(1, -1, qkGreedy)] # raPlus
    check shapes("(?:a+?)??") == @[(0, -1, qkLazy)] # raLazyStar
    check shapes("(?:a+?)+?") == @[(1, -1, qkLazy)] # raDel

  test "the two rules that do not flatten the pair":
    # ``(?:X*)??`` is ``(?:X+)??``: the outer repeat still owns the choice of
    # taking nothing at all, so the inner one may as well take something.
    check shapes("(?:a*)??") == @[(0, 1, qkLazy), (1, -1, qkGreedy)]
    # And one pair Oniguruma leaves exactly as written.
    check shapes("(?:a?)+?") == @[(1, -1, qkLazy), (0, 1, qkGreedy)]
    check search("aab", re("(?:a*)??b")).matchSpan == 0 .. 3
    check search("aab", re("(?:a?)+?b")).matchSpan == 0 .. 3

  test "a capture or a possessive stops the collapse":
    # ``(a*)*`` and ``a*`` do not write the same group, and a possessive is an
    # atomic group in Oniguruma, so neither pair is one the table reads.
    check shapes("(a*)*") == @[(0, -1, qkGreedy), (0, -1, qkGreedy)]
    check shapes("(?:a*+)*") == @[(0, -1, qkGreedy), (0, -1, qkPossessive)]
    check shapes("(?:a*)*+") == @[(0, -1, qkPossessive), (0, -1, qkGreedy)]
    # The group is left holding the empty last iteration, as in Oniguruma.
    check search("aaa", re("(a*)*")).captureSpan(1) == 3 .. 3

  test "two exact counts multiply":
    check re("(?:a{2}){3}").ast.bytes == "aaaaaa"
    check shapes("(?:[ab]{2}){3}") == @[(6, 6, qkGreedy)]
    check search("ababab", re("(?:a{2}){3}")).found == false
    check search("aaaaaa", re("(?:a{2}){3}")).matchSpan == 0 .. 6
    # A product past what the parser will spell stays the pair it was written
    # as, which matches the same text.
    check shapes("(?:a{1000}){1000}") ==
      @[(1000, 1000, qkGreedy), (1000, 1000, qkGreedy)]

  test "an unbounded inner repeat pins a counted outer one to its minimum":
    # Every iteration after the first matches empty, so the count above the
    # minimum buys nothing.
    check shapes("(?:[ab]*){2,4}") == @[(2, 2, qkGreedy), (0, -1, qkGreedy)]
    check shapes("(?:[ab]*){0,4}") == @[(0, 1, qkGreedy), (0, -1, qkGreedy)]
    check shapes("(?:[ab]+){3,5}") == @[(3, 3, qkGreedy), (1, -1, qkGreedy)]

  test "a lazy-optional inner collapses for every outer":
    # The ``??`` row of the table, all six cells. Each pair becomes a lazy
    # repeat: ``raDel`` keeps the inner ``??``, every other cell becomes
    # ``*?``. A mistranscribed cell changes one of these shapes.
    check shapes("(?:a??)?") == @[(0, 1, qkLazy)]
    check shapes("(?:a??)*") == @[(0, -1, qkLazy)]
    check shapes("(?:a??)+") == @[(0, -1, qkLazy)]
    check shapes("(?:a??)??") == @[(0, 1, qkLazy)]
    check shapes("(?:a??)*?") == @[(0, -1, qkLazy)]
    check shapes("(?:a??)+?") == @[(0, -1, qkLazy)]
    # Every span below is libonig 6.9.10's.
    check search("aab", re("(?:a??)*b")).matchSpan == 0 .. 3
    check search("aab", re("(?:a??)+b")).matchSpan == 0 .. 3
    check search("aab", re("(?:a??)??b")).matchSpan == 1 .. 3
    check search("aab", re("(?:a??)?b")).matchSpan == 1 .. 3
    check search("aab", re("(?:a??)*?b")).matchSpan == 0 .. 3
    check search("aab", re("(?:a??)+?b")).matchSpan == 0 .. 3

  test "only a greedy outer over an unbounded greedy inner pins the count":
    # The rule beside the table fires for ``*``/``+`` inside with a greedy
    # counted outside. A lazy kind on either side, or an open-ended outer,
    # leaves the pair as written; flipping the ``qkGreedy`` check or the
    # ``{1, 2}`` set changes one of these shapes.
    check shapes("(?:[ab]*){2,4}?") == @[(2, 4, qkLazy), (0, -1, qkGreedy)]
    check shapes("(?:[ab]+){2,4}?") == @[(2, 4, qkLazy), (1, -1, qkGreedy)]
    check shapes("(?:[ab]*){0,4}?") == @[(0, 4, qkLazy), (0, -1, qkGreedy)]
    check shapes("(?:[ab]*?){2,4}") == @[(2, 4, qkGreedy), (0, -1, qkLazy)]
    check shapes("(?:[ab]+?){2,4}") == @[(2, 4, qkGreedy), (1, -1, qkLazy)]
    check shapes("(?:[ab]*){2,}") == @[(2, -1, qkGreedy), (0, -1, qkGreedy)]
    # ``+`` after braces chains rather than turning possessive, so this is a
    # greedy ``+`` over the pinned ``{2,2}``.
    check shapes("(?:[ab]*){2,4}+") ==
      @[(1, -1, qkGreedy), (2, 2, qkGreedy), (0, -1, qkGreedy)]
    # Every span below is libonig 6.9.10's.
    check search("aaab", re("(?:[ab]*){2,4}?")).matchSpan == 0 .. 4
    check search("aaab", re("(?:[ab]*?){2,4}")).matchSpan == 0 .. 0
    check search("aaab", re("(?:[ab]*){2,}")).matchSpan == 0 .. 4
    check search("aaab", re("(?:[ab]*){2,4}+")).matchSpan == 0 .. 4

  test "an exact repeat of a literal is written out":
    check re("a{3}").ast.kind == nkString
    check re("a{3}").ast.bytes == "aaa"
    check re("(?:ab){2}").ast.bytes == "abab"
    check search("aaa", re("a{3}")).matchSpan == 0 .. 3
    check search("abab", re("(?:ab){2}")).matchSpan == 0 .. 4
    # An escaped literal takes the nkEscapedLiteral branch.
    check re("\\*{3}").ast.kind == nkString
    check re("\\*{3}").ast.bytes == "***"
    check search("***", re("\\*{3}")).matchSpan == 0 .. 3
    # Not an exact count, not a literal body, and past the length bound: each
    # stays a repeat.
    check shapes("a{2,3}") == @[(2, 3, qkGreedy)]
    check shapes("[ab]{3}") == @[(3, 3, qkGreedy)]
    check shapes("a{101}") == @[(101, 101, qkGreedy)]

  test "case folding stands the expansion down":
    # ``(?i)ff`` matches U+FB00 and ``(?i)f{2}`` does not, in Oniguruma as
    # here: it expands the multi-character fold while the repeat still holds a
    # one-character string.  Writing the repeat out would hand reni's
    # match-time folding a pair Oniguruma never gives it.
    const Ff = "\u{FB00}"
    check search(Ff, re("(?i)ff")).matchSpan == 0 .. 3
    check not search(Ff, re("(?i)f{2}")).found
    check shapes("(?i)f{2}") == @[(2, 2, qkGreedy)]
    # A scoped fold anywhere in the pattern is enough to stand it down.
    check shapes("(?i:z)f{2}") == @[(2, 2, qkGreedy)]
    check re("f{2}").ast.kind == nkString

  test "a look-behind body reduces only once the pair is flat":
    # This is what the pass is for.  ``(?<=(?:a*)*\b)`` is ``(?<=\b)`` to
    # Oniguruma: the pair collapses to ``a*``, the look-behind reduction pins
    # that to ``a{0}`` and drops it, and the body left over is fixed-length,
    # so it reads the real subject rather than a window.  Every answer below
    # is libonig 6.9.x's.
    check search("ab", re("(?<=(?:a*)*\\b)")).matchSpan == 0 .. 0
    check search("ab", re("(?<=(?:a*)*\\b)a")).matchSpan == 0 .. 1
    check search("ab", re("(?<=(?:a*)+\\b)")).matchSpan == 0 .. 0
    check search("ab", re("(?<=(?:a+)*\\b)")).matchSpan == 0 .. 0
    check search("ab", re("(?<=(?:(?:ab)*)*\\b)")).matchSpan == 0 .. 0
    check search("ab", re("(?<=(?:a*)*\\B)")).matchSpan == 1 .. 1
    # The same for a body the expansion is what flattens.
    check search("ab", re("(?<=(?:a{2})*\\b)")).matchSpan == 0 .. 0
    # A counted outer repeat is not a pair Oniguruma flattens, so the body
    # stays variable-length and keeps its window.
    check search("ab", re("(?<=(?:a*){1,2}\\b)")).matchSpan == 2 .. 2

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
