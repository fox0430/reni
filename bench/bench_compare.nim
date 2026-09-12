## Head-to-head benchmark: reni vs. the Oniguruma C library, with PCRE2
## (interpreted and JIT) as a calibration point.
##
## All engines run the same patterns over the same subject inside the same
## process, driven by identical findAll-style loops, so the numbers differ
## only by engine.  Match sequences are compared against reni's before
## timing; an engine that disagrees on a pattern is flagged, since its
## timing would not be measuring the same work.
##
## Run with:
##   nim c -d:release --opt:speed --mm:orc bench/bench_compare.nim
##   ./bench/bench_compare              # default 5_000 lines, 5 iterations
##   ./bench/bench_compare 20000 7      # lines, iterations
##   ./bench/bench_compare --md         # tables as Markdown

import std/[strformat, strutils]

import ../reni
import bench_common
import onig
import pcre2

type
  Engine = enum
    eReni = "reni"
    eOnig = "onig"
    ePcre2 = "pcre2"
    ePcre2Jit = "pcre2-jit"

  Span = tuple[a, b: int]

  Compiled = object
    reni: Regex
    onig: onig.OnigRegex
    pcre2: pcre2.Pcre2Code
    pcre2Jit: pcre2.Pcre2Code

  Scratch = ref object
    ctx: MatchContext
    region: ptr onig.OnigRegion
    data: pcre2.Pcre2MatchData

const TimeCol = 11

# ---------------------------------------------------------------- match loops
#
# One loop shape per engine, mirroring reni's `findAll`: search from `pos`,
# record the match, advance to the match end (one code point on a zero-width
# match), repeat.  reni's own loops run on `MatchScanner`, which is what
# `findAll` runs on; the foreign engines hand back an ovector, which reports
# what the attempt consumed, and `advanceOvector` below is the whole cursor
# rule such a match needs.  It is the deprecated `advanceAfterMatch` of the
# public API, kept here because here it is the right rule.  The `collect*` variants exist for the
# pre-timing agreement check; the `count*` variants are what gets timed.

proc advanceOvector(subject: string, mStart, mEnd: int): int {.inline.} =
  ## Next search position after a match that reported what it consumed.
  ## A zero-width match steps one code point, or ends the scan at the end.
  if mEnd == mStart:
    if mStart < subject.len:
      nextRunePos(subject, mStart)
    else:
      -1
  else:
    mEnd

proc collectReni(ctx: MatchContext, subject: string, regex: Regex): seq[Span] =
  var sc = initMatchScanner(subject)
  var m: Match
  while scanNext(sc, ctx, subject, regex, m):
    result.add (m.boundaries[0].a, m.boundaries[0].b)

proc collectOnig(
    reg: onig.OnigRegex, subject: string, region: ptr onig.OnigRegion
): seq[Span] =
  var pos = 0
  while pos <= subject.len:
    if onig.search(reg, subject, region, pos) < 0:
      break
    let mStart = region.beg[0].int
    let mEnd = region.ends[0].int
    result.add (mStart, mEnd)
    let nextPos = advanceOvector(subject, mStart, mEnd)
    if nextPos < 0:
      break
    pos = nextPos

proc collectPcre2(
    code: pcre2.Pcre2Code, subject: string, data: pcre2.Pcre2MatchData
): seq[Span] =
  var pos = 0
  while pos <= subject.len:
    if pcre2.match(code, subject, data, pos) <= 0:
      break
    let ov = pcre2.ovector(data)
    let mStart = ov[0].int
    let mEnd = ov[1].int
    result.add (mStart, mEnd)
    let nextPos = advanceOvector(subject, mStart, mEnd)
    if nextPos < 0:
      break
    pos = nextPos

proc countReni(ctx: MatchContext, subject: string, regex: Regex): int =
  var sc = initMatchScanner(subject)
  var m: Match
  while scanNext(sc, ctx, subject, regex, m):
    inc result

proc countOnig(reg: onig.OnigRegex, subject: string, region: ptr onig.OnigRegion): int =
  var pos = 0
  while pos <= subject.len:
    if onig.search(reg, subject, region, pos) < 0:
      break
    inc result
    let nextPos = advanceOvector(subject, region.beg[0].int, region.ends[0].int)
    if nextPos < 0:
      break
    pos = nextPos

