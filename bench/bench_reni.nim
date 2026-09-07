## Single-engine benchmark for reni.
##
## Runs the shared benchmark items from `bench_common` and reports reni's own
## numbers (best, median, throughput) without linking any other engine — use
## `bench_compare` for the head-to-head against Oniguruma and PCRE2.
##
## Run with:
##   nim c -d:release --opt:speed --mm:orc bench/bench_reni.nim
##   ./bench/bench_reni            # default 5_000 lines
##   ./bench/bench_reni 100000     # larger subject
##   ./bench/bench_reni --md       # table as Markdown

import std/strformat

import ../reni
import bench_common

proc countMatches(ctx: MatchContext, subject: string, regex: Regex): int =
  ## Reproduce findAll semantics directly on top of searchIntoCtx so the
  ## benchmark stresses the matcher, not the iterator wrapper.
  var pos = 0
  var m: Match
  while pos <= subject.len:
    discard searchIntoCtx(ctx, subject, regex, m, start = pos)
    if not m.found:
      break
    inc result
    let nextPos = advanceAfterMatch(subject, m.boundaries[0])
    if nextPos < 0:
      break
    pos = nextPos

proc bench(lineCount: int, warmup, iters: int, markdown: bool) =
  let corpora = subjects(lineCount)
  let ctx = newMatchContext(8)

  echo fmt"# reni bench: {Benchmarks.len} items, " &
    fmt"~{corpora[cCode].len div 1024} KiB subjects " &
    fmt"(`code` = {lineCount} lines of Nim source, `text` = UTF-8 prose), " &
    fmt"warmup={warmup}, best of {iters}"
  echo ""
  echo environmentNote()
  echo ""

  let table = initTableWriter(
    [
      ("category", 14),
      ("item", 18),
      ("corpus", 7),
      ("best", 12),
      ("median", 12),
      ("throughput", 14),
      ("matches", 9),
    ],
    markdown,
  )

  for b in Benchmarks:
    let subject = corpora[b.corpus]
    var regex: Regex
    try:
      regex = re(b.pattern)
    except CatchableError as e:
      table.row(b.category, b.label, $b.corpus, "error: " & e.msg)
      continue

    var timing: Timing
    try:
      timing = measure(
        warmup,
        iters,
        proc(): int =
          countMatches(ctx, subject, regex),
      )
    except RegexError:
      table.row(b.category, b.label, $b.corpus, "limit")
      continue

    table.row(
      b.category,
      b.label,
      $b.corpus,
      fmtMs(timing.best),
      fmtMs(timing.median),
      fmtMiBs(subject.len, timing.best),
      $timing.matches,
    )

proc main() =
  let (lineCount, iters, markdown) = parseArgs()
  bench(lineCount, warmup = 2, iters = iters, markdown = markdown)

when isMainModule:
  main()
