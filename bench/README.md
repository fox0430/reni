# Benchmarks

Two benchmarks share one workload (`bench_common.nim`): 29 items grouped into
ten categories — literals, character classes, alternation, quantifiers, anchors,
captures, lookaround, Unicode, no-match scans and backtracking — each run over
one of two same-sized subjects:

| corpus | content |
| --- | --- |
| `code` | synthetic Nim source, ASCII-heavy, built by cycling 10 sample lines |
| `text` | mixed Japanese / ASCII prose, UTF-8 multibyte |

| File | What it measures |
| --- | --- |
| `bench_reni.nim` | reni alone: per-item wall time and throughput |
| `bench_compare.nim` | reni vs. Oniguruma vs. PCRE2 (interpreted and JIT), in the same process |
| `bench_common.nim` | shared patterns, subject builder, timing and formatting |
| `onig.nim` | minimal FFI bindings to libonig (benchmark-only) |
| `pcre2.nim` | minimal FFI bindings to libpcre2-8 (benchmark-only) |
| `RESULTS.md` | a captured `bench_compare` run |

## Requirements

`bench_compare` links against Oniguruma and PCRE2. Install both development
packages (`oniguruma` / `libonig-dev` and `pcre2` / `libpcre2-dev`) so that
`pkg-config --libs oniguruma` / `pkg-config --libs libpcre2-8` and their headers
resolve; the build falls back to `-lonig` / `-lpcre2-8` when `pkg-config` has no
entry.

PCRE2 is not the subject of the comparison — it is a calibration point. Reading
reni against Oniguruma alone cannot tell a fast reference from a slow one, so
the table also carries PCRE2's interpreter (an engine of the same class as
Oniguruma) and its JIT (a different class entirely).

## Running

```sh
nim c -d:release --opt:speed --mm:orc bench/bench_reni.nim
./bench/bench_reni [lines] [iterations] [--md]      # default: 5000 lines, 5 iterations

nim c -d:release --opt:speed --mm:orc bench/bench_compare.nim
./bench/bench_compare [lines] [iterations] [--md]   # default: 5000 lines, 5 iterations
```

`--md` prints the tables as Markdown instead of aligned text. Every run starts
with the engine versions, the machine, the build and the invocation, so a
captured run stays self-describing:

```sh
./bench/bench_compare 5000 7 --md > bench/RESULTS.md
```

## Methodology

- Every engine is driven by the *same* `findAll` loop: search from `pos`, record
  the match, advance to the match end (one code point on a zero-width match),
  repeat. reni uses `searchIntoCtx` with a reused `MatchContext`; Oniguruma uses
  `onig_search` with a reused `OnigRegion`; PCRE2 uses `pcre2_match` with a
  reused match data block.
- Patterns are compiled as UTF-8: `ONIG_SYNTAX_ONIGURUMA` for Oniguruma,
  `PCRE2_UTF | PCRE2_UCP | PCRE2_MULTILINE` for PCRE2 so that `\w`, `\d`, `\b`
  and `^` carry the same semantics in all three engines.
- Before timing, the full match sequence of every engine is collected and
  compared span by span against reni's. The `agree` column reports the result and
  the first divergence is printed below the table — an item the engines disagree
  on is not a meaningful timing comparison, so it is excluded from the summary
  and its category is marked `*`.
- An engine that rejects a pattern outright shows `n/a`; reni hitting its step
  limit shows `limit`. Neither stops the rest of the run.
- Each pattern is warmed up, then timed over N iterations; the table reports the
  best sample (least noise), and `bench_reni` also reports the median.
- Tables carry measured times only. Ratios are left to the reader: which
  baseline is meaningful depends on the question being asked, and the totals
  are dominated by the slowest pattern.

## Reading a run

`bench_compare` prints, in this order:

1. **What was measured** — workload, engine configuration, machine, invocation.
2. **Summary** — one row per engine: total search time, scan rate in MiB/s
   (higher is better), and a bar proportional to that rate. This is the part to
   quote; everything below it is evidence.
3. **By category** — where the time goes, so a weak spot is visible without
   reading 29 rows.
4. **Per item** — the individual measurements behind the two tables above.
5. **Compile, per item** — pattern compilation cost (`re` vs. `onig_new` vs.
   `pcre2_compile`, with and without a JIT pass).
6. **Patterns** — the regex behind each item, so the workload is inspectable.