proc countPcre2(
    code: pcre2.Pcre2Code, subject: string, data: pcre2.Pcre2MatchData
): int =
  var pos = 0
  while pos <= subject.len:
    if pcre2.match(code, subject, data, pos) <= 0:
      break
    inc result
    let nextPos =
      advanceOvector(subject, pcre2.ovector(data)[0].int, pcre2.ovector(data)[1].int)
    if nextPos < 0:
      break
    pos = nextPos

# -------------------------------------------------------------------- helpers

proc diffSummary(reference, other: seq[Span]): string =
  ## "", or a short description of the first divergence from `reference`.
  if reference == other:
    return ""
  for i in 0 ..< min(reference.len, other.len):
    if reference[i] != other[i]:
      return fmt"#{i} {reference[i].a}-{reference[i].b} vs {other[i].a}-{other[i].b}"
  fmt"count {reference.len} vs {other.len}"

proc engineColumns(width = TimeCol): seq[(string, int)] =
  for e in Engine:
    result.add ($e, width)

# ------------------------------------------------------------------ one item

type
  Status = enum
    stOk = "ok"
    stUnsupported = "n/a" ## the engine rejected the pattern
    stLimit = "limit" ## reni hit its step limit

  ItemResult = object
    bench: Bench
    time: array[Engine, int64]
    status: array[Engine, Status]
    matches: int
    agree: string ## "" when every available engine agrees, else the first divergence
    disagreeing: seq[string] ## engines whose match sequence differs
    comparable: bool ## every engine ran and agreed
    bytes: int

proc runItem(
    b: Bench, subject: string, scratch: Scratch, warmup, iters: int
): ItemResult =
  result.bench = b
  result.bytes = subject.len

  var c: Compiled
  var have: array[Engine, bool]
  try:
    c.reni = re(b.pattern)
    have[eReni] = true
  except CatchableError:
    result.status[eReni] = stUnsupported
  try:
    c.onig = onig.compile(b.pattern)
    have[eOnig] = true
  except onig.OnigError:
    result.status[eOnig] = stUnsupported
  try:
    c.pcre2 = pcre2.compile(b.pattern, jit = false)
    have[ePcre2] = true
    c.pcre2Jit = pcre2.compile(b.pattern, jit = true)
    have[ePcre2Jit] = true
  except pcre2.Pcre2Error:
    if not have[ePcre2]:
      result.status[ePcre2] = stUnsupported
    result.status[ePcre2Jit] = stUnsupported
  # `c.reni` is garbage-collected; the C engines need explicit frees.
  defer:
    if have[eOnig]:
      onig.free(c.onig)
    if have[ePcre2]:
      pcre2.free(c.pcre2)
    if have[ePcre2Jit]:
      pcre2.free(c.pcre2Jit)

  if have[ePcre2]:
    scratch.data = pcre2.newMatchData(c.pcre2)
  defer:
    if have[ePcre2]:
      pcre2.free(scratch.data)

  # Match sequences first: timing an engine that computes something else
  # would be meaningless.
  var spans: array[Engine, seq[Span]]
  if have[eReni]:
    try:
      spans[eReni] = collectReni(scratch.ctx, subject, c.reni)
    except RegexError:
      have[eReni] = false
      result.status[eReni] = stLimit
  if have[eOnig]:
    spans[eOnig] = collectOnig(c.onig, subject, scratch.region)
  if have[ePcre2]:
    spans[ePcre2] = collectPcre2(c.pcre2, subject, scratch.data)
  if have[ePcre2Jit]:
    spans[ePcre2Jit] = collectPcre2(c.pcre2Jit, subject, scratch.data)

  let reference =
    if have[eReni]:
      eReni
    elif have[eOnig]:
      eOnig
    else:
      ePcre2
  result.matches = spans[reference].len
  for e in Engine:
    if have[e] and e != reference and spans[e] != spans[reference]:
      result.disagreeing.add $e
      if result.agree.len == 0:
        result.agree = fmt"vs {reference}, " & diffSummary(spans[reference], spans[e])

  for e in Engine:
    if not have[e]:
      result.time[e] = -1
      continue
    result.time[e] =
      case e
      of eReni:
        measure(
          warmup,
          iters,
          proc(): int =
            countReni(scratch.ctx, subject, c.reni),
        ).best
      of eOnig:
        measure(
          warmup,
          iters,
          proc(): int =
            countOnig(c.onig, subject, scratch.region),
        ).best
      of ePcre2:
        measure(
          warmup,
          iters,
          proc(): int =
            countPcre2(c.pcre2, subject, scratch.data),
        ).best
      of ePcre2Jit:
        measure(
          warmup,
          iters,
          proc(): int =
            countPcre2(c.pcre2Jit, subject, scratch.data),
        ).best

  result.comparable = result.agree.len == 0
  for e in Engine:
    if not have[e]:
      result.comparable = false

