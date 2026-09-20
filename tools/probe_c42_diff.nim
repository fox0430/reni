## C42's differential: the sequence-run fast path against the general path.
##
## The claim the fast path makes is not "these patterns match" but "this
## enumerates the states the general path enumerates, in its order".  Only a
## run against the general path can check that, so this prints every match and
## every capture span for a fixed pattern set over an exhaustive subject set,
## and the two builds' outputs are compared byte for byte.
##
##   nim c -d:release --mm:orc -o:<path> tools/probe_c42_diff.nim
##
## Build it once here and once from a worktree of the parent commit.

import std/[strformat, strutils]

import ../reni

const Patterns = [
  # The benchmark's own shape, and its bounded and anchored relatives.
  r"(?:\w+\s+){3,}",
  r"(?:\w+\s+){1,3}",
  r"(?:\w+\s+){2,}x",
  r"(?:\w+\s+){2,}$",
  r"(?:\w+\s*){2,}",
  # Overlapping accept sets: a give-back in the left element can feed the
  # right one, which is the case an odometer gets wrong.
  r"(?:[ab]+[bc]+)+",
  r"(?:[ab]+[bc]+)+c",
  r"(?:[ab]+[bc]+){2,}",
  r"(?:[ab]+[bc]+[cd]+){2,}",
  r"[ab]+[bc]+",
  r"[ab]+[bc]+$",
  # Zero-minimum elements beside a consuming one.
  r"(?:[ab]*[bc]+){2,}",
  r"(?:[ab]+[bc]*){2,}c",
  # Bounded elements.
  r"(?:[ab]{1,3}[bc]{2,4}){2,}",
  r"(?:[ab]{2}[bc]{1,2})+",
  # A continuation that has to backtrack into the repeat.
  r"((?:[ab]+[bc]+){2,})c",
  r"(?:[ab]+[bc]+){2,}(?=cc)",
  r"(?:[ab]+[bc]+){2,}\1?",
  r"((?:[ab]+ ){1,})\1",
  # Flags moving under the repeat, which turns the fast path off.
  r"(?i:(?:[ab]+[bc]+){2,})",
  r"(?:(?i)[ab]+[bc]+){2,}",
  # Inside a lookaround, where the window clips consumption.
  r"(?<=(?:[ab]+[bc]+){1,3})x",
  r"(?=(?:[ab]+[bc]+){2,})[ab]",
  # Negated and Unicode-capable leaves: the region bail-out.
  r"(?:[^x]+[bc]+){2,}",
  r"(?:\w+\W+){2,}",
  r"(?:\S+\s+){2,}",
  r"(?:.+\s+){1,2}",
  # Possessive elements, which ``markPossessive`` makes common: the benchmark
  # pattern's own left element is one.
  r"(?:[ab]++[bc]+){2,}",
  r"(?:[ab]+[bc]++){2,}c",
  r"(?:[ab]++[bc]++){2,}",
  r"(?:[ab]++[bc]+){1,3}c",
  # A lazy element, which the shape refuses, beside one that qualifies.
  r"(?:[ab]+?[bc]+){2,}",
  # Three and four elements.
  r"(?:[ab]+[bc]+[ca]+[ab]+){1,2}",
  r"(?:a[bc]+b?){2,}",
  # Outer bounds that bite.
  r"(?:[ab]+[bc]+){2}",
  r"(?:[ab]+[bc]+){0,2}c",
  r"(?:[ab]+[bc]+){3,4}",
  # ``findLongest`` fails every attempt on purpose, so the walk has to offer
  # every state and not only the first that matches.
  r"(?L)(?:[ab]+[bc]+){2,}",
  r"(?L)(?:[ab]++[bc]+){1,3}c?",
  # A step limit that lands inside a run; the probe reports the raise.
  r"(?:[ab]+[bc]+){2,}z",
]

proc alphabetStrings(alphabet: string, maxLen: int): seq[string] =
  result = @[""]
  var frontier = @[""]
  for _ in 1 .. maxLen:
    var next: seq[string] = @[]
    for s in frontier:
      for c in alphabet:
        next.add(s & c)
    result.add(next)
    frontier = next

proc main() =
  var subjects = alphabetStrings("ab c", 6)
  # A few longer and non-ASCII ones, for the region bail-out and the tail.
  subjects.add(
    [
      "aabbcc aabbcc aabbcc ", "ab bc ab bc ab bc x", "aaabbbcccx",
      "\xc3\xa9ab bc ab bc ", "ab bc \xc3\xa9 ab bc ", "abc\xe3\x81\x82def ghi ",
      "word word word ", "  a b  c   d ",
    ]
  )
  # Longer subjects, where the walk goes deep enough to interleave give-backs
  # with iterations it adds again.  A local generator, so both builds draw the
  # same corpus whatever ``std/random`` does.
  var state = 0x2545F4914F6CDD1D'u64
  proc nextByte(alphabet: string): char =
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    alphabet[int((state shr 33) mod uint64(alphabet.len))]

  for alphabet in ["abc ", "ab c\n", "aw1 \xc3\xa9"]:
    for n in 0 ..< 800:
      var s = ""
      for _ in 0 .. (n mod 34) + 6:
        s.add nextByte(alphabet)
      subjects.add s

  for pattern in Patterns:
    var rx: Regex
    try:
      rx = re(pattern)
    except CatchableError as e:
      echo &"{pattern}\tCOMPILE ERROR {e.msg}"
      continue
    for subj in subjects:
      var line = ""
      # A budget small enough to land inside a run on the longer subjects,
      # and large enough to leave the short ones alone: the counts a scan
      # charges must not move either.
      let limit = if subj.len > 12: 200 else: DefaultStepLimit
      try:
        for m in findAll(subj, rx, stepLimit = limit):
          let s0 = m.matchSpan
          line.add &"[{s0.a},{s0.b}]"
          for gi in 1 .. m.groupCount:
            let b = m.captureSpan(gi)
            line.add(
              if b.a < 0:
                "(-)"
              else:
                &"({b.a},{b.b})"
            )
      except CatchableError as e:
        line = "ERROR " & e.msg
      echo &"{pattern}\t{subj.escape}\t{line}"

main()
