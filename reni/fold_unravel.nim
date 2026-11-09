## How Oniguruma unravels a ``(?i)`` string outside a look-behind
## (``unravel_case_fold_string``), for the matcher: the string is cut left to
## right into windows of three or two characters whose simple folds spell a
## multi-character fold (``ffi``, ``ss``), the longer first, and single
## characters.  A window, and a fold source on its own (``ß``), becomes a
## choice of plain strings, so only canonical UTF-8 matches it; any other
## character becomes a class of its case variants, which reads the subject
## leniently (``\xE0\x85\xBF`` is ``ſ``).
##
## Its own module, out of ``engine``'s translation unit: the matcher reaches
## it only on a subject the ASCII compare hands back, and code added to
## ``engine`` moves gcc's inlining in ``runMachine`` (``pushChoice``).
##
## Every proc reads a subject view that ends where the matcher may consume.

import std/unicode
import types, unicode_utils

proc spelledAs(s: openArray[char], p, next: int, code: int32): bool {.noinline.} =
  ## Whether the bytes of ``s`` from ``p`` to ``next`` are ``code``'s own
  ## UTF-8 encoding: no overlong form, and no stray byte the lenient decode
  ## read past (``\xC5?`` is no ``ſ`` here).  [engine.matchEncodedBytes]
  ## asks the same of a case-sensitive literal, over the unchecked subject.
  var buf: array[4, char]
  let n = utf8Encode(code, buf)
  if next - p != n:
    return false
  for k in 0 ..< n:
    if s[p + k] != buf[k]:
      return false
  true

proc foldSourceSpelled(
    s: openArray[char], target: Rune, p, next: int, code: int32, flags: RegexFlags
): bool =
  ## Whether the character ``code`` at ``p`` matches fold source ``target``
  ## (``ß``) as one character.  Oniguruma's branches for it are ``target``
  ## and every character sharing its full fold (``ẞ``), each spelled as its
  ## own bytes.
  if not spelledAs(s, p, next, code):
    return false
  let r = Rune(code)
  if r == target or caseInsensitiveMatch(r, target, flags):
    return true
  if not hasMultiCharFold(r):
    return false
  let a = getMultiCharFold(r)
  let b = getMultiCharFold(target)
  if a.len != b.len:
    return false
  for k in 0 ..< a.len:
    if a.runes[k] != b.runes[k]:
      return false
  true

proc literalBehind(node: Node): bool {.inline.} =
  if node.kind == nkLiteral: node.literalBehind else: node.escapedBehind

proc plainSpelled*(
    s: openArray[char],
    node: Node,
    target: Rune,
    p, next: int,
    code: int32,
    flags: RegexFlags,
): bool {.noinline.} =
  ## Whether the plain way of ``(?i)`` literal ``node``, rune ``target``,
  ## which matched ``code`` at ``p``, holds: outside a look-behind and under
  ## flags that fold above U+007F a fold source is a choice of plain strings
  ## ([foldSourceSpelled]), anything else a class.
  literalBehind(node) or not foldsAboveAscii(flags) or not hasMultiCharFold(target) or
    foldSourceSpelled(s, target, p, next, code, flags)

proc foldRunEnd(
    s: openArray[char], fold: RuneBuf, start: int, flags: RegexFlags, spelled: bool
): int =
  ## End of ``fold``'s characters matched one by one from ``start``, or -1;
  ## with ``spelled``, each only as its own bytes ([spelledAs]).
  var p = start
  for i in 0 ..< fold.len:
    if p >= s.len:
      return -1
    var sc: int32
    var sn: int
    if not decodeAt(s, p, sc, sn) or not codeIsClassifiable(sc, sn - p) or
        not caseInsensitiveMatch(Rune(sc), fold.runes[i], flags):
      return -1
    if spelled and sn - p > 1 and not spelledAs(s, p, sn, sc):
      return -1
    p = sn
  p

