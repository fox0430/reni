## Randomized differential test: reni against the Oniguruma C library.
##
## The engine's rollback machinery runs on invariants that no single example
## pins down -- which construct owns the undo for a capture, and how much of
## the state a given backtrack has to restore.  Optimizations narrow those
## invariants one at a time, and an example-based suite keeps passing while a
## narrowing is wrong, because the shape that breaks is a combination nobody
## wrote down.  So generate the combinations instead, and let the library reni
## is compatible with answer them.
##
## Oniguruma is the reference, but it is not infallible, so a disagreement is
## put to PCRE2 -- already bound in ``bench/`` -- before it counts.  Only a
## disagreement PCRE2 confirms, by answering exactly what Oniguruma answered,
## fails the test.  Anything else is recorded as disputed and printed: two of
## the three engines have to agree against reni before the finger points here.
## (``(?=(a)?x*?x).+`` on "qxbxq" is a live example: Oniguruma reports no
## match, reni and PCRE2 both report 1..5.)
##
## An engine that gives up has not answered, and casts no vote.  Oniguruma
## stops at its retry limit (``ONIGERR_RETRY_LIMIT_IN_MATCH_OVER``), PCRE2 at
## its match, depth and heap limits, and the generator does reach Oniguruma's.
## Read as "no match", that error would be a vote nobody cast: against reni it
## would make a quorum with PCRE2, and with reni it would count as an
## agreement.  So when Oniguruma gives up and reni answers, the case is put to
## PCRE2 alone.  It is counted apart from ``compared``, and a disagreement is
## printed in a list of its own, where ordinary disputes cannot crowd it out.
## One that is only the iteration split described next is counted and not
## printed, so it cannot either.  Nothing fails on one oracle's word.  When
## reni's step limit stops it too, the case is skipped, like any other that
## reni does not answer.
##
## One class is disputed even when PCRE2 sides with Oniguruma: the span a
## group is left holding after a repetition, when the engines split the same
## text into iterations differently.  On ``x(?:(q|\w*?)){0,2}a`` against
## "bxxab", Perl, Python and reni all report group 1 as 3..3, the empty final
## iteration; PCRE2 reports 2..3, the iteration before it.  The same split
## happens with no empty iteration in sight: on ``(a*?){0,2}x`` against "aax",
## Perl, Python, Oniguruma and reni all report 1..2 -- two iterations of one
## "a" -- where PCRE2 reports 0..2, one iteration of "aa".
##
## Oniguruma gives *both* answers depending on whether a backreference appears
## elsewhere in the pattern, which is what makes the quorum unreliable here
## rather than merely split: wrap that same pattern in one and Oniguruma moves
## to PCRE2's side, so two engines "confirm" a span that Perl and Python read
## the way reni does.  So a divergence whose differing spans are empty on one
## side, or end at the same offset, is reported, not failed.
##
## The split is not confined to the group it happens in: a backreference
## consumes what the losing iteration left there, so the match span moves with
## it.  ``onlyIterationSplitSpans`` excuses that on a narrower tell.
##
## Patterns come from a small grammar weighted towards the constructs that
## stress rollback: captures inside quantified groups, lookarounds that keep
## what they captured, conditionals, atomic groups, backreferences, and ``\K``
## -- which a positive assertion keeps the way it keeps its captures, so the
## same rollbacks own it.  Roughly a third of the patterns carry one.
## Subjects are short strings over a tiny alphabet, so a random pattern has a
## real chance of matching and of matching in several ways.
##
## Run with (see the build note below for ``-d:reniFuzzDiff``):
##   nim c -r -d:release -d:reniFuzzDiff --path:. tests/test_fuzz_oniguruma
##   RENI_FUZZ_SEEDS=64 RENI_FUZZ_ITERS=200000 ./tests/test_fuzz_oniguruma
##
## The default sweeps several seeds rather than running one long stream: at
## roughly 160k comparisons a second the whole default run costs a few
## seconds, and spreading that across seeds finds more than deepening one of
## them does.  Measured against the commit this file was written for, one seed
## at 60k comparisons found nothing and the default sweep found the bugs.
##
## Everything is deterministic from ``RENI_FUZZ_SEED``, and every run prints
## the seeds it used, so a divergence reproduces with the pattern and subject
## it prints -- a reduced test case as it stands, since the generator keeps
## patterns short on purpose.
##
## The corpus is a function of the seed alone: the generator draws from the
## ``Rand`` defined below, not from ``std/random``, so the seed the CI job
## spells out (see ``.github/workflows/test.yml``) names the same patterns on
## every toolchain.  That is the point of carrying a PRNG here -- the job runs
## on Nim ``stable`` deliberately, and a corpus that moves with the compiler
## would turn a required job red on a release with no change under test.
##
## The default seed is clean; other seeds are not.  Two shapes are open, both
## older than this file.  Each case quoted for them diverges on its own, with
## Oniguruma 6.9.10 and PCRE2 10.49 giving the same answer against reni:
##
## * an atomic group over a possessive body, where reni gives up a match the
##   other two engines find -- ``[ba]?(?>(.{1,3}+|(b?))\2{1,3}){1,3}`` on
##   "abqq" answers 0..1 here and 0..4 there, and
##   ``b((([ab])a*+|a*?)(\3.*?(?>ab*q)|a\w(?>x\w++x))*?|a*?\2\w+){0,2}a`` on
##   "bxbaba" 2..4 here and 0..6 there;
## * an alternation lookbehind, which reni retries once the continuation after
##   it fails where both oracles read the assertion as atomic --
##   ``(?>baa|b(?<=b|(.))\1)`` on "bbabaa" answers 0..2 here and 3..6 there,
##   and ``((?<=a|(.))\2{0,2}+\w)\2b`` on "aaab" 1..4 here and no match there.
##
## No sweep is named for either: the corpus of none of the ones this list used
## to name (seeds 424242, 20250101 and 99991, 24 each) holds any of the four
## patterns.  It also named two more shapes, a backreference to a group that a
## repetition writes: ``(\w{0,2}+b{0,2}+)+\w(?:(q\1)a*)+`` on "xaaqaax" and
## ``(a{0,2}+.*(?:a*?){0,2})*\1a`` on "aqbbxqx".  Neither is a divergence.
## Oniguruma gives up on both, and PCRE2 was asked ``{0,2}+`` as a possessive
## interval; asked what Oniguruma reads, it answers as reni does.
##
## A wider sweep also prints cases where PCRE2 sides with Oniguruma and Perl
## 5.42 with reni.  Sweeping 128 seeds from the default prints three.
## ``RENI_FUZZ_SEED=20260978 RENI_FUZZ_SEEDS=1`` prints ``(.*?x?){0,2}x\1`` on
## "axa": 0..2 here and 0..3 there, the iteration split above carried into the
## match span by a backreference, past what ``onlyIterationSplitSpans``
## excuses.  ``RENI_FUZZ_SEED=20260960 RENI_FUZZ_SEEDS=1`` prints the same
## split carried into the group, with
## ``(?:(b|q*?+){0,2}\1*+a|(?:\w{1,3}(?:b{0,2}qb)?)b*?+\Kx)\K`` on "qqqqaaq";
## it reduces to ``(q*?){0,2}\1*a`` on "qqqqa", where group 1 holds 1..2 here,
## in Perl and in Python, and 0..1 there.
## ``RENI_FUZZ_SEED=20261033 RENI_FUZZ_SEEDS=1`` prints
## ``^((?:(?!bxx)(?=ba\w)\Kb+\K|q)*(a{0,2})\K(?:(\2?)|(\3\K\3\Kb)){0,2}\K)q``
## on "bq": no match here and 1..2 there.  It has not been reduced.
##
## So a red run is not automatically a new bug: read the divergence it prints
## against the cases above before suspecting the change under test.

