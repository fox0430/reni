## C40 equivalence probe: the ASCII-skipping ``advanceChainTo`` against the
## byte-at-a-time chain walk it replaces.
##
## The skip is an equivalence, not a heuristic, so this brute-forces every
## ``(start, target)`` pair of subjects built from every lead-byte class,
## malformed ones included: lone continuations, overlongs, and sequences
## truncated by the end of the subject.  It drives the engine's own
## ``advanceChainTo``, not a copy, so a later change to the skip is what the
## sweep measures.
##
##   nim c -r -d:release tools/probe_c40_chain.nim
import std/[random, strutils]

import ../reni/engine

proc oldChain(s: string, start, target: int): int =
  result = start
  while result < target and result < s.len:
    result = nextScanPos(s, result)

var r = initRand(20260920)
var bad = 0
var checked = 0

proc check(s: string) =
  for start in 0 .. s.len:
    for target in -2 .. s.len + 2:
      let a = oldChain(s, start, target)
      let b = advanceChainTo(s, start, target, false)
      inc checked
      if a != b:
        inc bad
        if bad <= 10:
          echo "MISMATCH s=",
            s.toHex, " start=", start, " target=", target, " old=", a, " new=", b

# Hand-written shapes the entry names.
check ""
check "abcdefghijklmnopqrstuvwxyz0123456789"
check "abc\xC3\xA9def\n"
check "aaaaaaaaaaaa\xE3\x81\x82\naaaaaaaaaaaaaa"
check "abcdefghij\xF0\x9F\x98\x80\n"
check "abcdefgh\xF0\x9F\n" # truncated 4-byte before a newline
check "\xC0\x80abcdefghijkl" # overlong
check "abc\xF4\x8F\xBF\xBFxyz"
check "\x80\x80\x80abcdefghijklmno" # lone continuations

# Random subjects over a byte alphabet that mixes ASCII with every lead class.
const alpha = [
  "a", "\n", " ", "0", "\xC3\xA9", "\xE3\x81\x82", "\xF0\x9F\x98\x80", "\xC0", "\x80",
  "\xF4", "\xE0\xA0", "\xFF",
]
for i in 1 .. 4000:
  var s = ""
  let n = r.rand(1 .. 9)
  for _ in 1 .. n:
    s.add alpha[r.rand(alpha.high)]
  check s

echo "checked ", checked, " (start, target) pairs; mismatches: ", bad
if bad > 0:
  quit 1
