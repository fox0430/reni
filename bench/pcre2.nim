## Minimal FFI bindings to PCRE2 (8-bit), used by the benchmark harness as a
## calibration point next to reni and Oniguruma.
##
## Only compilation (with optional JIT), forward matching with a reusable
## match data block, and error reporting are bound.  Benchmark-only; not
## part of the reni package.

import std/strutils

const
  RawCflags = staticExec("pkg-config --cflags libpcre2-8 2>/dev/null")
  RawLibs = staticExec("pkg-config --libs libpcre2-8 2>/dev/null")
  Pcre2Cflags = RawCflags.strip()
  Pcre2Libs =
    if RawLibs.strip().len > 0:
      RawLibs.strip()
    else:
      "-lpcre2-8"

{.passC: "-DPCRE2_CODE_UNIT_WIDTH=8 " & Pcre2Cflags.}
{.passL: Pcre2Libs.}

const pcre2H = "<pcre2.h>"

type
  Pcre2Code* = distinct pointer
    ## Compiled pattern; distinct so it cannot be mixed up with match data.
  Pcre2MatchData* = distinct pointer
  Pcre2Size = csize_t

  Pcre2Error* = object of CatchableError

const
  Pcre2Utf = 0x00080000'u32
  Pcre2Ucp = 0x00020000'u32
    ## Unicode properties for \w, \d, \b — matches the semantics reni and
    ## Oniguruma use for a UTF-8 subject.
  Pcre2Multiline = 0x00000400'u32
    ## `^` / `$` as line anchors, which is Oniguruma's (and reni's) default.
  Pcre2NoUtfCheck = 0x40000000'u32
  Pcre2JitComplete = 0x00000001'u32
  Pcre2ErrorNoMatch* = -1
  Pcre2ConfigJit = 1'u32
  MaxErrorMessageLen = 256

proc pcre2Compile(
  pattern: ptr uint8,
  length: Pcre2Size,
  options: uint32,
  errorcode: ptr cint,
  erroroffset: ptr Pcre2Size,
  ccontext: pointer,
): Pcre2Code {.importc: "pcre2_compile_8", header: pcre2H.}

proc pcre2CodeFree(code: Pcre2Code) {.importc: "pcre2_code_free_8", header: pcre2H.}

proc pcre2JitCompile(
  code: Pcre2Code, options: uint32
): cint {.importc: "pcre2_jit_compile_8", header: pcre2H.}

proc pcre2MatchDataCreateFromPattern(
  code: Pcre2Code, gcontext: pointer
): Pcre2MatchData {.importc: "pcre2_match_data_create_from_pattern_8", header: pcre2H.}

proc pcre2MatchDataFree(
  data: Pcre2MatchData
) {.importc: "pcre2_match_data_free_8", header: pcre2H.}

proc pcre2Match(
  code: Pcre2Code,
  subject: ptr uint8,
  length: Pcre2Size,
  startoffset: Pcre2Size,
  options: uint32,
  matchData: Pcre2MatchData,
  mcontext: pointer,
): cint {.importc: "pcre2_match_8", header: pcre2H.}

proc pcre2GetOvectorPointer(
  matchData: Pcre2MatchData
): ptr UncheckedArray[Pcre2Size] {.
  importc: "pcre2_get_ovector_pointer_8", header: pcre2H
.}

proc pcre2GetErrorMessage(
  errorcode: cint, buffer: ptr uint8, bufflen: Pcre2Size
): cint {.importc: "pcre2_get_error_message_8", header: pcre2H.}

proc pcre2Config(
  what: uint32, where: pointer
): cint {.importc: "pcre2_config_8", header: pcre2H.}

proc basePtr(s: string): ptr uint8 {.inline.} =
  if s.len > 0:
    cast[ptr uint8](unsafeAddr s[0])
  else:
    nil

proc jitAvailable*(): bool =
  var supported: uint32 = 0
  discard pcre2Config(Pcre2ConfigJit, addr supported)
  supported == 1

proc errorMessage(code: cint): string =
  var buf = newString(MaxErrorMessageLen)
  let n = pcre2GetErrorMessage(code, cast[ptr uint8](addr buf[0]), buf.len.Pcre2Size)
  if n >= 0 and n <= buf.len:
    buf.setLen(n)
  buf

proc compile*(pattern: string, jit: bool): Pcre2Code =
  ## Compile `pattern` as UTF-8 with Unicode properties and line anchors
  ## enabled, matching Oniguruma's defaults.  When `jit` is true the pattern is
  ## also JIT-compiled, which `match` picks up automatically.
  var errorcode: cint
  var erroroffset: Pcre2Size
  result = pcre2Compile(
    basePtr(pattern),
    pattern.len.Pcre2Size,
    Pcre2Utf or Pcre2Ucp or Pcre2Multiline,
    addr errorcode,
    addr erroroffset,
    nil,
  )
  if cast[pointer](result) == nil:
    raise newException(
      Pcre2Error,
      "pcre2_compile failed for /" & pattern & "/ at offset " & $erroroffset & ": " &
        errorMessage(errorcode),
    )
  if jit:
    let rc = pcre2JitCompile(result, Pcre2JitComplete)
    if rc != 0:
      let msg = errorMessage(rc.cint)
      pcre2CodeFree(result)
      raise newException(Pcre2Error, "pcre2_jit_compile failed: " & msg)

proc free*(code: Pcre2Code) {.inline.} =
  pcre2CodeFree(code)

proc newMatchData*(code: Pcre2Code): Pcre2MatchData {.inline.} =
  pcre2MatchDataCreateFromPattern(code, nil)

proc free*(data: Pcre2MatchData) {.inline.} =
  pcre2MatchDataFree(data)

proc match*(
    code: Pcre2Code, subject: string, data: Pcre2MatchData, start: int = 0
): cint {.inline.} =
  ## Match at or after byte offset `start`.  Returns the PCRE2 status code
  ## (> 0 on success, `Pcre2ErrorNoMatch` when there is no match); spans are
  ## read from the ovector.
  pcre2Match(
    code,
    basePtr(subject),
    subject.len.Pcre2Size,
    start.Pcre2Size,
    Pcre2NoUtfCheck,
    data,
    nil,
  )

proc ovector*(data: Pcre2MatchData): ptr UncheckedArray[Pcre2Size] {.inline.} =
  pcre2GetOvectorPointer(data)
