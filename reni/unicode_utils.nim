## Unicode character classification for regex matching.

import std/[unicode, strutils]

import
  pkg/unicodedb/[properties, casing, scripts, scripts_data, blocks_data, segmentation]

import types

type
  MultiCharFold* = object
    ## These are characters that fold to multiple characters under case-insensitive matching.
    ## Each entry: (source rune, expansion as seq of runes)
    source*: Rune
    expansion*: seq[Rune]

  RuneBuf* = object
    runes*: array[3, Rune]
    len*: int

  GcbProp* = enum
    ## Grapheme Cluster Break (GCB) property (Unicode 15.1, UAX #29)
    gcbOther
    gcbCR
    gcbLF
    gcbControl
    gcbExtend
    gcbZWJ
    gcbRegionalIndicator
    gcbPrepend
    gcbSpacingMark
    gcbL # Hangul Leading Jamo
    gcbV # Hangul Vowel Jamo
    gcbT # Hangul Trailing Jamo
    gcbLV # Hangul LV Syllable
    gcbLVT # Hangul LVT Syllable

const
  EmojiRanges*: array[151, (int32, int32)] = [
    (0x0023'i32, 0x0023'i32),
    (0x002A'i32, 0x002A'i32),
    (0x0030'i32, 0x0039'i32),
    (0x00A9'i32, 0x00A9'i32),
    (0x00AE'i32, 0x00AE'i32),
    (0x203C'i32, 0x203C'i32),
    (0x2049'i32, 0x2049'i32),
    (0x2122'i32, 0x2122'i32),
    (0x2139'i32, 0x2139'i32),
    (0x2194'i32, 0x2199'i32),
    (0x21A9'i32, 0x21AA'i32),
    (0x231A'i32, 0x231B'i32),
    (0x2328'i32, 0x2328'i32),
    (0x23CF'i32, 0x23CF'i32),
    (0x23E9'i32, 0x23F3'i32),
    (0x23F8'i32, 0x23FA'i32),
    (0x24C2'i32, 0x24C2'i32),
    (0x25AA'i32, 0x25AB'i32),
    (0x25B6'i32, 0x25B6'i32),
    (0x25C0'i32, 0x25C0'i32),
    (0x25FB'i32, 0x25FE'i32),
    (0x2600'i32, 0x2604'i32),
    (0x260E'i32, 0x260E'i32),
    (0x2611'i32, 0x2611'i32),
    (0x2614'i32, 0x2615'i32),
    (0x2618'i32, 0x2618'i32),
    (0x261D'i32, 0x261D'i32),
    (0x2620'i32, 0x2620'i32),
    (0x2622'i32, 0x2623'i32),
    (0x2626'i32, 0x2626'i32),
    (0x262A'i32, 0x262A'i32),
    (0x262E'i32, 0x262F'i32),
    (0x2638'i32, 0x263A'i32),
    (0x2640'i32, 0x2640'i32),
    (0x2642'i32, 0x2642'i32),
    (0x2648'i32, 0x2653'i32),
    (0x265F'i32, 0x2660'i32),
    (0x2663'i32, 0x2663'i32),
    (0x2665'i32, 0x2666'i32),
    (0x2668'i32, 0x2668'i32),
    (0x267B'i32, 0x267B'i32),
    (0x267E'i32, 0x267F'i32),
    (0x2692'i32, 0x2697'i32),
    (0x2699'i32, 0x2699'i32),
    (0x269B'i32, 0x269C'i32),
    (0x26A0'i32, 0x26A1'i32),
    (0x26A7'i32, 0x26A7'i32),
    (0x26AA'i32, 0x26AB'i32),
    (0x26B0'i32, 0x26B1'i32),
    (0x26BD'i32, 0x26BE'i32),
    (0x26C4'i32, 0x26C5'i32),
    (0x26C8'i32, 0x26C8'i32),
    (0x26CE'i32, 0x26CF'i32),
    (0x26D1'i32, 0x26D1'i32),
    (0x26D3'i32, 0x26D4'i32),
    (0x26E9'i32, 0x26EA'i32),
    (0x26F0'i32, 0x26F5'i32),
    (0x26F7'i32, 0x26FA'i32),
    (0x26FD'i32, 0x26FD'i32),
    (0x2702'i32, 0x2702'i32),
    (0x2705'i32, 0x2705'i32),
    (0x2708'i32, 0x270D'i32),
    (0x270F'i32, 0x270F'i32),
    (0x2712'i32, 0x2712'i32),
    (0x2714'i32, 0x2714'i32),
    (0x2716'i32, 0x2716'i32),
    (0x271D'i32, 0x271D'i32),
    (0x2721'i32, 0x2721'i32),
    (0x2728'i32, 0x2728'i32),
    (0x2733'i32, 0x2734'i32),
    (0x2744'i32, 0x2744'i32),
    (0x2747'i32, 0x2747'i32),
    (0x274C'i32, 0x274C'i32),
    (0x274E'i32, 0x274E'i32),
    (0x2753'i32, 0x2755'i32),
    (0x2757'i32, 0x2757'i32),
    (0x2763'i32, 0x2764'i32),
    (0x2795'i32, 0x2797'i32),
    (0x27A1'i32, 0x27A1'i32),
    (0x27B0'i32, 0x27B0'i32),
    (0x27BF'i32, 0x27BF'i32),
    (0x2934'i32, 0x2935'i32),
    (0x2B05'i32, 0x2B07'i32),
    (0x2B1B'i32, 0x2B1C'i32),
    (0x2B50'i32, 0x2B50'i32),
    (0x2B55'i32, 0x2B55'i32),
    (0x3030'i32, 0x3030'i32),
    (0x303D'i32, 0x303D'i32),
    (0x3297'i32, 0x3297'i32),
    (0x3299'i32, 0x3299'i32),
    (0x1F004'i32, 0x1F004'i32),
    (0x1F0CF'i32, 0x1F0CF'i32),
    (0x1F170'i32, 0x1F171'i32),
    (0x1F17E'i32, 0x1F17F'i32),
    (0x1F18E'i32, 0x1F18E'i32),
    (0x1F191'i32, 0x1F19A'i32),
    (0x1F1E6'i32, 0x1F1FF'i32),
    (0x1F201'i32, 0x1F202'i32),
    (0x1F21A'i32, 0x1F21A'i32),
    (0x1F22F'i32, 0x1F22F'i32),
    (0x1F232'i32, 0x1F23A'i32),
    (0x1F250'i32, 0x1F251'i32),
    (0x1F300'i32, 0x1F321'i32),
    (0x1F324'i32, 0x1F393'i32),
    (0x1F396'i32, 0x1F397'i32),
    (0x1F399'i32, 0x1F39B'i32),
    (0x1F39E'i32, 0x1F3F0'i32),
    (0x1F3F3'i32, 0x1F3F5'i32),
    (0x1F3F7'i32, 0x1F4FD'i32),
    (0x1F4FF'i32, 0x1F53D'i32),
    (0x1F549'i32, 0x1F54E'i32),
    (0x1F550'i32, 0x1F567'i32),
    (0x1F56F'i32, 0x1F570'i32),
    (0x1F573'i32, 0x1F57A'i32),
    (0x1F587'i32, 0x1F587'i32),
    (0x1F58A'i32, 0x1F58D'i32),
    (0x1F590'i32, 0x1F590'i32),
    (0x1F595'i32, 0x1F596'i32),
    (0x1F5A4'i32, 0x1F5A5'i32),
    (0x1F5A8'i32, 0x1F5A8'i32),
    (0x1F5B1'i32, 0x1F5B2'i32),
    (0x1F5BC'i32, 0x1F5BC'i32),
    (0x1F5C2'i32, 0x1F5C4'i32),
    (0x1F5D1'i32, 0x1F5D3'i32),
    (0x1F5DC'i32, 0x1F5DE'i32),
    (0x1F5E1'i32, 0x1F5E1'i32),
    (0x1F5E3'i32, 0x1F5E3'i32),
    (0x1F5E8'i32, 0x1F5E8'i32),
    (0x1F5EF'i32, 0x1F5EF'i32),
    (0x1F5F3'i32, 0x1F5F3'i32),
    (0x1F5FA'i32, 0x1F64F'i32),
    (0x1F680'i32, 0x1F6C5'i32),
    (0x1F6CB'i32, 0x1F6D2'i32),
    (0x1F6D5'i32, 0x1F6D7'i32),
    (0x1F6DC'i32, 0x1F6E5'i32),
    (0x1F6E9'i32, 0x1F6E9'i32),
    (0x1F6EB'i32, 0x1F6EC'i32),
    (0x1F6F0'i32, 0x1F6F0'i32),
    (0x1F6F3'i32, 0x1F6FC'i32),
    (0x1F7E0'i32, 0x1F7EB'i32),
    (0x1F7F0'i32, 0x1F7F0'i32),
    (0x1F90C'i32, 0x1F93A'i32),
    (0x1F93C'i32, 0x1F945'i32),
    (0x1F947'i32, 0x1F9FF'i32),
    (0x1FA70'i32, 0x1FA7C'i32),
    (0x1FA80'i32, 0x1FA88'i32),
    (0x1FA90'i32, 0x1FABD'i32),
    (0x1FABF'i32, 0x1FAC5'i32),
    (0x1FACE'i32, 0x1FADB'i32),
    (0x1FAE0'i32, 0x1FAE8'i32),
    (0x1FAF0'i32, 0x1FAF8'i32),
  ]

  ExtPictRanges*: array[78, (int32, int32)] = [
    (0x00A9'i32, 0x00A9'i32),
    (0x00AE'i32, 0x00AE'i32),
    (0x203C'i32, 0x203C'i32),
    (0x2049'i32, 0x2049'i32),
    (0x2122'i32, 0x2122'i32),
    (0x2139'i32, 0x2139'i32),
    (0x2194'i32, 0x2199'i32),
    (0x21A9'i32, 0x21AA'i32),
    (0x231A'i32, 0x231B'i32),
    (0x2328'i32, 0x2328'i32),
    (0x2388'i32, 0x2388'i32),
    (0x23CF'i32, 0x23CF'i32),
    (0x23E9'i32, 0x23F3'i32),
    (0x23F8'i32, 0x23FA'i32),
    (0x24C2'i32, 0x24C2'i32),
    (0x25AA'i32, 0x25AB'i32),
    (0x25B6'i32, 0x25B6'i32),
    (0x25C0'i32, 0x25C0'i32),
    (0x25FB'i32, 0x25FE'i32),
    (0x2600'i32, 0x2605'i32),
    (0x2607'i32, 0x2612'i32),
    (0x2614'i32, 0x2685'i32),
    (0x2690'i32, 0x2705'i32),
    (0x2708'i32, 0x2712'i32),
    (0x2714'i32, 0x2714'i32),
    (0x2716'i32, 0x2716'i32),
    (0x271D'i32, 0x271D'i32),
    (0x2721'i32, 0x2721'i32),
    (0x2728'i32, 0x2728'i32),
    (0x2733'i32, 0x2734'i32),
    (0x2744'i32, 0x2744'i32),
    (0x2747'i32, 0x2747'i32),
    (0x274C'i32, 0x274C'i32),
    (0x274E'i32, 0x274E'i32),
    (0x2753'i32, 0x2755'i32),
    (0x2757'i32, 0x2757'i32),
    (0x2763'i32, 0x2767'i32),
    (0x2795'i32, 0x2797'i32),
    (0x27A1'i32, 0x27A1'i32),
    (0x27B0'i32, 0x27B0'i32),
    (0x27BF'i32, 0x27BF'i32),
    (0x2934'i32, 0x2935'i32),
    (0x2B05'i32, 0x2B07'i32),
    (0x2B1B'i32, 0x2B1C'i32),
    (0x2B50'i32, 0x2B50'i32),
    (0x2B55'i32, 0x2B55'i32),
    (0x3030'i32, 0x3030'i32),
    (0x303D'i32, 0x303D'i32),
    (0x3297'i32, 0x3297'i32),
    (0x3299'i32, 0x3299'i32),
    (0x1F000'i32, 0x1F0FF'i32),
    (0x1F10D'i32, 0x1F10F'i32),
    (0x1F12F'i32, 0x1F12F'i32),
    (0x1F16C'i32, 0x1F171'i32),
    (0x1F17E'i32, 0x1F17F'i32),
    (0x1F18E'i32, 0x1F18E'i32),
    (0x1F191'i32, 0x1F19A'i32),
    (0x1F1AD'i32, 0x1F1E5'i32),
    (0x1F201'i32, 0x1F20F'i32),
    (0x1F21A'i32, 0x1F21A'i32),
    (0x1F22F'i32, 0x1F22F'i32),
    (0x1F232'i32, 0x1F23A'i32),
    (0x1F23C'i32, 0x1F23F'i32),
    (0x1F249'i32, 0x1F3FA'i32),
    (0x1F400'i32, 0x1F53D'i32),
    (0x1F546'i32, 0x1F64F'i32),
    (0x1F680'i32, 0x1F6FF'i32),
    (0x1F774'i32, 0x1F77F'i32),
    (0x1F7D5'i32, 0x1F7FF'i32),
    (0x1F80C'i32, 0x1F80F'i32),
    (0x1F848'i32, 0x1F84F'i32),
    (0x1F85A'i32, 0x1F85F'i32),
    (0x1F888'i32, 0x1F88F'i32),
    (0x1F8AE'i32, 0x1F8FF'i32),
    (0x1F90C'i32, 0x1F93A'i32),
    (0x1F93C'i32, 0x1F945'i32),
    (0x1F947'i32, 0x1FAFF'i32),
    (0x1FC00'i32, 0x1FFFD'i32),
  ]

  # Hangul syllable ranges
  HangulSBase = 0xAC00
  HangulLBase = 0x1100
  HangulVBase = 0x1161
  HangulTBase = 0x11A7
  HangulLCount = 19
  HangulVCount = 21
  HangulTCount = 28
  HangulNCount = HangulVCount * HangulTCount # 588
  HangulSCount = HangulLCount * HangulNCount # 11172

  # Prepend codepoints (GCB=Prepend from Unicode 15.1 GraphemeBreakProperty.txt)
  PrependRanges: array[14, (int32, int32)] = [
    (0x0600'i32, 0x0605'i32),
    (0x06DD'i32, 0x06DD'i32),
    (0x070F'i32, 0x070F'i32),
    (0x0890'i32, 0x0891'i32),
    (0x08E2'i32, 0x08E2'i32),
    (0x0D4E'i32, 0x0D4E'i32),
    (0x110BD'i32, 0x110BD'i32),
    (0x110CD'i32, 0x110CD'i32),
    (0x111C2'i32, 0x111C3'i32),
    (0x1193F'i32, 0x1193F'i32),
    (0x11941'i32, 0x11941'i32),
    (0x11A3A'i32, 0x11A3A'i32),
    (0x11D46'i32, 0x11D46'i32),
    (0x11F02'i32, 0x11F02'i32),
  ]

  # SpacingMark codepoints that are GCB=SpacingMark (not Extend)
  # These are General_Category=Mc chars that have GCB=SpacingMark
  SpacingMarkRanges: array[50, (int32, int32)] = [
    (0x0903'i32, 0x0903'i32),
    (0x093B'i32, 0x093B'i32),
    (0x093E'i32, 0x0940'i32),
    (0x0949'i32, 0x094C'i32),
    (0x094E'i32, 0x094F'i32),
    (0x0982'i32, 0x0983'i32),
    (0x09BE'i32, 0x09C0'i32),
    (0x09C7'i32, 0x09C8'i32),
    (0x09CB'i32, 0x09CC'i32),
    (0x09D7'i32, 0x09D7'i32),
    (0x0A03'i32, 0x0A03'i32),
    (0x0A3E'i32, 0x0A40'i32),
    (0x0A83'i32, 0x0A83'i32),
    (0x0ABE'i32, 0x0AC0'i32),
    (0x0AC9'i32, 0x0AC9'i32),
    (0x0ACB'i32, 0x0ACC'i32),
    (0x0B02'i32, 0x0B03'i32),
    (0x0B3E'i32, 0x0B3E'i32),
    (0x0B40'i32, 0x0B40'i32),
    (0x0B47'i32, 0x0B48'i32),
    (0x0B4B'i32, 0x0B4C'i32),
    (0x0B57'i32, 0x0B57'i32),
    (0x0BBE'i32, 0x0BBF'i32),
    (0x0BC1'i32, 0x0BC2'i32),
    (0x0BC6'i32, 0x0BC8'i32),
    (0x0BCA'i32, 0x0BCC'i32),
    (0x0BD7'i32, 0x0BD7'i32),
    (0x0C01'i32, 0x0C03'i32),
    (0x0C41'i32, 0x0C44'i32),
    (0x0C82'i32, 0x0C83'i32),
    (0x0CBE'i32, 0x0CBE'i32),
    (0x0CC0'i32, 0x0CC4'i32),
    (0x0CC7'i32, 0x0CC8'i32),
    (0x0CCA'i32, 0x0CCB'i32),
    (0x0CD5'i32, 0x0CD6'i32),
    (0x0CF3'i32, 0x0CF3'i32),
    (0x0D02'i32, 0x0D03'i32),
    (0x0D3E'i32, 0x0D40'i32),
    (0x0D46'i32, 0x0D48'i32),
    (0x0D4A'i32, 0x0D4C'i32),
    (0x0D57'i32, 0x0D57'i32),
    (0x0D82'i32, 0x0D83'i32),
    (0x0DCF'i32, 0x0DD1'i32),
    (0x0DD8'i32, 0x0DDF'i32),
    (0x0DF2'i32, 0x0DF3'i32),
    (0x0F3E'i32, 0x0F3F'i32),
    (0x0F7F'i32, 0x0F7F'i32),
    (0x1031'i32, 0x1031'i32),
    (0x1038'i32, 0x1038'i32),
    (0x17B6'i32, 0x17B6'i32),
  ]

  MultiCharFolds*: array[17, (int32, array[3, int32], int)] = [
    # (source_codepoint, expansion_codepoints, expansion_length)
    (0x00DF'i32, [0x0073'i32, 0x0073'i32, 0'i32], 2), # ß → ss
    (0x0130'i32, [0x0069'i32, 0x0307'i32, 0'i32], 2), # İ → i + combining dot above
    (0x0149'i32, [0x02BC'i32, 0x006E'i32, 0'i32], 2), # ŉ → ʼn
    (0x01F0'i32, [0x006A'i32, 0x030C'i32, 0'i32], 2), # ǰ → j + combining caron
    (0x0390'i32, [0x03B9'i32, 0x0308'i32, 0x0301'i32], 3), # ΐ → ι + ̈ + ́
    (0x03B0'i32, [0x03C5'i32, 0x0308'i32, 0x0301'i32], 3), # ΰ → υ + ̈ + ́
    (0x0587'i32, [0x0565'i32, 0x0582'i32, 0'i32], 2), # և → եւ
    (0x1E96'i32, [0x0068'i32, 0x0331'i32, 0'i32], 2),
      # ẖ → h + combining macron below
    (0x1E97'i32, [0x0074'i32, 0x0308'i32, 0'i32], 2), # ẗ → t + combining diaeresis
    (0x1E98'i32, [0x0077'i32, 0x030A'i32, 0'i32], 2), # ẘ → w + combining ring above
    (0x1E99'i32, [0x0079'i32, 0x030A'i32, 0'i32], 2), # ẙ → y + combining ring above
    (0x1E9E'i32, [0x0073'i32, 0x0073'i32, 0'i32], 2), # ẞ → ss
    (0xFB00'i32, [0x0066'i32, 0x0066'i32, 0'i32], 2), # ﬀ → ff
    (0xFB01'i32, [0x0066'i32, 0x0069'i32, 0'i32], 2), # ﬁ → fi
    (0xFB02'i32, [0x0066'i32, 0x006C'i32, 0'i32], 2), # ﬂ → fl
    (0xFB05'i32, [0x0073'i32, 0x0074'i32, 0'i32], 2), # ﬅ → st
    (0xFB06'i32, [0x0073'i32, 0x0074'i32, 0'i32], 2), # ﬆ → st
  ]

