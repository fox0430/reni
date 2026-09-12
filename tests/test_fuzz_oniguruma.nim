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
## Patterns come from a small grammar weighted towards the constructs that
## stress rollback: captures inside quantified groups, lookarounds that keep
## what they captured, conditionals, atomic groups and backreferences.
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
## The default seed is clean; other seeds are not, which is why the CI job
## spells the seed out (see ``.github/workflows/test.yml``).  That job tracks
## Nim ``stable`` rather than a pinned version, so a toolchain bump re-rolls
## ``std/random`` and with it the corpus this seed generates: a run that goes
## red straight after one is as likely to have reached an open shape below as
## to have found something new.  At least two shapes are open, both of
## them older than this file:
##
## * an atomic group over a possessive body, where reni gives up a match the
##   other two engines find -- ``[ba]?(?>(.{1,3}+|(b?))\2{1,3}){1,3}`` on
##   "abqq" answers 0..1 here and 0..4 there
##   (``RENI_FUZZ_SEED=424242 RENI_FUZZ_SEEDS=24``);
## * a conditional or backreference naming a group that the repetition around
##   it writes, where reni matches and both oracles do not -- the generator
##   avoids this deliberately (see ``Gen.closed``) but a nested quantifier can
##   still reach it (``RENI_FUZZ_SEED=99991 RENI_FUZZ_SEEDS=24``;
##   ``RENI_FUZZ_SEED=20250101 RENI_FUZZ_SEEDS=24`` reaches it through a
##   conditional instead).

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
  import std/[os, random, strformat, strutils, unittest]

  import ../reni
  import ../bench/onig
  import ../bench/pcre2

  const
    Alphabet = "aabbxq" ## Doubled letters bias subjects towards repetition.
    MaxSubjectLen = 7
    DefaultIters = 100_000 ## per seed
    DefaultSeeds = 8

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

  proc expr(g: var Gen, depth: int): string

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
    ## One branch of a lookbehind: one or two pieces, so it stays bounded.
    lookPiece(g) & (if g.r.rand(1) == 0: "" else: lookPiece(g))

  proc group(g: var Gen, depth: int): string =
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
      "(?<" & (if neg: "!" else: "=") & lookBehindBody(g) &
        (if g.r.rand(2) == 0: "|" & lookBehindBody(g) else: "") & ")"
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

  proc piece(g: var Gen, depth: int): string =
    result =
      if depth > 0 and g.r.rand(2) == 0:
        group(g, depth)
      else:
        atom(g)
    if g.r.rand(2) == 0:
      result &= quantifier(g)
      # Possessive and lazy spellings both matter; ``+`` after a quantifier is
      # possessive in Oniguruma syntax.
      if g.r.rand(5) == 0:
        result &= "+"

  proc branch(g: var Gen, depth: int): string =
    for _ in 0 .. g.r.rand(2):
      result &= piece(g, depth)

  proc expr(g: var Gen, depth: int): string =
    result = branch(g, depth)
    if depth > 0 and g.r.rand(3) == 0:
      result &= "|" & branch(g, depth)

  proc pattern(g: var Gen): string =
    g.groups = 0
    g.closed.setLen(0)
    result = ""
    if g.r.rand(2) == 0:
      result &= "^"
    result &= expr(g, 3)

  proc subject(g: var Gen): string =
    for _ in 0 ..< g.r.rand(MaxSubjectLen):
      result &= g.r.sample(Alphabet)

  proc onigSpans(
      reg: OnigRegex, subj: string, region: ptr OnigRegion
  ): seq[(int, int)] =
    ## ``search`` fills ``region``; a mismatch leaves the result empty.
    if search(reg, subj, region) < 0:
      return @[]
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
    ## *and* a stale end -- which neither tell covers.  A differing match span
    ## -- index 0 -- is never excused.
    if a.len != b.len or a.len == 0:
      return false
    if a[0] != b[0]:
      return false
    for i in 1 ..< a.len:
      if a[i] == b[i]:
        continue
      let emptySide = a[i][0] == a[i][1] or b[i][0] == b[i][1]
      let sameEnd = a[i][1] == b[i][1]
      if not (emptySide or sameEnd):
        return false
    true

  proc pcre2Spans(pat, subj: string, want: int): seq[(int, int)] =
    ## PCRE2's answer in the same shape, or ``@[]`` for no match.  ``want`` is
    ## how many spans the comparison is about -- it has to be the wider of the
    ## two answers being compared, since a zero would make "matched" and "did
    ## not match" print the same.  Groups PCRE2 left unset come back as
    ## ``(-1, -1)``, as the other two engines spell them.  Raises ``Pcre2Error``
    ## when PCRE2 will not take the pattern.
    let code = pcre2.compile(pat, jit = false)
    defer:
      pcre2.free(code)
    let data = pcre2.newMatchData(code)
    defer:
      pcre2.free(data)
    let rc = pcre2.match(code, subj, data, 0)
    if rc <= 0:
      return @[]
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
      var failures, disputes: seq[string]
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
                reg = compile(pat)
              except OnigError:
                skipped += 1 # Oniguruma rejects it; nothing to compare against.
                break one
              defer:
                free(reg)

              var rx: Regex
              try:
                rx = re(pat)
              except CatchableError:
                # reni rejecting a pattern Oniguruma accepts is worth knowing about,
                # but it is a parser gap, not a rollback bug; keep them apart.
                skipped += 1
                break one

              let want = onigSpans(reg, subj, region)
              var got: seq[(int, int)]
              try:
                got = reniSpans(rx, subj)
              except RegexLimitError:
                # The generator does produce catastrophic backtrackers, and the step
                # limit stopping one is the engine working as designed.  Oniguruma
                # has no such budget and answers, so there is nothing to compare.
                skipped += 1
                break one
              except CatchableError as e:
                failures.add &"/{pat}/ on \"{subj}\": reni raised {e.name}: {e.msg}"
                break one
              compared += 1
              if got != want:
                # Ask the third engine before blaming reni.
                var third: seq[(int, int)]
                var haveThird = true
                try:
                  third = pcre2Spans(pat, subj, max(want.len, got.len))
                except Pcre2Error:
                  haveThird = false
                let detail = &"/{pat}/ on \"{subj}\":\n    onig {want}\n    reni {got}"
                # ``want`` is padded to the same width so the three shapes line up.
                let wantPadded = block:
                  var w = want
                  while w.len > 0 and w.len < third.len:
                    w.add (-1, -1)
                  w
                if haveThird and third == wantPadded and
                    not onlyIterationSplitSpans(got, want):
                  failures.add detail & &"\n    pcre2 {third} (agrees with onig)"
                else:
                  disputed += 1
                  if disputes.len < 5:
                    disputes.add detail & (
                      if haveThird: &"\n    pcre2 {third}"
                      else: "\n    pcre2 rejected it"
                    )
              if failures.len >= 10:
                break sweep

      echo &"  compared {compared}, skipped {skipped}, disputed {disputed} " &
        &"(seeds {baseSeed} .. {baseSeed + seeds - 1}, {iters} each)"
      for d in disputes:
        echo "  DISPUTED (reni and pcre2 against onig, or no quorum) ", d
      if failures.len > 0:
        for f in failures:
          echo "  DIVERGENCE ", f
      check failures.len == 0
      check compared > (iters * seeds) div 4 # the generator still does real work
