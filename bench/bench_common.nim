## Shared workload and reporting helpers for the reni benchmarks.
##
## `Benchmarks` is the workload: one item per row, grouped into categories
## (literals, character classes, alternation, quantifiers, anchors, captures,
## lookaround, Unicode, no-match scans, backtracking), run against either an
## ASCII-heavy code corpus or a UTF-8 Japanese/ASCII text corpus of the same
## size.  Keeping it in one place means `bench_reni` (single engine) and
## `bench_compare` (reni vs. Oniguruma vs. PCRE2) measure the same thing.

import std/[algorithm, math, monotimes, os, strformat, strutils, times]

type
  Corpus* = enum ## Which subject a benchmark item runs against.
    cCode = "code" ## synthetic Nim source, ASCII-heavy
    cText = "text" ## mixed Japanese / ASCII prose, UTF-8 multibyte

  Bench* = tuple[category, label: string, corpus: Corpus, pattern: string]

const Benchmarks*: array[29, Bench] = [
  # Plain literals: what a prefilter / first-byte scan can skip over.
  ("literal", "common-word", cCode, "result"),
  ("literal", "rare-word", cCode, "0xDEADBEEF"),
  ("literal", "utf8", cText, "日本語"),
  ("literal", "case-insensitive", cCode, "(?i)RESULT"),
  # Character classes.
  ("class", "digits", cCode, "[0-9]+"),
  ("class", "word", cCode, "\\w+"),
  ("class", "negated", cCode, "[^ \\n]+"),
  ("class", "posix", cCode, "[[:alpha:]]+"),
  ("class", "unicode-property", cText, "\\p{L}+"),
  # Alternation width.
  ("alternation", "small", cCode, "\\b(proc|func|method|iterator)\\b"),
  (
    "alternation", "large", cCode,
    "\\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|float64|bool|char|string|seq|array|tuple|object|ref|ptr|var|const|let|proc|func|method|iterator|template|macro|type|enum|range|set|cstring|pointer|typed)\\b",
  ),
  # Quantifiers.
  ("quantifier", "greedy", cCode, "\".*\""),
  ("quantifier", "lazy", cCode, "\".*?\""),
  ("quantifier", "bounded", cCode, "\\w{4,8}"),
  ("quantifier", "possessive", cCode, "\\w++\\s"),
  # Anchors.
  ("anchor", "line-start", cCode, "^\\s*(proc|func|var|let|const)\\b"),
  ("anchor", "word-boundary", cCode, "\\bresult\\b"),
  # Capture groups.
  ("capture", "two-groups", cCode, "(\\w+)\\s*=\\s*(\\w+)"),
  ("capture", "named", cCode, "(?<lhs>\\w+)\\s*=\\s*(?<rhs>\\w+)"),
  ("capture", "backreference", cCode, "(\\w)\\1"),
  # Lookaround.
  ("lookaround", "lookahead", cCode, "\\w+(?=\\()"),
  ("lookaround", "lookbehind", cCode, "(?<=\\.)\\w+"),
  ("lookaround", "negative", cCode, "\\b(?!proc)\\w+\\b"),
  # Multibyte subject.
  ("unicode", "word", cText, "\\w+"),
  ("unicode", "script", cText, "\\p{Han}+"),
  # Nothing to find: pure scanning speed.
  ("no-match", "literal", cCode, "zzqqxx"),
  ("no-match", "class", cCode, "\\d{6,}"),
  # Backtracking-heavy.
  ("backtracking", "assignment-lhs", cCode, "[A-Za-z_][A-Za-z0-9_]*\\s*="),
  ("backtracking", "repeated-group", cCode, "(?:\\w+\\s+){3,}"),
]