proc literalFoldEnd*(
    s: openArray[char], node: Node, target: Rune, start: int, flags: RegexFlags
): int {.noinline.} =
  ## End of ``(?i)`` literal ``node``'s second way, ``target``'s
  ## multi-character fold matched one character at a time from ``start``,
  ## or -1.  Outside a look-behind each character only as its own bytes.
  if not foldsAboveAscii(flags):
    return -1
  let fold = getMultiCharFold(target)
  if fold.len == 0:
    return -1
  foldRunEnd(s, fold, start, flags, not literalBehind(node))

proc foldedCode(r: Rune): int32 {.inline.} =
  ## ``simpleFold(r)``, without the table search for an ASCII ``r``.
  let cp = int32(r)
  if cp < 0x80:
    if cp >= ord('A') and cp <= ord('Z'):
      cp + 32
    else:
      cp
  else:
    int32(simpleFold(r))

proc foldWindowLen(runes: openArray[Rune], i: int): int =
  ## How many characters from ``i`` make one window: 3 or 2 where their
  ## simple folds spell a multi-character fold, the longer first, else 1.
  ## Windows are cut left to right, so ``sss`` is ``ss`` then ``s``.
  if i + 1 >= runes.len:
    return 1
  let c0 = foldedCode(runes[i])
  if not canStartFoldExpansion(Rune(c0)):
    return 1
  let c1 = foldedCode(runes[i + 1])
  result = 1
  for f in MultiCharFolds:
    if f.expansion[0] == c0 and f.expansion[1] == c1:
      if f.len == 2:
        result = 2
      elif i + 2 < runes.len and foldedCode(runes[i + 2]) == f.expansion[2]:
        return 3

proc foldWindowEnd(
    s: openArray[char], runes: openArray[Rune], i, w, start: int, flags: RegexFlags
): int =
  ## End of window ``runes[i ..< i + w]`` matched at ``start``, or -1: one
  ## character whose full fold the window's folds spell (``ß`` for ``ss``),
  ## or ``w`` characters each folding with the pattern's (``sſ``), each
  ## spelled as its own bytes.
  var code: int32
  var next: int
  if not decodeAt(s, start, code, next) or not spelledAs(s, start, next, code):
    return -1
  let r = Rune(code)
  if hasMultiCharFold(r):
    let fold = getMultiCharFold(r)
    if fold.len != w:
      return -1
    for k in 0 ..< w:
      if fold.runes[k] != simpleFold(runes[i + k]):
        return -1
    return next
  var p = start
  for k in 0 ..< w:
    if k > 0:
      if p >= s.len or not decodeAt(s, p, code, next) or not spelledAs(s, p, next, code):
        return -1
    if not caseInsensitiveMatch(Rune(code), runes[i + k], flags):
      return -1
    p = next
  p

proc foldedRunEnd*(
    s: openArray[char], start: int, runes: openArray[Rune], flags: RegexFlags
): int {.noinline.} =
  ## End of the ``(?i)`` string ``runes`` matched at ``start``, or -1, as
  ## Oniguruma unravels it outside a look-behind: a window, a fold source
  ## (``ß``: one character, or its fold's characters), or any other
  ## character as a class holding its case variants.
  var p = start
  var i = 0
  while i < runes.len:
    if p >= s.len:
      return -1
    let w = foldWindowLen(runes, i)
    if w > 1:
      p = foldWindowEnd(s, runes, i, w, p, flags)
      if p < 0:
        return -1
      i += w
      continue
    let target = runes[i]
    var code: int32
    var next: int
    if not decodeAt(s, p, code, next):
      return -1
    if hasMultiCharFold(target):
      if foldSourceSpelled(s, target, p, next, code, flags):
        p = next
      else:
        p = foldRunEnd(s, getMultiCharFold(target), p, flags, true)
        if p < 0:
          return -1
    else:
      let r = Rune(code)
      if not codeIsClassifiable(code, next - p) or
          not (r == target or caseInsensitiveMatch(r, target, flags)):
        return -1
      p = next
    inc i
  p
