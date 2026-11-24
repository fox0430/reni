## ``\<`` and ``\>`` under ``rfWordBeginEnd``: Oniguruma's ``WORD_BEGIN``
## and ``WORD_END``.
##
## Its own module, out of ``engine``'s translation unit, as
## ``fold_unravel`` is: written into ``engine`` the same check moved the
## grammar workload +1.3% instructions, none of whose patterns holds these
## anchors, by gcc inlining less into ``runMachine`` (``pushChoice``,
## ``pushFrame``, ``bodyBounds``; 2026-11-20).

import std/unicode
import types, unicode_utils

proc wordEdgeAt*(
    s: openArray[char], pos, rangeEnd: int, begin, asciiOnly, wordBefore0: bool
): bool {.noinline.} =
  ## Whether ``\<`` (``begin``) or ``\>`` holds at ``pos`` in ``s``, the
  ## whole subject.  Each side is read as ``\b`` reads it, the real next
  ## character included.  ``\<`` first needs ``pos < rangeEnd``, the end an
  ## absent range or a look-behind window clips consumption to: Oniguruma's
  ## ``WORD_BEGIN`` opens with ``DATA_ENSURE_CHECK1`` (``s < right_range``)
  ## at every position.  ``WORD_END`` has no such check, so ``\>`` holds at
  ## the clip as anywhere.  ``asciiOnly`` is ``(?W)`` or ``(?P)``.
  ## ``wordBefore0`` is what precedes ``pos`` 0: false but in a line mode
  ## view a malformed byte cuts, where it is ``MatchContext.cutPrevWord``.
  if begin and pos >= rangeEnd:
    return false
  var before = wordBefore0 and not asciiOnly
  if pos > 0:
    let prev = s[pos - 1].uint8
    before =
      if prev < 0x80:
        asciiHas(int32(prev), acWord)
      else:
        var q: int
        isWordChar(Rune(prevCharAt(s, pos, q)), asciiOnly)
  var after = false
  if pos < s.len:
    let lead = s[pos].uint8
    if lead < 0x80:
      after = asciiHas(int32(lead), acWord)
    else:
      var code: int32
      var next: int
      after = decodeAt(s, pos, code, next) and isWordChar(Rune(code), asciiOnly)
  if begin:
    after and not before
  else:
    before and not after