const CodeLines: array[10, string] = [
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

const TextLines: array[8, string] = [
  "正規表現エンジンの性能を比較するためのサンプルテキストです。",
  "The quick brown fox jumps over the lazy dog 0123456789.",
  "日本語と English が混在した行、句読点や記号（、。「」）も含む。",
  "メールアドレス example@example.com と URL https://example.com を含む行。",
  "数値: 3.14159, 2.71828, 1.41421 と全角数字 １２３４５ の混在。",
  "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod.",
  "カタカナ・ひらがな・漢字が並ぶ行。単語境界の判定に効いてくる。",
  "result = calcTotal(items)  # 計算結果を代入する",
]

type Timing* = object
  best*: int64 ## fastest sample, in nanoseconds
  median*: int64 ## median sample, in nanoseconds
  matches*: int ## match count of the last run (sanity check)

proc buildCodeSubject*(lineCount: int): string =
  ## Deterministic ASCII-heavy subject: `lineCount` lines of Nim-flavored source.
  result = newStringOfCap(lineCount * 70)
  for i in 0 ..< lineCount:
    result.add CodeLines[i mod CodeLines.len]
    result.add '\n'

proc buildTextSubject*(targetBytes: int): string =
  ## Deterministic UTF-8 subject of roughly `targetBytes` bytes, so the two
  ## corpora are the same size and their timings stay comparable.
  result = newStringOfCap(targetBytes + 128)
  var i = 0
  while result.len < targetBytes:
    result.add TextLines[i mod TextLines.len]
    result.add '\n'
    inc i

proc subjects*(lineCount: int): array[Corpus, string] =
  ## Both corpora, sized to match.
  result[cCode] = buildCodeSubject(lineCount)
  result[cText] = buildTextSubject(result[cCode].len)

proc measure*(warmup, iters: int, run: proc(): int): Timing =
  ## Run `run` `warmup` + `iters` times and keep the best/median wall time.
  for _ in 0 ..< warmup:
    discard run()

  var samples = newSeq[int64](iters)
  for it in 0 ..< iters:
    let t0 = getMonoTime()
    result.matches = run()
    let t1 = getMonoTime()
    samples[it] = inNanoseconds(t1 - t0)
  samples.sort()

  result.best = samples[0]
  result.median = samples[samples.len div 2]

proc fmtMs*(ns: int64): string =
  fmt"{ns.float / 1_000_000.0:>9.3f} ms"

proc fmtUs*(ns: int64): string =
  fmt"{ns.float / 1_000.0:>8.2f} us"

proc fmtMiBs*(bytes: int, ns: int64): string =
  let mibs = bytes.float / (ns.float / 1_000_000_000.0) / (1024.0 * 1024.0)
  fmt"{mibs:>7.1f} MiB/s"

proc bar*(value, maxValue: float, width: int = 32): string =
  ## Proportional bar for `value` against `maxValue`, at least one block wide
  ## so a non-zero measurement never renders as nothing.
  if maxValue <= 0.0 or value <= 0.0:
    return ""
  "\u2588".repeat(max(1, int(round(value / maxValue * width.float))))

type TableWriter* = object
  ## Emits a table as aligned plain text or as GitHub-flavored Markdown.
  markdown: bool
  widths: seq[int]

proc initTableWriter*(cols: openArray[(string, int)], markdown: bool): TableWriter =
  ## Write the header row.  `cols` pairs each column title with the width
  ## used in plain-text mode (ignored for Markdown).
  result.markdown = markdown
  for (name, width) in cols:
    result.widths.add width
  if markdown:
    var head, sep = "|"
    for (name, _) in cols:
      head.add " " & name & " |"
      sep.add " --- |"
    echo head
    echo sep
  else:
    var line = "  "
    for (name, width) in cols:
      line.add name.alignLeft(width) & " "
    echo line

proc row*(w: TableWriter, cells: varargs[string]) =
  if w.markdown:
    var line = "|"
    for cell in cells:
      line.add " " & cell.strip().replace("|", "\\|") & " |"
    echo line
  else:
    var line = "  "
    for i, cell in cells:
      line.add cell.alignLeft(
        if i < w.widths.len:
          w.widths[i]
        else:
          0
      ) & " "
    echo line

proc cpuModel(): string =
  when defined(linux):
    try:
      for line in lines("/proc/cpuinfo"):
        if line.startsWith("model name"):
          return line.split(":", 1)[1].strip()
    except CatchableError:
      discard
  hostCPU

proc environmentNote*(): string =
  ## One line of machine / build / invocation context, so a captured run is
  ## self-describing.
  let build =
    when defined(danger):
      "danger build"
    elif defined(release):
      "release build"
    else:
      "debug build"
  let args = commandLineParams().join(" ")
  let date = now().format("yyyy-MM-dd")
  let invocation =
    getAppFilename().extractFilename() & (if args.len > 0: " " & args
    else: "")
  fmt"{cpuModel()}, {hostOS}/{hostCPU}. Nim {NimVersion}, {build}. " &
    fmt"Generated {date} by `{invocation}`."

proc parseArgs*(
    defaultLines = 5_000, defaultIters = 5
): tuple[lines, iters: int, markdown: bool] =
  ## `[lines] [iterations] [--md]`, in any order.
  result = (lines: defaultLines, iters: defaultIters, markdown: false)
  var positional: seq[string]
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg == "--md":
      result.markdown = true
    else:
      positional.add arg
  if positional.len >= 1:
    result.lines = parseInt(positional[0])
  if positional.len >= 2:
    result.iters = parseInt(positional[1])
