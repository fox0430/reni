## What one bind costs, i.e. what a pattern pays before its first position.
##
## The suite measures long scans through one context, where anything derived
## per tree is paid once and vanishes.  This probe measures the other end: a
## one-shot ``search`` over a short subject, which allocates a context, binds,
## matches and throws the context away.  Run it under callgrind against two
## builds to price a new bind-time pass.
##
##   nim c -d:release --opt:speed --mm:orc --debugger:native tools/probe_bind_cost.nim
##   valgrind --tool=callgrind ./tools/probe_bind_cost 2000
##
## The patterns are sized by node count, so the reading says whether the cost
## follows the tree or not.
import std/[os, strutils]

import ../reni

const Patterns = [
  r"\w+", r"^\s*(proc|func|var|let|const)\b",
  r"(\w+)\s*=\s*(\w+)|(\w+)\.(\w+)\(([^)]*)\)|#\s*(.*)$|""([^""]*)""",
]

proc main() =
  let rounds =
    if paramCount() >= 1:
      parseInt(paramStr(1))
    else:
      2000
  let subject = "  let total = calcTotal(items)  # sum"
  var found = 0
  for p in Patterns:
    let rx = re(p)
    for _ in 0 ..< rounds:
      # One-shot: a fresh context per call, so every call binds.
      if search(subject, rx).found:
        inc found
  echo "patterns ", Patterns.len, ", rounds ", rounds, ", found ", found

main()