## Building this links against Oniguruma and PCRE2, which the rest of
## ``tests/`` does not, so it is opt-in: without ``-d:reniFuzzDiff`` the file
## compiles to a notice and ``nimble test`` keeps working on a machine with
## neither library.  Install both development packages (``oniguruma`` /
## ``libonig-dev`` and ``pcre2`` / ``libpcre2-dev``), as ``bench/README.md``
## describes, then:
##
##   nim c -r -d:release -d:reniFuzzDiff --path:. tests/test_fuzz_oniguruma
##

when not defined(reniFuzzDiff):
  echo "test_fuzz_oniguruma: skipped (build with -d:reniFuzzDiff)"
else:
  import std/[os, strformat, strutils, unittest]

  import ../reni
  import ../bench/onig
  import ../bench/pcre2

  const
    Alphabet = "aabbxq" ## Doubled letters bias subjects towards repetition.
    MaxSubjectLen = 7
    DefaultIters = 100_000 ## per seed
    DefaultSeeds = 8

  type Rand = object
    ## A self-contained SplitMix64, so that ``RENI_FUZZ_SEED`` alone
    ## determines the corpus.  ``std/random`` generates the same shapes, but
    ## its stream is an implementation detail of the Nim release, and the CI
    ## job that runs this file tracks ``stable`` on purpose: drawing from
    ## ``std/random`` there means a toolchain bump re-rolls the whole sweep
    ## onto shapes the pinned seed was never measured on, turning a required
    ## job red with no change under test.  Twenty lines of generator buy back
    ## a corpus that a seed in a workflow file actually names.
    ##
    ## Quality is not the point and neither is the modulo bias below: the
    ## bounds here are single digits against a 64-bit stream, and what the
    ## sweep needs is a spread of shapes that reproduces, not uniformity.
    state: uint64

  const
    SplitMixGamma = 0x9E3779B97F4A7C15'u64
    SplitMixMixA = 0xBF58476D1CE4E5B9'u64
    SplitMixMixB = 0x94D049BB133111EB'u64

  proc initRand(seed: int): Rand =
    ## Seeds differing by one still give unrelated streams: the seed goes
    ## through the same output mix as every draw, so the sweep can walk
    ## ``baseSeed + s`` the way it did before.
    Rand(state: cast[uint64](seed) xor SplitMixGamma)

  proc next(r: var Rand): uint64 =
    r.state = r.state + SplitMixGamma
    var z = r.state
    z = (z xor (z shr 30)) * SplitMixMixA
    z = (z xor (z shr 27)) * SplitMixMixB
    z xor (z shr 31)

  proc rand(r: var Rand, max: int): int =
    ## Uniform over ``0 .. max`` inclusive, as ``std/random``'s ``rand`` is,
    ## so every call site below reads the same way it always did.
    int(r.next() mod uint64(max + 1))

  proc sample(r: var Rand, s: string): char =
    s[r.rand(s.len - 1)]

  proc sample[T](r: var Rand, s: openArray[T]): T =
    s[r.rand(s.len - 1)]

  proc envInt(name: string, fallback: int): int =
    let v = getEnv(name)
    if v.len == 0:
      fallback
    else:
      (
        try:
          parseInt(v)
        except ValueError:
          fallback
      )

  type Spelling = object
    ## A generated pattern as each engine is asked it.  reni and Oniguruma
    ## read ``onig``; PCRE2 gets the same pattern spelled the way its own
    ## syntax reads what Oniguruma reads, which differs only where
    ## ``quantified`` says.  The generator writes both as it goes, since it is
    ## the one place that knows where each quantifier and its operand are.
    onig, pcre2: string

  proc both(s: string): Spelling =
    ## ``s``, which the two syntaxes read alike.
    Spelling(onig: s, pcre2: s)

  proc `&`(a, b: Spelling): Spelling =
    Spelling(onig: a.onig & b.onig, pcre2: a.pcre2 & b.pcre2)

  proc `&`(a: Spelling, b: string): Spelling =
    a & both(b)

  proc `&`(a: string, b: Spelling): Spelling =
    both(a) & b

  proc `&=`(a: var Spelling, b: Spelling | string) =
    a = a & b

  type Gen = object
    r: Rand
    groups: int ## Capture groups opened so far, i.e. the numbering counter.
    closed: seq[int]
      ## Groups whose ``)`` has already been emitted.  Backreferences and
      ## conditionals only ever name one of these, because a reference to a
      ## group it sits *inside* is a construct the two engines read differently:
      ## Oniguruma clears the group on re-entry, so ``((?(1)a|b))+`` matches
      ## "bb" there and "ba" here, and ``(a\\1?)+`` splits the same way.  That
      ## disagreement is real and predates this file; leaving it in would mask
      ## every other divergence behind the same few shapes.

  proc atom(g: var Gen): string =
    case g.r.rand(9)
    of 0 .. 4:
      $g.r.sample(Alphabet)
    of 5:
      "."
    of 6:
      "[" & (if g.r.rand(1) == 0: "^" else: "") & g.r.sample(Alphabet) &
        g.r.sample(Alphabet) & "]"
    of 7:
      r"\w"
    of 8:
      if g.closed.len > 0:
        r"\" & $g.r.sample(g.closed)
      else:
        $g.r.sample(Alphabet)
    else:
      $g.r.sample(Alphabet)

  proc expr(g: var Gen, depth: int): Spelling

  proc lookPiece(g: var Gen): string =
    ## One element of a lookbehind body: a bare atom, or a capturing group
    ## around one or two.  A lookbehind that captures is the whole point --
    ## ``keepLookCaptures`` and the ``chLookbehindAlt`` commit path own the
    ## rollback for what the body wrote, and a body built out of ``atom``
    ## alone can never reach either, since ``atom`` emits no groups.
    if g.r.rand(2) == 0:
      g.groups += 1
      let idx = g.groups
      let body = atom(g) & (if g.r.rand(1) == 0: "" else: atom(g))
      g.closed.add idx # only now may a reference name it
      "(" & body & ")"
    else:
      atom(g)

  proc lookBehindBody(g: var Gen): string =
    ## One branch of a lookbehind: one or two pieces, so it stays bounded,
    ## with a ``\K`` dropped between them often enough to matter.  A ``\K``
    ## here is the shape that moves a reported start *behind* where the match
    ## began -- and, at the end of the body, ahead of where it stops, which is
    ## the clamp -- so the slot is picked from every position rather than one.
    var pieces = @[lookPiece(g)]
    if g.r.rand(1) != 0:
      pieces.add lookPiece(g)
    let keepAt =
      if g.r.rand(2) == 0:
        g.r.rand(pieces.len)
      else:
        -1
    result = ""
    for i, p in pieces:
      if i == keepAt:
        result &= r"\K"
      result &= p
    if keepAt == pieces.len:
      result &= r"\K"

  proc group(g: var Gen, depth: int): Spelling =
    ## A bracketing construct.  Each arm that captures bumps ``groups`` before
    ## generating its body, so a backreference inside can see itself.
    case g.r.rand(9)
    of 0 .. 2:
      g.groups += 1
      let idx = g.groups
      let body = expr(g, depth - 1)
      g.closed.add idx # only now may a reference name it
      "(" & body & ")"
    of 3, 4:
      "(?:" & expr(g, depth - 1) & ")"
    of 5:
      "(?>" & expr(g, depth - 1) & ")" # atomic
    of 6:
      let neg = g.r.rand(1) == 0
      "(?" & (if neg: "!" else: "=") & expr(g, depth - 1) & ")"
    of 7:
      # Lookbehind: keep the body simple enough to stay bounded, but let it
      # capture, and sometimes make it an alternation -- the fixed, variable
      # and alternation shapes each own their kept captures differently, and
      # the alternation one is the only construct that re-enters a lookbehind
      # after it has already matched once.
      let neg = g.r.rand(1) == 0
      let closedBefore = g.closed.len
      let first = lookBehindBody(g)
      let alt = g.r.rand(2) == 0
      let second =
        if alt:
          "|" & lookBehindBody(g)
        else:
          ""
      if alt:
        # A backreference *outside* an alternation lookbehind, naming a group
        # one of its branches wrote, is another shape the engines split on --
        # and this one splits Oniguruma from itself.  ``(?<=b|(b))\1`` on "bb"
        # answers 1 in Ruby, whose Onigmo re-enters the lookbehind to try the
        # other branch once ``\1`` fails, and no match in Oniguruma 6.9.10 and
        # in PCRE2, which both commit to the branch that already succeeded.
        # reni answers with Ruby.  Two engines make a quorum against it, so
        # leaving the shape in would fail the sweep on a disagreement that is
        # not about rollback at all.  The groups stay numbered; they just stop
        # being nameable from outside.
        g.closed.setLen(closedBefore)
      both("(?<" & (if neg: "!" else: "=") & first & second & ")")
    of 8:
      # Conditional.  Both the backreference and the consuming/lookahead
      # condition forms, since they take different paths through ``condHolds``.
      if g.closed.len > 0 and g.r.rand(1) == 0:
        "(?(" & $g.r.sample(g.closed) & ")" & expr(g, depth - 1) & "|" &
          expr(g, depth - 1) & ")"
      else:
        let cond =
          if g.r.rand(1) == 0:
            "(?=" & expr(g, depth - 1) & ")"
          else:
            expr(g, depth - 1)
        "(?(" & cond & ")" & expr(g, depth - 1) & "|" & expr(g, depth - 1) & ")"
    else:
      "(?:" & expr(g, depth - 1) & ")"

  proc quantifier(g: var Gen): string =
    case g.r.rand(6)
    of 0: "*"
    of 1: "+"
    of 2: "?"
    of 3: "{0,2}"
    of 4: "{1,3}"
    of 5: "*?"
    else: "+?"

  proc quantified(operand: Spelling, q: string, plus: bool): Spelling =
    ## ``operand`` repeated by the quantifier ``q``, followed by a ``+`` when
    ## ``plus`` is set.  The two syntaxes read that ``+`` alike only after a
    ## greedy ``*``, ``+`` or ``?``, where it makes the repeat possessive.
    ## Anywhere else Oniguruma reads a second, greedy ``+`` over the whole
    ## repeat, and PCRE2 does not:
    ##
    ## * after an interval PCRE2 and Perl read a possessive interval, so
    ##   ``a{0,2}+a`` matches "aa" in Oniguruma and reni, not in PCRE2;
    ## * after a lazy ``*?`` or ``+?`` PCRE2 refuses the pattern outright.
    ##
    ## So PCRE2 gets the nested repeat spelled out, as ``(?:X{n,m})+`` or
    ## ``(?:X*?)+``.  Oniguruma does not reduce that repeat away: it answers
    ## ``((a)|b)+?+\2`` as PCRE2 answers ``(?:((a)|b)+?)+\2``, which is not how
    ## it answers ``((a)|b)+?\2``.
    result = operand & q
    if plus:
      if q in ["*", "+", "?"]:
        result &= "+"
      else:
        result = Spelling(onig: result.onig & "+", pcre2: "(?:" & result.pcre2 & ")+")

  proc piece(g: var Gen, depth: int): Spelling =
    result =
      if depth > 0 and g.r.rand(2) == 0:
        group(g, depth)
      else:
        both(atom(g))
    if g.r.rand(2) == 0:
      # Possessive and lazy spellings both matter, and what the ``+`` means
      # depends on what it follows.
      let q = quantifier(g)
      result = quantified(result, q, plus = g.r.rand(5) == 0)

  proc branch(g: var Gen, depth: int): Spelling =
    for _ in 0 .. g.r.rand(2):
      result &= piece(g, depth)
      # ``\K`` parts the span a match reports from the one its attempt ran
      # over, and a positive assertion keeps the start it moved the way it
      # keeps its captures -- so every rollback that restores a capture has to
      # restore this too, and the generator has to be able to put one inside a
      # lookaround, an atomic group and a repetition.  It is never quantified
      # directly -- all three engines reject ``\K*`` outright, so generating
      # one would only inflate the skip count -- but a quantifier on the group
      # around it reaches the same rollback.
      if g.r.rand(9) == 0:
        result &= r"\K"

  proc expr(g: var Gen, depth: int): Spelling =
    result = branch(g, depth)
    if depth > 0 and g.r.rand(3) == 0:
      result &= "|" & branch(g, depth)

  proc pattern(g: var Gen): Spelling =
    g.groups = 0
    g.closed.setLen(0)
    if g.r.rand(2) == 0:
      result &= "^"
    result &= expr(g, 3)

  proc subject(g: var Gen): string =
    for _ in 0 ..< g.r.rand(MaxSubjectLen):
      result &= g.r.sample(Alphabet)

  proc onigSpans(
      reg: OnigRegex, subj: string, region: ptr OnigRegion
  ): seq[(int, int)] =
    ## ``search`` fills ``region``; a mismatch leaves the result empty.  Raises
    ## ``OnigError`` when Oniguruma gives up instead of answering: any code
    ## below ``OnigMismatch`` is an error, not "no match".
    let rc = search(reg, subj, region)
    if rc == OnigMismatch:
      return @[]
    if rc < 0:
      raise newException(OnigError, &"onig_search failed with code {rc}")
    for i in 0 ..< region.numRegs.int:
      result.add (region.beg[i].int, region.ends[i].int)

  proc onlyIterationSplitSpans(a, b: seq[(int, int)]): bool =
    ## True when every span the two answers disagree on differs only in which
    ## iteration of a repetition the group was left holding -- the shape the
    ## engines genuinely disagree about (see the header).  Two tells, either of
    ## which excuses one span:
    ##
    ## * the span is empty on one side -- the final iteration matched empty and
    ##   one engine kept it while the other kept the iteration before it;
    ## * the two spans end at the same offset -- the group reaches the same
    ##   place, but one engine got there in one iteration where the other took
    ##   two, so only the start differs.  ``(a*?){0,2}x`` on "aax" is the
    ##   minimal case: reni, Perl, Python and Oniguruma all say 1..2, PCRE2
    ##   says 0..2, and adding a backreference elsewhere flips Oniguruma onto
    ##   PCRE2's side, manufacturing a quorum against an answer three other
    ##   engines share.
    ##
    ## A wrong rollback moves a span somewhere else entirely -- a stale start
    ## *and* a stale end -- which neither tell covers.
    ##
    ## The match span -- index 0 -- is excused on the same two tells, except
    ## that it takes *both* spans empty rather than one.  The split reaches it
    ## through a backreference, which consumes what the losing iteration left:
    ## on ``(.*?){0,2}a\1`` against "bab" the empty final iteration ends the
    ## match at 2 and the iteration before it at 3.  ``\K`` moves the start the
    ## same way.  But one side empty would excuse an empty match standing
    ## against a span of any length, which is what a rollback bug looks like;
    ## needing both also keeps "matched" against "did not match" failing, since
    ## those two answers differ in length.
    if a.len != b.len or a.len == 0:
      return false
    for i in 0 ..< a.len:
      if a[i] == b[i]:
        continue
      let aEmpty = a[i][0] == a[i][1]
      let bEmpty = b[i][0] == b[i][1]
      let empty =
        if i == 0:
          aEmpty and bEmpty
        else:
          aEmpty or bEmpty
      let sameEnd = a[i][1] == b[i][1]
      if not (empty or sameEnd):
        return false
    true

  proc padded(spans: seq[(int, int)], width: int): seq[(int, int)] =
    ## ``spans`` widened to ``width`` with unset groups, so that two answers
    ## of different widths line up.  "No match" stays empty.
    result = spans
    while result.len > 0 and result.len < width:
      result.add (-1, -1)

  proc pcre2Asked(pat: Spelling): string =
    ## How PCRE2 was asked ``pat``, for a report, when that is not how the
    ## other two were: an answer reproduced from the other spelling differs.
    if pat.pcre2 == pat.onig:
      ""
    else:
      &" (asked /{pat.pcre2}/)"

  proc pcre2Spans(pat: Spelling, subj: string, want: int): seq[(int, int)] =
    ## PCRE2's answer in the same shape, or ``@[]`` for no match.  ``want`` is
    ## how many spans the comparison is about -- it has to be the wider of the
    ## two answers being compared, since a zero would make "matched" and "did
    ## not match" print the same.  Groups PCRE2 left unset come back as
    ## ``(-1, -1)``, as the other two engines spell them.  Raises ``Pcre2Error``
    ## when PCRE2 will not take the pattern, or gives up on the subject.
    let code = pcre2.compile(pat.pcre2, jit = false)
    defer:
      pcre2.free(code)
    let data = pcre2.newMatchData(code)
    defer:
      pcre2.free(data)
    let rc = pcre2.match(code, subj, data, 0)
    if rc == Pcre2ErrorNoMatch:
      return @[]
    if rc <= 0:
      # A match, depth or heap limit, or 0 for an ovector too small to hold
      # the groups: no answer either way.
      raise newException(Pcre2Error, &"pcre2_match failed with code {rc}")
    let ov = pcre2.ovector(data)
    let unset = high(typeof(ov[0])) # PCRE2_UNSET; the size type is bench-private
    for i in 0 ..< want:
      if i < rc.int and ov[2 * i] != unset:
        result.add (ov[2 * i].int, ov[2 * i + 1].int)
      else:
        result.add (-1, -1)

  proc reniSpans(rx: Regex, subj: string): seq[(int, int)] =
    let m = search(subj, rx)
    if not m.found:
      return @[]
    for b in m.boundaries:
      result.add (b.a, b.b)

  suite "reni agrees with Oniguruma on generated patterns":
    test "PCRE2 is asked the pattern Oniguruma reads":
      proc spelled(operand: Spelling, q: string, plus: bool): (string, string) =
        let s = quantified(operand, q, plus)
        (s.onig, s.pcre2)

      check spelled(both("a"), "{0,2}", true) == ("a{0,2}+", "(?:a{0,2})+")
      check spelled(both("(a|b)"), "{1,3}", true) == ("(a|b){1,3}+", "(?:(a|b){1,3})+")
      check spelled(both("a"), "*?", true) == ("a*?+", "(?:a*?)+")
      check spelled(both("(a|b)"), "+?", true) == ("(a|b)+?+", "(?:(a|b)+?)+")
      # A wrapper inside the operand stays inside the outer one.
      let inner = "(" & quantified(both("x"), "*?", true) & ")"
      check spelled(inner, "{0,2}", true) == ("(x*?+){0,2}+", "(?:((?:x*?)+){0,2})+")
      # Possessive, or no ``+`` at all, reads alike.
      for q in ["*", "+", "?"]:
        check spelled(both("a"), q, true) == ("a" & q & "+", "a" & q & "+")
      for q in ["*", "+", "?", "{0,2}", "{1,3}", "*?", "+?"]:
        check spelled(both("a"), q, false) == ("a" & q, "a" & q)

    test "random patterns over a small alphabet":
      initOniguruma()
      defer:
        finalizeOniguruma()
      let iters = envInt("RENI_FUZZ_ITERS", DefaultIters)
      let baseSeed = envInt("RENI_FUZZ_SEED", 20260912)
      let seeds = envInt("RENI_FUZZ_SEEDS", DefaultSeeds)
      let region = newRegion()
      defer:
        free(region)

      var compared, skipped, disputed = 0
      var bothGaveUp, gaveUpRaised, gaveUpAgreed, gaveUpSplit = 0
      var gaveUpDisputed, gaveUpUnanswered = 0
      var failures, disputes, gaveUpDisputes: seq[string]
      var g: Gen
      block sweep:
        for s in 0 ..< seeds:
          g = Gen(r: initRand(baseSeed + s))
          for _ in 0 ..< iters:
            block one:
              let pat = pattern(g)
              let subj = subject(g)

              var reg: OnigRegex
              try:
                reg = compile(pat.onig)
              except OnigError:
                skipped += 1 # Oniguruma rejects it; nothing to compare against.
                break one
              defer:
                free(reg)

              var rx: Regex
              try:
                rx = re(pat.onig)
              except CatchableError:
                # reni rejecting a pattern Oniguruma accepts is worth knowing about,
                # but it is a parser gap, not a rollback bug; keep them apart.
                skipped += 1
                break one

              var want: seq[(int, int)]
              var onigGaveUp = "" # Oniguruma's error, when it did not answer
              try:
                want = onigSpans(reg, subj, region)
              except OnigError as e:
                onigGaveUp = e.msg
              var got: seq[(int, int)]
              try:
                got = reniSpans(rx, subj)
              except RegexLimitError:
                # The generator does produce catastrophic backtrackers, and the step
                # limit stopping one is the engine working as designed.  reni gave
                # no answer, so there is nothing to compare, whatever the oracles
                # said.
                skipped += 1
                if onigGaveUp.len > 0:
                  bothGaveUp += 1
                break one
              except CatchableError as e:
                if onigGaveUp.len > 0:
                  gaveUpRaised += 1
                failures.add &"/{pat.onig}/ on \"{subj}\": reni raised {e.name}: {e.msg}"
                break one
              if onigGaveUp.len > 0:
                # One oracle is no quorum (see the header): PCRE2 only decides
                # whether the case is worth printing.
                var third: seq[(int, int)]
                try:
                  third = pcre2Spans(pat, subj, max(got.len, rx.captureCount + 1))
                except Pcre2Error:
                  gaveUpUnanswered += 1
                  break one
                let gotPadded = padded(got, third.len)
                if gotPadded == third:
                  gaveUpAgreed += 1
                elif onlyIterationSplitSpans(gotPadded, third):
                  gaveUpSplit += 1
                else:
                  gaveUpDisputed += 1
                  if gaveUpDisputes.len < 10:
                    gaveUpDisputes.add &"/{pat.onig}/ on \"{subj}\":\n    onig gave up " &
                      &"({onigGaveUp})\n    reni {got}\n    pcre2 {third}{pat.pcre2Asked}"
                break one
              compared += 1
              if got != want:
                # Ask the third engine before blaming reni.
                var third: seq[(int, int)]
                var thirdError = "" # why PCRE2 gave no answer, when it did not
                try:
                  third = pcre2Spans(pat, subj, max(want.len, got.len))
                except Pcre2Error as e:
                  thirdError = e.msg
                let detail =
                  &"/{pat.onig}/ on \"{subj}\":\n    onig {want}\n    reni {got}"
                # ``want`` is padded to the same width so the three shapes line up.
                let wantPadded = padded(want, third.len)
                if thirdError.len == 0 and third == wantPadded and
                    not onlyIterationSplitSpans(got, want):
                  failures.add detail &
                    &"\n    pcre2 {third}{pat.pcre2Asked} (agrees with onig)"
                else:
                  disputed += 1
                  if disputes.len < 5:
                    disputes.add detail & (
                      if thirdError.len == 0: &"\n    pcre2 {third}{pat.pcre2Asked}"
                      else: &"\n    pcre2 gave no answer: {thirdError}"
                    )
              if failures.len >= 10:
                break sweep

      echo &"  compared {compared}, skipped {skipped}, disputed {disputed} " &
        &"(seeds {baseSeed} .. {baseSeed + seeds - 1}, {iters} each)"
      let gaveUp =
        bothGaveUp + gaveUpRaised + gaveUpAgreed + gaveUpSplit + gaveUpDisputed +
        gaveUpUnanswered
      if gaveUp > 0:
        # Only the first count is in ``skipped``, and only the second in the
        # failures; the rest are in none of the counts above.
        echo &"  onig gave up on {gaveUp}: reni stopped too on {bothGaveUp}, " &
          &"raised on {gaveUpRaised}; pcre2 agrees with reni on {gaveUpAgreed}, " &
          &"splits the iterations differently on {gaveUpSplit}, disagrees on " &
          &"{gaveUpDisputed}, gives no answer on {gaveUpUnanswered}"
      for d in disputes:
        echo "  DISPUTED (reni and pcre2 against onig, or no quorum) ", d
      for d in gaveUpDisputes:
        echo "  DISPUTED (onig gave up, pcre2 against reni) ", d
      if failures.len > 0:
        for f in failures:
          echo "  DIVERGENCE ", f
      check failures.len == 0
      check compared > (iters * seeds) div 4 # the generator still does real work