proc cell(r: ItemResult, e: Engine): string =
  if r.time[e] >= 0:
    fmtMs(r.time[e])
  else:
    $r.status[e]

# ----------------------------------------------------------------- benchmarks

proc runAll(corpora: array[Corpus, string], warmup, iters: int): seq[ItemResult] =
  let scratch = Scratch(ctx: newMatchContext(8), region: onig.newRegion())
  defer:
    onig.free(scratch.region)
  for b in Benchmarks:
    result.add runItem(b, corpora[b.corpus], scratch, warmup, iters)

proc printSummary(results: seq[ItemResult], markdown: bool) =
  ## The headline: one row per engine over every comparable item.
  var
    total: array[Engine, int64]
    bytes = 0
    counted = 0
  for r in results:
    if not r.comparable:
      continue
    inc counted
    bytes += r.bytes
    for e in Engine:
      total[e] += r.time[e]
  if counted == 0:
    return

  var fastest = 0.0
  for e in Engine:
    fastest = max(fastest, 1.0 / total[e].float)

  echo ""
  echo fmt"## Summary ({counted} of {results.len} items comparable across all engines)"
  echo ""
  let table = initTableWriter(
    [("engine", 12), ("total", TimeCol), ("scan rate", 14), ("", 32)], markdown
  )
  for e in Engine:
    table.row(
      $e, fmtMs(total[e]), fmtMiBs(bytes, total[e]), bar(1.0 / total[e].float, fastest)
    )

proc printByCategory(results: seq[ItemResult], markdown: bool) =
  ## Where the time goes, per benchmark category.
  echo ""
  echo "## By category"
  echo ""
  var cols = @[("category", 14), ("items", 6)]
  cols.add engineColumns()
  let table = initTableWriter(cols, markdown)

  var seen: seq[string]
  for r in results:
    if r.bench.category notin seen:
      seen.add r.bench.category
  for category in seen:
    var
      total: array[Engine, int64]
      items = 0
      partial = false
    for r in results:
      if r.bench.category != category:
        continue
      inc items
      if not r.comparable:
        partial = true
        continue
      for e in Engine:
        total[e] += r.time[e]
    var cells = @[category, (if partial: $items & "*" else: $items)]
    for e in Engine:
      cells.add fmtMs(total[e])
    table.row(cells)
  echo ""
  echo "`*` — the category holds an item the engines disagree on; it is left " &
    "out of these totals."

proc printItems(results: seq[ItemResult], iters: int, markdown: bool) =
  echo ""
  echo fmt"## Per item (best of {iters})"
  echo ""
  var cols = @[("category", 14), ("item", 18), ("corpus", 7)]
  cols.add engineColumns()
  cols.add [("matches", 8), ("agree", 5)]
  let table = initTableWriter(cols, markdown)
  for r in results:
    var cells = @[r.bench.category, r.bench.label, $r.bench.corpus]
    for e in Engine:
      cells.add cell(r, e)
    cells.add $r.matches
    cells.add(
      if r.disagreeing.len == 0:
        "yes"
      else:
        "no (" & r.disagreeing.join(", ") & ")"
    )
    table.row(cells)

  for r in results:
    if r.disagreeing.len == 0:
      continue
    echo ""
    let engines = r.disagreeing.join(", ")
    echo fmt"`{r.bench.category}/{r.bench.label}`: {engines} disagree " &
      fmt"({r.agree}); the item is left out of the summary."