proc inRangeTable*(cp: int32, table: openArray[(int32, int32)]): bool =
  ## Binary search a sorted table of (start, end) ranges.
  var lo = 0
  var hi = table.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let (s, e) = table[mid]
    if cp < s:
      hi = mid - 1
    elif cp > e:
      lo = mid + 1
    else:
      return true
  return false

proc isWordChar*(r: Rune, asciiOnly: bool): bool =
  ## \w: Letter, Mark, Number, Connector_Punctuation, or underscore
  if asciiOnly:
    let c = int32(r)
    return
      (c >= ord('a') and c <= ord('z')) or (c >= ord('A') and c <= ord('Z')) or
      (c >= ord('0') and c <= ord('9')) or c == ord('_')
  let cat = unicodeCategory(r)
  cat in ctgL or cat in ctgM or cat in ctgN or cat == ctgPc

proc isDigitChar*(r: Rune, asciiOnly: bool): bool =
  ## \d: Decimal digit
  if asciiOnly:
    let c = int32(r)
    return c >= ord('0') and c <= ord('9')
  unicodeCategory(r) == ctgNd

proc isSpaceChar*(r: Rune, asciiOnly: bool): bool =
  ## \s: Whitespace
  if asciiOnly:
    let c = int32(r)
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x0C or c == 0x0B
  let cat = unicodeCategory(r)
  cat in ctgZ or int32(r) == 0x09 or int32(r) == 0x0A or int32(r) == 0x0B or
    int32(r) == 0x0C or int32(r) == 0x0D or int32(r) == 0x85

