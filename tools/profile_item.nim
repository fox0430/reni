## One benchmark item, one pass, so callgrind's self cost is the library's
## and not ``bench_compare``'s.
##
##   nim c -d:release --opt:speed --mm:orc --debugger:native tools/profile_item.nim
##   valgrind --tool=callgrind ./tools/profile_item negated
##
## Never with ``-d:nimNoLentIterators`` (OPTIMIZATION_NEXT.md §4, trap 4): it
## charges the harness's own copies to the library.

import std/[os, strutils]

import ../reni
import ../bench/bench_common

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    quit("usage: profile_item <item-label> [lines] [passes]")
  let label = args[0]
  let lines =
    if args.len > 1:
      parseInt(args[1])
    else:
      5000
  let passes =
    if args.len > 2:
      parseInt(args[2])
    else:
      1

  var item: Bench
  var found = false
  for b in Benchmarks:
    if b.label == label:
      item = b
      found = true
      break
  if not found:
    quit("no benchmark item labelled " & label)

  let corpora = subjects(lines)
  let subject = corpora[item.corpus]
  let regex = re(item.pattern)
  let ctx = newMatchContext(8)

  var total = 0
  for _ in 0 ..< passes:
    var sc = initMatchScanner(subject)
    var m: Match
    while scanNext(sc, ctx, subject, regex, m):
      inc total
  echo item.category,
    "/", item.label, " ", subject.len, " bytes, ", total, " matches over ", passes,
    " pass(es)"

main()