proc benchCompile(iters: int, markdown: bool) =
  ## Pattern compilation cost, per compile.
  echo ""
  echo fmt"## Compile, per item ({iters} compiles, time per compile)"
  echo ""
  var cols = @[("category", 14), ("item", 18)]
  cols.add engineColumns()
  let table = initTableWriter(cols, markdown)

  var total: array[Engine, int64]
  for b in Benchmarks:
    let pattern = b.pattern
    var best: array[Engine, int64]
    for e in Engine:
      best[e] = -1

    var reniBox = newSeq[Regex](iters)
    try:
      best[eReni] = measure(
        1,
        5,
        proc(): int =
          for i in 0 ..< iters:
            reniBox[i] = re(pattern)
          iters,
      ).best
    except CatchableError:
      discard

    var onigBox = newSeq[onig.OnigRegex](iters)
    try:
      best[eOnig] = measure(
        1,
        5,
        proc(): int =
          for i in 0 ..< iters:
            onigBox[i] = onig.compile(pattern)
          for i in 0 ..< iters:
            onig.free(onigBox[i])
          iters,
      ).best
    except onig.OnigError:
      discard

    var pcreBox = newSeq[pcre2.Pcre2Code](iters)
    for jit in [false, true]:
      let e = if jit: ePcre2Jit else: ePcre2
      try:
        best[e] = measure(
          1,
          5,
          proc(): int =
            for i in 0 ..< iters:
              pcreBox[i] = pcre2.compile(pattern, jit = jit)
            for i in 0 ..< iters:
              pcre2.free(pcreBox[i])
            iters,
        ).best
      except pcre2.Pcre2Error:
        discard

    var cells = @[b.category, b.label]
    for e in Engine:
      if best[e] >= 0:
        total[e] += best[e]
        cells.add fmtUs(best[e] div iters)
      else:
        cells.add $stUnsupported
    table.row(cells)

  var cells = @["TOTAL", ""]
  for e in Engine:
    cells.add fmtUs(total[e] div iters)
  table.row(cells)

proc printPatterns(markdown: bool) =
  ## The workload itself, so a reader can see what each item stands for.
  echo ""
  echo "## Patterns"
  echo ""
  let table = initTableWriter([("category", 14), ("item", 18), ("regex", 0)], markdown)
  for b in Benchmarks:
    table.row(b.category, b.label, "`" & b.pattern & "`")

proc main() =
  let (lineCount, iters, markdown) = parseArgs()
  let warmup = 2

  onig.initOniguruma()
  defer:
    onig.finalizeOniguruma()

  let corpora = subjects(lineCount)
  let jitState = if pcre2.jitAvailable(): "available" else: "unavailable"

  echo fmt"# reni vs Oniguruma {onig.onigVersionString()} vs PCRE2"
  echo ""
  echo fmt"{Benchmarks.len} benchmark items across " &
    "literals, character classes, alternation, quantifiers, anchors, captures, " &
    "lookaround, Unicode, no-match scans and backtracking. Each item finds " &
    fmt"every match in a ~{corpora[cCode].len div 1024} KiB subject: `code` is " &
    fmt"{lineCount} lines of synthetic Nim source, `text` is UTF-8 " &
    "Japanese/ASCII prose of the same size. Best of " & $iters & " runs."
  echo ""
  echo "Same subject, same match loop, same process. UTF-8 throughout: " &
    "`ONIG_SYNTAX_ONIGURUMA` for Oniguruma, " &
    "`PCRE2_UTF | PCRE2_UCP | PCRE2_MULTILINE` for PCRE2 " &
    fmt"(JIT {jitState}), so `\w`, `\d`, `\b` and `^` mean the same thing " &
    "everywhere. The `agree` column checks that: every engine must return the " &
    "identical match sequence, and only items where all four agree feed the " &
    "summary."
  echo ""
  echo environmentNote()

  let results = runAll(corpora, warmup, iters)
  printSummary(results, markdown)
  printByCategory(results, markdown)
  printItems(results, iters, markdown)
  benchCompile(200, markdown)
  printPatterns(markdown)

when isMainModule:
  main()