proc isHexDigitChar*(r: Rune): bool =
  ## \h: Hex digit (always ASCII)
  let c = int32(r)
  (c >= ord('0') and c <= ord('9')) or (c >= ord('a') and c <= ord('f')) or
    (c >= ord('A') and c <= ord('F'))

proc simpleFold*(r: Rune): Rune =
  ## Simple case fold for case-insensitive matching
  simpleCaseFold(r)

proc getMultiCharFold*(r: Rune): RuneBuf =
  ## Get multi-character case fold expansion for a character.
  ## Returns len == 0 if no multi-char fold exists.
  let cp = int32(r)
  case cp
  of 0x00DF: # ß → ss
    RuneBuf(runes: [Rune(0x0073), Rune(0x0073), Rune(0)], len: 2)
  of 0x0130: # İ → i + dot above
    RuneBuf(runes: [Rune(0x0069), Rune(0x0307), Rune(0)], len: 2)
  of 0x01F0: # ǰ → j + combining caron
    RuneBuf(runes: [Rune(0x006A), Rune(0x030C), Rune(0)], len: 2)
  of 0x0390: # ΐ
    RuneBuf(runes: [Rune(0x03B9), Rune(0x0308), Rune(0x0301)], len: 3)
  of 0x03B0: # ΰ
    RuneBuf(runes: [Rune(0x03C5), Rune(0x0308), Rune(0x0301)], len: 3)
  of 0x0587: # և → եւ
    RuneBuf(runes: [Rune(0x0565), Rune(0x0582), Rune(0)], len: 2)
  of 0x1E96: # ẖ → h + combining macron below
    RuneBuf(runes: [Rune(0x0068), Rune(0x0331), Rune(0)], len: 2)
  of 0x1E97: # ẗ → t + diaeresis
    RuneBuf(runes: [Rune(0x0074), Rune(0x0308), Rune(0)], len: 2)
  of 0x1E98: # ẘ → w + ring above
    RuneBuf(runes: [Rune(0x0077), Rune(0x030A), Rune(0)], len: 2)
  of 0x1E99: # ẙ → y + ring above
    RuneBuf(runes: [Rune(0x0079), Rune(0x030A), Rune(0)], len: 2)
  of 0x1E9A: # ẚ → a + modifier letter right half ring
    RuneBuf(runes: [Rune(0x0061), Rune(0x02BE), Rune(0)], len: 2)
  of 0x1E9E: # ẞ → ss (capital sharp s)
    RuneBuf(runes: [Rune(0x0073), Rune(0x0073), Rune(0)], len: 2)
  of 0x1F50: # ὐ
    RuneBuf(runes: [Rune(0x03C5), Rune(0x0313), Rune(0)], len: 2)
  of 0xFB00: # ﬀ → ff
    RuneBuf(runes: [Rune(0x0066), Rune(0x0066), Rune(0)], len: 2)
  of 0xFB01: # ﬁ → fi
    RuneBuf(runes: [Rune(0x0066), Rune(0x0069), Rune(0)], len: 2)
  of 0xFB02: # ﬂ → fl
    RuneBuf(runes: [Rune(0x0066), Rune(0x006C), Rune(0)], len: 2)
  of 0xFB03: # ﬃ → ffi
    RuneBuf(runes: [Rune(0x0066), Rune(0x0066), Rune(0x0069)], len: 3)
  of 0xFB04: # ﬄ → ffl
    RuneBuf(runes: [Rune(0x0066), Rune(0x0066), Rune(0x006C)], len: 3)
  of 0xFB05: # ﬅ → st
    RuneBuf(runes: [Rune(0x0073), Rune(0x0074), Rune(0)], len: 2)
  of 0xFB06: # ﬆ → st
    RuneBuf(runes: [Rune(0x0073), Rune(0x0074), Rune(0)], len: 2)
  else:
    RuneBuf(runes: [Rune(0), Rune(0), Rune(0)], len: 0)

