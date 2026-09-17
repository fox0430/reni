## Match-sequence dump for the shapes the leaf-run scan admits. Diff two
## trees: a run that takes a byte the per-repetition loop would have refused,
## or stops short of one it would have taken, shows up as a different match
## count or digest.

import std/strformat

import ../reni
import ../bench/bench_common

const Patterns = [
  # Possessive over a byte-set leaf: the pure branch the run lands in first.
  r"\w++\s",
  r"\w++",
  r"\d++",
  r"\s++",
  r"\W++",
  r"\D++",
  r"\S++",
  r"\h++",
  r"[a-z]++",
  r"[^a-z]++",
  r"[^ \n]++",
  r"[0-9A-Fa-f]++",
  r"[\w.]++",
  # Bounded, so the run has to stop at ``qmax`` and not at the byte set.
  r"\w{4,8}+",
  r"\w{1,3}+",
  r"\w{3,}+",
  r"[^ \n]{2,4}+",
  r"\w{8}+",
  # ``.``, whose byte set the run reads off ``rfMultiLine``: the newline stays
  # out of one reading and in the other.
  r".++",
  r"(?m).++",
  r".{2,4}+",
  "\".*\"",
  "\"(?m).*\"",
  r".+\n",
  r"(?<=.++)\d",
  r"\O++",
  r"\N++",
  # Kinds the run must refuse: ``\X`` and ``\R`` do not take one byte per
  # repetition, and neither does ``.`` once a grapheme mode is on.
  r"\X++",
  r"\R++",
  r"(?y{g}).++",
  r"(?y{w}).++",
  r"(?y{g})\X++",
  # Folding, which takes the bitmap gate away.
  r"(?i)[a-z]++",
  r"(?i)\w++",
  r"(?i)[\x{00DF}s]++",
  # ASCII-restriction flags, which must not move an answer below U+0080.
  r"(?W)\w++",
  r"(?D)\d++",
  r"(?S)\s++",
  r"(?P)[[:alpha:]]++",
  # Classes whose bitmap comes off the shape reader rather than the atoms.
  r"[\p{Han}a-z]++",
  r"[^\p{Han}]++",
  r"\p{L}++",
  r"\P{L}++",
  r"[a-\x{FF}]++",
  r"[^a-\x{FF}]++",
  r"[\x{7F}-\x{80}]++",
  # The greedy forms the possessification passes rewrite into the above.
  r"\w+\s",
  r"[^ \n]+",
  r"\w+",
  r"\d+=",
  r"[A-Za-z_][A-Za-z0-9_]*\s*=",
  # A clipped consumption window, and a run inside a re-entered matcher.
  r"(?<=[a-z]++)\d",
  r"(?<=\w)\w++",
  r"(?=\w++)\w+\(",
  r"(?>\w++)\s",
  # Captures around the run, so a rollback has something to give back.
  r"(\w++)\s",
  r"(\w)\1",
  r"(?:\w+\s+){3,}",
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
      var limit = ""
      try:
        while scanNext(sc, ctx, subject, regex, m):
          inc n
          for sp in m.boundaries:
            digest = digest * 31 + sp.a * 7 + sp.b
          digest = digest and 0x3FFFFFFF
      except CatchableError as e:
        # A limit is an answer the run can move: report it, do not end the
        # sweep.
        limit = " LIMIT " & e.msg
      echo fmt"{pat} [{corpus}] {n} {digest}{limit}"

main()
