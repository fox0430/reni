## Micro benchmark for the reni regex engine.
##
## Mirrors the measurement methodology from RENI_BOTTLENECKS.md:
##   - 14 patterns × N lines of Nim-flavored synthetic input
##   - searchIntoCtx via reused MatchContext (findAll semantics)
##   - prints per-pattern wall time and lines/sec
##
## Run with:
##   nim c -d:release --opt:speed --mm:orc bench/bench_reni.nim
##   ./bench/bench_reni            # default 5_000 lines
##   ./bench/bench_reni 100000     # match the bottleneck doc's setup

import std/[algorithm, monotimes, os, strformat, strutils, times]

import ../reni

const Patterns: array[14, string] = [
  "\\b\\d+(['_]?[iIuU](8|16|32|64))?\\b",
  "\\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|float64|bool|char|string|seq|array|tuple|object|ref|ptr|var|const|let|proc|func|method|iterator|template|macro|type|enum|range|set|cstring|pointer|typed)\\b",
  "\\b(import|export|include|from|as|when|elif|else|case|of|if|while|for|in|notin|is|isnot|return|yield|break|continue|discard|raise|try|except|finally|defer|do|block|static|cast|new|sizeof|addr|and|or|xor|not|shl|shr|div|mod)\\b",
  "\\b[A-Za-z_][A-Za-z0-9_]*\\b",
  "\\b(if|elif|else|case|of|while|for|in|notin|is|isnot|return|yield|break|continue|discard|raise|try|except|finally|defer)\\b",
  "\"([^\"\\\\]|\\\\.)*\"", "#.*", "[A-Z][A-Za-z0-9_]*", "\\d+\\.\\d+",
  "[+\\-*/=<>!&|^~%]+", "\\(.*?\\)", "0[xX][0-9A-Fa-f]+", "[A-Za-z_][A-Za-z0-9_]*\\s*=",
  "\\s+",
]

const PatternLabels: array[14, string] = [
  "int-literal-suffix", "type-keywords", "control-keywords", "identifier",
  "if-elif-else-keywords", "double-quoted-string", "line-comment", "PascalCase",
  "float-literal", "operator-run", "paren-group", "hex-literal", "assignment-lhs",
  "whitespace-run",
]

const SampleLines: array[10, string] = [
  "  let x = foo(123_i32, \"hello\", 0xDEADBEEF) # initialize",
  "  for i in 0 ..< n: result.add Item(name: \"x\", count: i + 1)",
  "type Foo = ref object of RootObj  ## a comment about Foo",
  "proc bar*[T](xs: seq[T]; threshold: float = 1.5): bool =",
  "  if a == b and c != d or not flag: result = true",
  "var pos: int = 0; const tag: string = \"abc-123\"",
  "while i < len(s):  result &= chr(ord(s[i]) xor 0x20'u8); inc i",
  "  return Match(found: true, boundaries: @[span(0, 4), span(5, 11)])",
  "discard fmt\"{n:08X} {label:<12} {value:>6.2f}us\"",
  "import std/[monotimes, strformat, strutils, tables, sequtils]",
]

proc buildSubject(lineCount: int): string =
  ## Build a deterministic, reasonably-sized subject by cycling SampleLines.
  result = newStringOfCap(lineCount * 70)
  for i in 0 ..< lineCount:
    result.add SampleLines[i mod SampleLines.len]
    result.add '\n'

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
    let mEnd = m.boundaries[0].b
    if mEnd == pos:
      if pos >= subject.len:
        break
      inc pos
      while pos < subject.len and (subject[pos].uint8 and 0xC0'u8) == 0x80'u8:
        inc pos
    else:
      pos = mEnd

proc fmtMs(ns: int64): string =
  fmt"{ns.float / 1_000_000.0:>8.2f} ms"

proc fmtLps(lines: int, ns: int64): string =
  let lps = lines.float * 1_000_000_000.0 / ns.float
  if lps >= 1_000_000.0:
    fmt"{lps / 1_000_000.0:>5.2f}M lines/s"
  else:
    fmt"{lps / 1_000.0:>5.0f}K lines/s"

proc bench(lineCount: int, warmup, iters: int): void =
  let subject = buildSubject(lineCount)
  let ctx = newMatchContext(8)

  echo fmt"# reni bench: {lineCount} lines (~{subject.len div 1024} KiB), warmup={warmup}, iters={iters}"
  echo "  ",
    "pattern".alignLeft(28),
    " ",
    "best".alignLeft(12),
    " ",
    "median".alignLeft(12),
    " ",
    "throughput".alignLeft(20),
    " ",
    "matches"

  for pi in 0 ..< Patterns.len:
    let r = re(Patterns[pi])

    for _ in 0 ..< warmup:
      discard countMatches(ctx, subject, r)

    var samples = newSeq[int64](iters)
    var lastCount = 0
    for it in 0 ..< iters:
      let t0 = getMonoTime()
      lastCount = countMatches(ctx, subject, r)
      let t1 = getMonoTime()
      samples[it] = inNanoseconds(t1 - t0)
    samples.sort()

    let best = samples[0]
    let median = samples[samples.len div 2]
    echo "  ",
      PatternLabels[pi].alignLeft(28),
      " ",
      fmtMs(best).alignLeft(12),
      " ",
      fmtMs(median).alignLeft(12),
      " ",
      fmtLps(lineCount, best).alignLeft(20),
      " ",
      lastCount

when isMainModule:
  let lineCount =
    if paramCount() >= 1:
      parseInt(paramStr(1))
    else:
      5_000
  let iters =
    if paramCount() >= 2:
      parseInt(paramStr(2))
    else:
      5
  let warmup = 2
  bench(lineCount, warmup, iters)