proc getReverseMultiCharFolds*(r1, r2: Rune): RuneBuf =
  ## Given two consecutive characters, return characters that fold to this pair.
  ## Used for matching subject "ss" against pattern "ß".
  let cp1 = int32(r1)
  let cp2 = int32(r2)
  if cp1 == 0x0073 and cp2 == 0x0073: # ss → ß, ẞ
    RuneBuf(runes: [Rune(0x00DF), Rune(0x1E9E), Rune(0)], len: 2)
  elif cp1 == 0x0066 and cp2 == 0x0066: # ff → ﬀ
    RuneBuf(runes: [Rune(0xFB00), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0066 and cp2 == 0x0069: # fi → ﬁ
    RuneBuf(runes: [Rune(0xFB01), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0066 and cp2 == 0x006C: # fl → ﬂ
    RuneBuf(runes: [Rune(0xFB02), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0073 and cp2 == 0x0074: # st → ﬅ, ﬆ
    RuneBuf(runes: [Rune(0xFB05), Rune(0xFB06), Rune(0)], len: 2)
  elif cp1 == 0x006A and cp2 == 0x030C: # j + caron → ǰ
    RuneBuf(runes: [Rune(0x01F0), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0068 and cp2 == 0x0331: # h + macron below → ẖ
    RuneBuf(runes: [Rune(0x1E96), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0074 and cp2 == 0x0308: # t + diaeresis → ẗ
    RuneBuf(runes: [Rune(0x1E97), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0077 and cp2 == 0x030A: # w + ring → ẘ
    RuneBuf(runes: [Rune(0x1E98), Rune(0), Rune(0)], len: 1)
  elif cp1 == 0x0079 and cp2 == 0x030A: # y + ring → ẙ
    RuneBuf(runes: [Rune(0x1E99), Rune(0), Rune(0)], len: 1)
  else:
    RuneBuf(runes: [Rune(0), Rune(0), Rune(0)], len: 0)

proc posixAsciiOnly*(cls: PosixClassName, flags: RegexFlags): bool =
  ## Check if POSIX class should use ASCII-only matching based on flags.
  ## Individual flags (W/D/S) override the general P flag.
  if rfAsciiPosix in flags:
    return true
  case cls
  of pcWord:
    rfAsciiWord in flags
  of pcDigit:
    rfAsciiDigit in flags
  of pcSpace:
    rfAsciiSpace in flags
  of pcAlnum:
    rfAsciiWord in flags
  # alnum relates to word chars
  of pcAlpha:
    rfAsciiWord in flags
  else:
    false

proc matchPosixClass*(r: Rune, cls: PosixClassName, asciiOnly: bool): bool =
  let c = int32(r)
  case cls
  of pcAlnum:
    if asciiOnly:
      (c >= ord('a') and c <= ord('z')) or (c >= ord('A') and c <= ord('Z')) or
        (c >= ord('0') and c <= ord('9'))
    else:
      let cat = unicodeCategory(r)
      cat in ctgL or cat in ctgN
  of pcAlpha:
    if asciiOnly:
      (c >= ord('a') and c <= ord('z')) or (c >= ord('A') and c <= ord('Z'))
    else:
      unicodeCategory(r) in ctgL
  of pcAscii:
    c >= 0 and c <= 127
  of pcBlank:
    c == 0x20 or c == 0x09
  of pcCntrl:
    if asciiOnly:
      (c >= 0 and c < 0x20) or c == 0x7F
    else:
      unicodeCategory(r) == ctgCc
  of pcDigit:
    if asciiOnly:
      c >= ord('0') and c <= ord('9')
    else:
      unicodeCategory(r) == ctgNd
  of pcGraph:
    if asciiOnly:
      c > 0x20 and c < 0x7F
    else:
      let cat = unicodeCategory(r)
      not (cat in ctgZ or cat in ctgC) and c != ord(' ')
  of pcLower:
    if asciiOnly:
      c >= ord('a') and c <= ord('z')
    else:
      unicodeCategory(r) == ctgLl
  of pcPrint:
    if asciiOnly:
      c >= 0x20 and c < 0x7F
    else:
      let cat = unicodeCategory(r)
      not (cat in ctgC) or cat in ctgZ or c == ord(' ')
  of pcPunct:
    if asciiOnly:
      (c >= ord('!') and c <= ord('/')) or (c >= ord(':') and c <= ord('@')) or
        (c >= ord('[') and c <= ord('`')) or (c >= ord('{') and c <= ord('~'))
    else:
      # Oniguruma POSIX punct = graph AND NOT alnum (includes symbols)
      let cat = unicodeCategory(r)
      not (cat in ctgL or cat in ctgN or cat in ctgZ or cat in ctgC) and c != ord(' ')
  of pcSpace:
    isSpaceChar(r, asciiOnly)
  of pcUpper:
    if asciiOnly:
      c >= ord('A') and c <= ord('Z')
    else:
      unicodeCategory(r) == ctgLu
  of pcXdigit:
    isHexDigitChar(r)
  of pcWord:
    isWordChar(r, asciiOnly)

proc matchScript(script: UnicodeScript, name: string): bool =
  case name
  of "common":
    return script == sptCommon
  of "latin":
    return script == sptLatin
  of "greek":
    return script == sptGreek
  of "cyrillic":
    return script == sptCyrillic
  of "armenian":
    return script == sptArmenian
  of "hebrew":
    return script == sptHebrew
  of "arabic":
    return script == sptArabic
  of "han":
    return script == sptHan
  of "hiragana":
    return script == sptHiragana
  of "katakana":
    return script == sptKatakana
  of "hangul":
    return script == sptHangul
  of "thai":
    return script == sptThai
  of "devanagari":
    return script == sptDevanagari
  of "bengali":
    return script == sptBengali
  of "tamil":
    return script == sptTamil
  of "georgian":
    return script == sptGeorgian
  of "ethiopic":
    return script == sptEthiopic
  of "tibetan":
    return script == sptTibetan
  of "myanmar":
    return script == sptMyanmar
  of "bopomofo":
    return script == sptBopomofo
  of "inherited":
    return script == sptInherited
  of "coptic":
    return script == sptCoptic
  of "syriac":
    return script == sptSyriac
  of "khmer":
    return script == sptKhmer
  of "mongolian":
    return script == sptMongolian
  else:
    return false

proc matchUnicodeProp*(r: Rune, propName: string, flags: RegexFlags = {}): bool =
  ## Match \p{PropertyName}. Supports General Category and Script names.
  let name = propName.toLowerAscii()
  # Check ASCII-restriction flags for word/digit/space properties
  # Both individual flags (W/D/S) and the general P flag restrict to ASCII
  if name in ["word"]:
    if rfAsciiWord in flags or rfAsciiPosix in flags:
      return isWordChar(r, true)
  elif name in ["digit"]:
    if rfAsciiDigit in flags or rfAsciiPosix in flags:
      return isDigitChar(r, true)
  elif name in ["space", "white_space"]:
    if rfAsciiSpace in flags or rfAsciiPosix in flags:
      return isSpaceChar(r, true)
  elif name in [
    "alpha", "alnum", "upper", "lower", "print", "graph", "blank", "cntrl", "xdigit",
    "punct", "ascii",
  ]:
    if rfAsciiPosix in flags:
      return matchPosixClass(
        r,
        (
          case name
          of "alpha": pcAlpha
          of "alnum": pcAlnum
          of "upper": pcUpper
          of "lower": pcLower
          of "print": pcPrint
          of "graph": pcGraph
          of "blank": pcBlank
          of "cntrl": pcCntrl
          of "xdigit": pcXdigit
          of "punct": pcPunct
          of "ascii": pcAscii
          else: pcAlpha
        ),
        true,
      )
  # Single-letter general categories
  case name
  of "l", "letter":
    return unicodeCategory(r) in ctgL
  of "m", "mark":
    return unicodeCategory(r) in ctgM
  of "n", "number":
    return unicodeCategory(r) in ctgN
  of "p", "punct", "punctuation":
    return unicodeCategory(r) in ctgP
  of "s", "symbol":
    return unicodeCategory(r) in ctgS
  of "z", "separator":
    return unicodeCategory(r) in ctgZ
  of "c", "other":
    return unicodeCategory(r) in ctgC
  # Two-letter subcategories
  of "lu", "uppercase_letter":
    return unicodeCategory(r) == ctgLu
  of "ll", "lowercase_letter":
    return unicodeCategory(r) == ctgLl
  of "lt", "titlecase_letter":
    return unicodeCategory(r) == ctgLt
  of "lm", "modifier_letter":
    return unicodeCategory(r) == ctgLm
  of "lo", "other_letter":
    return unicodeCategory(r) == ctgLo
  of "mn", "nonspacing_mark":
    return unicodeCategory(r) == ctgMn
  of "mc", "spacing_mark":
    return unicodeCategory(r) == ctgMc
  of "me", "enclosing_mark":
    return unicodeCategory(r) == ctgMe
  of "nd", "decimal_number":
    return unicodeCategory(r) == ctgNd
  of "nl", "letter_number":
    return unicodeCategory(r) == ctgNl
  of "no", "other_number":
    return unicodeCategory(r) == ctgNo
  of "pc", "connector_punctuation":
    return unicodeCategory(r) == ctgPc
  of "pd", "dash_punctuation":
    return unicodeCategory(r) == ctgPd
  of "ps", "open_punctuation":
    return unicodeCategory(r) == ctgPs
  of "pe", "close_punctuation":
    return unicodeCategory(r) == ctgPe
  of "pi", "initial_punctuation":
    return unicodeCategory(r) == ctgPi
  of "pf", "final_punctuation":
    return unicodeCategory(r) == ctgPf
  of "po", "other_punctuation":
    return unicodeCategory(r) == ctgPo
  of "sm", "math_symbol":
    return unicodeCategory(r) == ctgSm
  of "sc", "currency_symbol":
    return unicodeCategory(r) == ctgSc
  of "sk", "modifier_symbol":
    return unicodeCategory(r) == ctgSk
  of "so", "other_symbol":
    return unicodeCategory(r) == ctgSo
  of "zs", "space_separator":
    return unicodeCategory(r) == ctgZs
  of "zl", "line_separator":
    return unicodeCategory(r) == ctgZl
  of "zp", "paragraph_separator":
    return unicodeCategory(r) == ctgZp
  of "cc", "control":
    return unicodeCategory(r) == ctgCc
  of "cf", "format":
    return unicodeCategory(r) == ctgCf
  of "cs", "surrogate":
    return unicodeCategory(r) == ctgCs
  of "co", "private_use":
    return unicodeCategory(r) == ctgCo
  of "cn", "unassigned":
    return unicodeCategory(r) == ctgCn
  # Common property aliases
  of "any":
    return true
  of "ascii":
    return int32(r) >= 0 and int32(r) <= 127
  of "print":
    return matchPosixClass(r, pcPrint, false)
  of "graph":
    return matchPosixClass(r, pcGraph, false)
  of "alpha":
    return unicodeCategory(r) in ctgL
  of "alnum":
    let cat = unicodeCategory(r)
    return cat in ctgL or cat in ctgN
  of "digit":
    return unicodeCategory(r) == ctgNd
  of "space", "white_space":
    return isSpaceChar(r, false)
  of "word":
    return isWordChar(r, false)
  of "blank":
    return int32(r) == 0x20 or int32(r) == 0x09
  of "cntrl":
    return unicodeCategory(r) == ctgCc
  of "xdigit":
    return isHexDigitChar(r)
  of "posixpunct":
    return matchPosixClass(r, pcPunct, false)
  of "posixalnum":
    return matchPosixClass(r, pcAlnum, false)
  of "posixalpha":
    return matchPosixClass(r, pcAlpha, false)
  of "posixblank":
    return matchPosixClass(r, pcBlank, false)
  of "posixcntrl":
    return matchPosixClass(r, pcCntrl, false)
  of "posixdigit":
    return matchPosixClass(r, pcDigit, false)
  of "posixgraph":
    return matchPosixClass(r, pcGraph, false)
  of "posixlower":
    return matchPosixClass(r, pcLower, false)
  of "posixprint":
    return matchPosixClass(r, pcPrint, false)
  of "posixspace":
    return matchPosixClass(r, pcSpace, false)
  of "posixupper":
    return matchPosixClass(r, pcUpper, false)
  of "posixxdigit":
    return matchPosixClass(r, pcXdigit, false)
  of "posixword":
    return matchPosixClass(r, pcWord, false)
  # Emoji binary properties (Unicode 15.1)
  of "emoji":
    return inRangeTable(int32(r), EmojiRanges)
  of "extended_pictographic", "extpict":
    return inRangeTable(int32(r), ExtPictRanges)
  else:
    # Try "In" prefix for Unicode block names
    if name.len > 2 and name.startsWith("in"):
      let blockName = name[2 ..^ 1]
      for i, bn in blockNames.pairs:
        # Normalize: remove spaces, underscores, hyphens and compare
        let normalBn =
          bn.toLowerAscii().replace(" ", "").replace("-", "").replace("_", "")
        let normalQuery = blockName.replace(" ", "").replace("-", "").replace("_", "")
        if normalBn == normalQuery:
          return int32(r) in blockRanges[i]
      return false
    # Try as script name
    let script = unicodeScript(r)
    return matchScript(script, name)

proc graphemeBreakProp*(r: Rune): GcbProp =
  let cp = int32(r)
  # Single-value checks first
  if cp == 0x000D:
    return gcbCR
  if cp == 0x000A:
    return gcbLF
  if cp == 0x200D:
    return gcbZWJ
  # Control
  if cp <= 0x001F or (cp >= 0x007F and cp <= 0x009F) or cp == 0x00AD or cp == 0x061C or
      cp == 0x180E or cp == 0x200B or cp == 0x200E or cp == 0x200F or
      (cp >= 0x2028 and cp <= 0x2029) or (cp >= 0x2060 and cp <= 0x2064) or
      (cp >= 0x2066 and cp <= 0x206F) or cp == 0xFEFF or (cp >= 0xFFF0 and cp <= 0xFFF8) or
      cp == 0xFFFE or cp == 0xFFFF:
    return gcbControl
  # Regional Indicator
  if cp >= 0x1F1E6 and cp <= 0x1F1FF:
    return gcbRegionalIndicator
  # Hangul Jamo (Leading)
  if (cp >= HangulLBase and cp < HangulLBase + HangulLCount) or
      (cp >= 0xA960 and cp <= 0xA97C):
    return gcbL
  # Hangul Jamo (Vowel)
  if (cp >= HangulVBase and cp < HangulVBase + HangulVCount) or
      (cp >= 0xD7B0 and cp <= 0xD7C6):
    return gcbV
  # Hangul Jamo (Trailing)
  if (cp >= HangulTBase + 1 and cp < HangulTBase + HangulTCount) or
      (cp >= 0xD7CB and cp <= 0xD7FB):
    return gcbT
  # Hangul Syllable (LV or LVT)
  if cp >= HangulSBase and cp < HangulSBase + HangulSCount:
    if (cp - HangulSBase) mod HangulTCount == 0:
      return gcbLV
    else:
      return gcbLVT
  # Prepend
  if inRangeTable(cp, PrependRanges):
    return gcbPrepend
  # Special SpacingMark characters whose General_Category is NOT Mc
  # (e.g., Thai Sara Am U+0E33 has GC=Lo but GCB=SpacingMark)
  if cp == 0x0E33 or cp == 0x0EB3:
    return gcbSpacingMark
  # Check general category for Extend vs SpacingMark
  let gc = unicodeCategory(r)
  # Extend: Mn (nonspacing mark), Me (enclosing mark), plus U+200C
  if gc == ctgMn or gc == ctgMe or cp == 0x200C:
    return gcbExtend
  # Grapheme_Extend includes some Mc that are NOT SpacingMark
  if gc == ctgMc:
    if inRangeTable(cp, SpacingMarkRanges):
      return gcbSpacingMark
    return gcbExtend
  # Format characters (Cf) that are not already categorized
  if gc == ctgCf:
    return gcbExtend
  gcbOther

proc isGraphemeBoundary*(subject: string, pos: int): bool =
  ## Determine if there is a grapheme cluster boundary at byte position `pos`
  ## in `subject`. Returns true at string boundaries and at grapheme breaks.
  ## Implements UAX #29 grapheme cluster boundary rules (simplified).
  if pos <= 0 or pos >= subject.len:
    return true
  # Decode the rune just before pos and at pos
  var prevStart = pos - 1
  while prevStart > 0 and (subject[prevStart].uint8 and 0xC0'u8) == 0x80'u8:
    dec prevStart
  var prevPos = prevStart
  var prevRune: Rune
  fastRuneAt(subject, prevPos, prevRune, true) # advances prevPos past the rune
  var curPos = pos
  var curRune: Rune
  if curPos < subject.len:
    fastRuneAt(subject, curPos, curRune, true)
  else:
    return true
  let prev = graphemeBreakProp(prevRune)
  let cur = graphemeBreakProp(curRune)
  # GB3: Do not break between CR and LF
  if prev == gcbCR and cur == gcbLF:
    return false
  # GB4: Break after controls
  if prev in {gcbControl, gcbCR, gcbLF}:
    return true
  # GB5: Break before controls
  if cur in {gcbControl, gcbCR, gcbLF}:
    return true
  # GB6: Do not break Hangul syllable sequences (L × (L | V | LV | LVT))
  if prev == gcbL and cur in {gcbL, gcbV, gcbLV, gcbLVT}:
    return false
  # GB7: (LV | V) × (V | T)
  if prev in {gcbLV, gcbV} and cur in {gcbV, gcbT}:
    return false
  # GB8: (LVT | T) × T
  if prev in {gcbLVT, gcbT} and cur == gcbT:
    return false
  # GB9: × (Extend | ZWJ)
  if cur in {gcbExtend, gcbZWJ}:
    return false
  # GB9a: × SpacingMark
  if cur == gcbSpacingMark:
    return false
  # GB9b: Prepend ×
  if prev == gcbPrepend:
    return false
  # GB11: \p{Extended_Pictographic} Extend* ZWJ × \p{Extended_Pictographic}
  if prev == gcbZWJ and inRangeTable(int32(curRune), ExtPictRanges):
    # Check that before the ZWJ there is ExtPict followed by zero or more Extends
    var scanPos = prevStart
    while scanPos > 0:
      var sp = scanPos - 1
      while sp > 0 and (subject[sp].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp
      var r2: Rune
      var sp2 = sp
      fastRuneAt(subject, sp2, r2, true)
      let prop = graphemeBreakProp(r2)
      if prop == gcbExtend:
        scanPos = sp
        continue
      if inRangeTable(int32(r2), ExtPictRanges):
        return false # GB11 applies
      break
    # GB11 does not apply if no ExtPict found before ZWJ
  # GB12/GB13: Regional_Indicator handling (pairs)
  if prev == gcbRegionalIndicator and cur == gcbRegionalIndicator:
    # Count preceding RI characters
    var riCount = 0
    var scanPos = prevStart
    while scanPos > 0:
      var sp = scanPos - 1
      while sp > 0 and (subject[sp].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp
      var r2: Rune
      var sp2 = sp
      fastRuneAt(subject, sp2, r2, true)
      if graphemeBreakProp(r2) != gcbRegionalIndicator:
        break
      inc riCount
      scanPos = sp
    # Don't break if odd number of RI before (makes a pair)
    if riCount mod 2 == 0:
      return false
    return true
  # GB999: Otherwise, break
  true

proc nextGraphemeClusterEnd*(subject: string, pos: int): int =
  ## Return the byte position just past the end of the grapheme cluster
  ## starting at `pos`.
  if pos >= subject.len:
    return pos
  var p = pos
  var r: Rune
  fastRuneAt(subject, p, r, true)
  # Consume following characters that don't form a boundary
  while p < subject.len:
    if isGraphemeBoundary(subject, p):
      break
    fastRuneAt(subject, p, r, true)
  p

proc isWordBoundaryUax29*(subject: string, pos: int): bool =
  ## Determine if there is a word boundary at byte position `pos`
  ## per UAX #29 word break rules. Returns true at string boundaries.
  if pos <= 0 or pos >= subject.len:
    return true
  # Decode runes before and at pos
  var prevStart = pos - 1
  while prevStart > 0 and (subject[prevStart].uint8 and 0xC0'u8) == 0x80'u8:
    dec prevStart
  var prevPos = prevStart
  var prevRune: Rune
  fastRuneAt(subject, prevPos, prevRune, true) # advances prevPos
  var curPos = pos
  var curRune: Rune
  fastRuneAt(subject, curPos, curRune, true)
  let prev = wordBreakProp(prevRune)
  let cur = wordBreakProp(curRune)
  # WB3: Do not break between CR and LF
  if prev == sgwCr and cur == sgwLf:
    return false
  # WB3a/WB3b: Break after/before newlines
  if prev in {sgwCr, sgwLf, sgwNewline}:
    return true
  if cur in {sgwCr, sgwLf, sgwNewline}:
    return true
  # WB3c: ZWJ × \p{Extended_Pictographic}
  if prev == sgwZwj and cur == sgwExtendedPictographic:
    return false
  # WB3d: WSegSpace × WSegSpace
  if prev == sgwWsegSpace and cur == sgwWsegSpace:
    return false
  # WB4: Skip Extend/Format/ZWJ (treat as transparent)
  # Get the "effective" previous property (skip Extend/Format/ZWJ)
  var effPrev = prev
  var effPrevRune = prevRune
  if effPrev in {sgwExtend, sgwFormat, sgwZwj}:
    var sp = prevStart
    while sp > 0:
      var sp2 = sp - 1
      while sp2 > 0 and (subject[sp2].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp2
      var r2: Rune
      var sp3 = sp2
      fastRuneAt(subject, sp3, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        effPrev = p2
        effPrevRune = r2
        break
      sp = sp2
  # WB5: AHLetter × AHLetter
  let isAHPrev = effPrev in {sgwAletter, sgwHebrewLetter}
  let isAHCur = cur in {sgwAletter, sgwHebrewLetter}
  if isAHPrev and isAHCur:
    return false
  # WB6: AHLetter × (MidLetter | MidNumLetQ) AHLetter
  if isAHPrev and cur in {sgwMidLetter, sgwMidNumLet, sgwSingleQuote}:
    # Look ahead: is the char after cur an AHLetter?
    var np = curPos
    # Skip the current char (already consumed by fastRuneAt above)
    # Skip Extend/Format/ZWJ
    while np < subject.len:
      var r2: Rune
      var np2 = np
      fastRuneAt(subject, np2, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 in {sgwAletter, sgwHebrewLetter}:
          return false
        break
      np = np2
  # WB7: AHLetter (MidLetter | MidNumLetQ) × AHLetter
  if isAHCur and effPrev in {sgwMidLetter, sgwMidNumLet, sgwSingleQuote}:
    # Look back further: is the char before effPrev an AHLetter?
    var sp = prevStart
    while sp > 0:
      var sp2 = sp - 1
      while sp2 > 0 and (subject[sp2].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp2
      var r2: Rune
      var sp3 = sp2
      fastRuneAt(subject, sp3, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 in {sgwAletter, sgwHebrewLetter}:
          return false
        break
      sp = sp2
  # WB7a: Hebrew_Letter × Single_Quote
  if effPrev == sgwHebrewLetter and cur == sgwSingleQuote:
    return false
  # WB7b: Hebrew_Letter × Double_Quote Hebrew_Letter
  if effPrev == sgwHebrewLetter and cur == sgwDoubleQuote:
    var np = curPos
    while np < subject.len:
      var r2: Rune
      var np2 = np
      fastRuneAt(subject, np2, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 == sgwHebrewLetter:
          return false
        break
      np = np2
  # WB7c: Hebrew_Letter Double_Quote × Hebrew_Letter
  if cur == sgwHebrewLetter and effPrev == sgwDoubleQuote:
    var sp = prevStart
    while sp > 0:
      var sp2 = sp - 1
      while sp2 > 0 and (subject[sp2].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp2
      var r2: Rune
      var sp3 = sp2
      fastRuneAt(subject, sp3, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 == sgwHebrewLetter:
          return false
        break
      sp = sp2
  # WB8: Numeric × Numeric
  if effPrev == sgwNumeric and cur == sgwNumeric:
    return false
  # WB9: AHLetter × Numeric
  if isAHPrev and cur == sgwNumeric:
    return false
  # WB10: Numeric × AHLetter
  if effPrev == sgwNumeric and isAHCur:
    return false
  # WB11: Numeric (MidNum | MidNumLetQ) × Numeric
  if cur == sgwNumeric and effPrev in {sgwMidNum, sgwMidNumLet, sgwSingleQuote}:
    var sp = prevStart
    while sp > 0:
      var sp2 = sp - 1
      while sp2 > 0 and (subject[sp2].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp2
      var r2: Rune
      var sp3 = sp2
      fastRuneAt(subject, sp3, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 == sgwNumeric:
          return false
        break
      sp = sp2
  # WB12: Numeric × (MidNum | MidNumLetQ) Numeric
  if effPrev == sgwNumeric and cur in {sgwMidNum, sgwMidNumLet, sgwSingleQuote}:
    var np = curPos
    while np < subject.len:
      var r2: Rune
      var np2 = np
      fastRuneAt(subject, np2, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 == sgwNumeric:
          return false
        break
      np = np2
  # WB13: Katakana × Katakana
  if effPrev == sgwKatakana and cur == sgwKatakana:
    return false
  # WB13a: (AHLetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
  if cur == sgwExtendNumLet and
      effPrev in {sgwAletter, sgwHebrewLetter, sgwNumeric, sgwKatakana, sgwExtendNumLet}:
    return false
  # WB13b: ExtendNumLet × (AHLetter | Numeric | Katakana)
  if effPrev == sgwExtendNumLet and
      cur in {sgwAletter, sgwHebrewLetter, sgwNumeric, sgwKatakana}:
    return false
  # WB15/WB16: Regional Indicator handling (pairs)
  if effPrev == sgwRegionalIndicator and cur == sgwRegionalIndicator:
    var riCount = 0
    var sp = prevStart
    while sp > 0:
      var sp2 = sp - 1
      while sp2 > 0 and (subject[sp2].uint8 and 0xC0'u8) == 0x80'u8:
        dec sp2
      var r2: Rune
      var sp3 = sp2
      fastRuneAt(subject, sp3, r2, true)
      let p2 = wordBreakProp(r2)
      if p2 notin {sgwExtend, sgwFormat, sgwZwj}:
        if p2 != sgwRegionalIndicator:
          break
        inc riCount
      sp = sp2
    if riCount mod 2 == 0:
      return false
    return true
  # WB4: × (Extend | Format | ZWJ)
  if cur in {sgwExtend, sgwFormat, sgwZwj}:
    return false
  # WB999: Otherwise, break
  return true

proc nextWordSegmentEnd*(subject: string, pos: int): int =
  ## Return the byte position just past the end of the word segment
  ## starting at `pos` (per UAX #29 word boundaries).
  if pos >= subject.len:
    return pos
  var p = pos
  var r: Rune
  fastRuneAt(subject, p, r, true)
  while p < subject.len:
    if isWordBoundaryUax29(subject, p):
      break
    fastRuneAt(subject, p, r, true)
  return p
