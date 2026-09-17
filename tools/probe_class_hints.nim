## Match-sequence dump for the class shapes whose first-byte hint comes out
## of ``asciiSet``.  Diff two trees: a hint that is not a superset of the
## truth shows up as a missing match, not as a crash.

import std/strformat

import ../reni
import ../bench/bench_common

# The last rows are a range written across the ASCII boundary next to an atom
# the shape reader gives up on.  The corpora are well-formed UTF-8, so only
# ``test_engine_internals``'s byte sweep exercises the stray-byte half; these
# rows guard the ASCII half and the shape.
const Patterns = [
  r"\p{Han}+", r"\p{L}+", r"\P{L}+", r"\p{Latin}+", r"\p{Nd}+", r"\P{Nd}+",
  r"[\p{Han}a-z]+", r"[^\p{Han}]+", r"[^\p{L}]+", r"[\p{L}\d_]+", r"(?i)\p{L}+",
  r"(?i)[\p{Han}a-z]+", r"(?i)[^\p{L}]+", r"[[a-c][x-z]]+", r"[^[a-c][x-z]]+",
  r"[a-z&&[^aeiou]]+", r"[^a-z&&[^aeiou]]+", r"[\p{Alpha}]+", r"[^\p{Alpha}]+",
  r"(?W)[\p{Alpha}]+", r"(?W)\w+", r"(?P)[[:alpha:]]+", r"[\p{Han}\p{Hiragana}]+",
  r"\p{Han}\p{Hiragana}", r"[\x{4E00}-\x{9FFF}&&\p{Han}]+", r"[^\p{Han}&&\p{L}]+",
  r"\p{Han}?x", r"(\p{L})\1", r"^\p{L}+", r"\b\p{L}", r"[a-\x{FF}\p{Han}]+",
  r"[^a-\x{FF}\p{Han}]+", r"[\p{Han}a-\x{FF}]+", r"[a-\x{10FFFF}\p{Han}]+",
  r"[\x{7F}-\x{80}\p{Nd}]+",
]

proc main() =
  let corpora = subjects(400)
  let ctx = newMatchContext(8)
  for pat in Patterns:
    for corpus in [cCode, cText]:
      let subject = corpora[corpus]
      var regex: Regex
      try:
        regex = re(pat)
      except CatchableError as e:
        echo fmt"{pat} [{corpus}] ERROR {e.msg}"
        continue
      var sc = initMatchScanner(subject)
      var m: Match
      var n = 0
      var digest = 0
      while scanNext(sc, ctx, subject, regex, m):
        inc n
        for sp in m.boundaries:
          digest = digest * 31 + sp.a * 7 + sp.b
        digest = digest and 0x3FFFFFFF
      echo fmt"{pat} [{corpus}] {n} {digest}"

main()
