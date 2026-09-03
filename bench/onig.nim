## Minimal FFI bindings to the Oniguruma C library (libonig).
##
## Only the handful of entry points the benchmark harness needs are bound:
## initialization, pattern compilation, forward search with a reusable
## region, and error reporting.  This module is benchmark-only; it is not
## part of the reni package.

import std/strutils

const
  RawCflags = staticExec("pkg-config --cflags oniguruma 2>/dev/null")
  RawLibs = staticExec("pkg-config --libs oniguruma 2>/dev/null")
  OnigCflags = RawCflags.strip()
  OnigLibs =
    if RawLibs.strip().len > 0:
      RawLibs.strip()
    else:
      "-lonig"

when OnigCflags.len > 0:
  {.passC: OnigCflags.}
{.passL: OnigLibs.}

const onigH = "<oniguruma.h>"

type
  OnigUChar* = uint8
  OnigOptionType* = cuint

  OnigEncodingType* {.importc: "OnigEncodingType", header: onigH.} = object
  OnigEncoding* = ptr OnigEncodingType

  OnigSyntaxType* {.importc: "OnigSyntaxType", header: onigH.} = object

  OnigRegexType {.importc: "OnigRegexType", header: onigH.} = object
  OnigRegex* = ptr OnigRegexType

  OnigErrorInfo* {.importc: "OnigErrorInfo", header: onigH, bycopy.} = object

  OnigRegion* {.importc: "OnigRegion", header: onigH, bycopy.} = object
    allocated* {.importc: "allocated".}: cint
    numRegs* {.importc: "num_regs".}: cint
    beg* {.importc: "beg".}: ptr UncheckedArray[cint]
    ends* {.importc: "end".}: ptr UncheckedArray[cint]

  OnigError* = object of CatchableError

const
  OnigOptionNone*: OnigOptionType = 0
  OnigNormal = 0.cint
  OnigMismatch* = -1
  MaxErrorMessageLen = 90

var
  OnigEncodingUTF8 {.importc: "OnigEncodingUTF8", header: onigH.}: OnigEncodingType
  OnigSyntaxOniguruma {.importc: "OnigSyntaxOniguruma", header: onigH.}: OnigSyntaxType

proc onigInitialize(
  encodings: ptr OnigEncoding, numEncodings: cint
): cint {.importc: "onig_initialize", header: onigH, discardable.}

proc onigEnd(): cint {.importc: "onig_end", header: onigH, discardable.}

proc onigVersion(): cstring {.importc: "onig_version", header: onigH.}

proc onigNew(
  reg: ptr OnigRegex,
  pattern: ptr OnigUChar,
  patternEnd: ptr OnigUChar,
  option: OnigOptionType,
  enc: OnigEncoding,
  syntax: ptr OnigSyntaxType,
  einfo: ptr OnigErrorInfo,
): cint {.importc: "onig_new", header: onigH.}

proc onigFree(reg: OnigRegex) {.importc: "onig_free", header: onigH.}

proc onigSearch(
  reg: OnigRegex,
  str: ptr OnigUChar,
  strEnd: ptr OnigUChar,
  start: ptr OnigUChar,
  searchEnd: ptr OnigUChar,
  region: ptr OnigRegion,
  option: OnigOptionType,
): cint {.importc: "onig_search", header: onigH.}

proc onigRegionNew(): ptr OnigRegion {.importc: "onig_region_new", header: onigH.}

proc onigRegionFree(
  region: ptr OnigRegion, freeSelf: cint
) {.importc: "onig_region_free", header: onigH.}

proc onigErrorCodeToStr(
  s: ptr OnigUChar, errCode: cint
): cint {.importc: "onig_error_code_to_str", header: onigH, varargs.}

proc offsetPtr(p: ptr OnigUChar, n: int): ptr OnigUChar {.inline.} =
  cast[ptr OnigUChar](cast[uint](p) + n.uint)

proc basePtr(s: string): ptr OnigUChar {.inline.} =
  if s.len > 0:
    cast[ptr OnigUChar](unsafeAddr s[0])
  else:
    nil

proc onigVersionString*(): string =
  $onigVersion()

proc initOniguruma*() =
  ## Must be called once before compiling any pattern.
  var encs = [cast[OnigEncoding](addr OnigEncodingUTF8)]
  discard onigInitialize(addr encs[0], 1)

proc finalizeOniguruma*() =
  discard onigEnd()

proc errorMessage(code: cint, einfo: ptr OnigErrorInfo): string =
  var buf = newString(MaxErrorMessageLen)
  let n = onigErrorCodeToStr(cast[ptr OnigUChar](addr buf[0]), code, einfo)
  if n >= 0 and n <= MaxErrorMessageLen:
    buf.setLen(n)
  buf

proc compile*(pattern: string): OnigRegex =
  ## Compile `pattern` as UTF-8 with ONIG_SYNTAX_ONIGURUMA.
  var reg: OnigRegex
  var einfo: OnigErrorInfo
  let p = basePtr(pattern)
  let rc = onigNew(
    addr reg,
    p,
    offsetPtr(p, pattern.len),
    OnigOptionNone,
    cast[OnigEncoding](addr OnigEncodingUTF8),
    addr OnigSyntaxOniguruma,
    addr einfo,
  )
  if rc != OnigNormal:
    raise newException(
      OnigError,
      "onig_new failed for /" & pattern & "/: " & errorMessage(rc, addr einfo),
    )
  reg

proc free*(reg: OnigRegex) {.inline.} =
  onigFree(reg)

proc newRegion*(): ptr OnigRegion {.inline.} =
  onigRegionNew()

proc free*(region: ptr OnigRegion) {.inline.} =
  onigRegionFree(region, 1)

proc search*(
    reg: OnigRegex, subject: string, region: ptr OnigRegion, start: int = 0
): int {.inline.} =
  ## Forward search from byte offset `start`.  Returns the match start
  ## offset, or `OnigMismatch` (-1) when there is no match.  Capture spans
  ## are written into `region` (`beg[i]` / `ends[i]`).
  let base = basePtr(subject)
  let subjectEnd = offsetPtr(base, subject.len)
  onigSearch(
    reg, base, subjectEnd, offsetPtr(base, start), subjectEnd, region, OnigOptionNone
  ).int
