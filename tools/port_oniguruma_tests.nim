## Oniguruma C test file parser
## Extracts x2/x3/n/e macro calls and outputs JSON test data.
##
## Usage: nim r tools/port_oniguruma_tests.nim <input.c> [--backward]
## Output goes to stdout as JSON.

import std/[strutils, parseutils, json, os, sequtils]

type
  TestKind = enum
    tkMatch = "x2" # x2(pattern, string, from, to) - match test
    tkCapture = "x3" # x3(pattern, string, from, to, mem) - capture group test
    tkNoMatch = "n" # n(pattern, string) - no match test
    tkError = "e" # e(pattern, string, error_name) - error test

  TestCase = object
    kind: TestKind
    pattern: string # Raw regex pattern (C string unescaped)
    subject: string # Raw subject string (C string unescaped)
    fromPos: int
    toPos: int
    mem: int # capture group index (for x3)
    errorName: string # ONIGERR_* name (for e)
    line: int # source line number

proc parseCString(s: string, pos: var int): string =
  ## Parse a C string literal starting at pos (which should point to opening quote).
  ## Returns the raw bytes as the C compiler would interpret them.
  ## Regex-level escapes (like \\d in C source = \d for regex) are preserved.
  if pos >= s.len or s[pos] != '"':
    raise newException(ValueError, "Expected '\"' at pos " & $pos & " in: " & s)
  inc pos # skip opening quote

  result = ""
  while pos < s.len and s[pos] != '"':
    if s[pos] == '\\':
      inc pos
      if pos >= s.len:
        raise newException(ValueError, "Unexpected end after backslash in: " & s)
      case s[pos]
      of '\\':
        result.add '\\'
        inc pos
      of '"':
        result.add '"'
        inc pos
      of '\'':
        result.add '\''
        inc pos
      of '?':
        result.add '?'
        inc pos
      of 'n':
        result.add '\n'
        inc pos
      of 't':
        result.add '\t'
        inc pos
      of 'r':
        result.add '\r'
        inc pos
      of 'b':
        result.add '\x08'
        inc pos
      # backspace
      of 'a':
        result.add '\x07'
        inc pos
      of 'e':
        result.add '\x1B'
        inc pos
      of 'f':
        result.add '\x0C'
        inc pos
      of 'v':
        result.add '\x0B'
        inc pos
      of '0' .. '7':
        # Octal escape: 1-3 digits
        var octalStr = ""
        while pos < s.len and s[pos] in {'0' .. '7'} and octalStr.len < 3:
          octalStr.add s[pos]
          inc pos
        let val = parseOctInt(octalStr)
        result.add chr(val and 0xFF)
      of 'x':
        inc pos
        # Hex escape: \xHH... (1+ hex digits, C is greedy but we cap at 2 for char)
        var hexStr = ""
        while pos < s.len and s[pos] in HexDigits and hexStr.len < 2:
          hexStr.add s[pos]
          inc pos
        if hexStr.len > 0:
          let val = parseHexInt(hexStr)
          result.add chr(val and 0xFF)
        else:
          # \x with no hex digits - output literally
          result.add "\\x"
      else:
        # Unknown escape, output literally (backslash + char)
        result.add '\\'
        result.add s[pos]
        inc pos
    else:
      result.add s[pos]
      inc pos

  if pos < s.len and s[pos] == '"':
    inc pos # skip closing quote
  else:
    raise newException(ValueError, "Unterminated string in: " & s)

proc skipWhitespace(s: string, pos: var int) =
  while pos < s.len and s[pos] in {' ', '\t'}:
    inc pos

proc skipComma(s: string, pos: var int) =
  skipWhitespace(s, pos)
  if pos < s.len and s[pos] == ',':
    inc pos
  skipWhitespace(s, pos)

proc parseInt(s: string, pos: var int): int =
  skipWhitespace(s, pos)
  var negative = false
  if pos < s.len and s[pos] == '-':
    negative = true
    inc pos
  var numStr = ""
  while pos < s.len and s[pos] in {'0' .. '9'}:
    numStr.add s[pos]
    inc pos
  if numStr.len == 0:
    raise newException(ValueError, "Expected integer at pos " & $pos & " in: " & s)
  result = parseint(numStr)
  if negative:
    result = -result

proc parseIdent(s: string, pos: var int): string =
  skipWhitespace(s, pos)
  result = ""
  while pos < s.len and s[pos] in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
    result.add s[pos]
    inc pos

type NumberedLine = object
  text: string
  lineNo: int # 1-based original line number

proc joinContinuationLines(lines: seq[string]): seq[NumberedLine] =
  ## Handle macro calls that span multiple lines (string concatenation via
  ## adjacent string literals or explicit line continuation).
  ## Returns lines with their original 1-based line numbers.
  result = @[]
  var i = 0
  while i < lines.len:
    let origLineNo = i + 1 # 1-based
    var line = lines[i]
    # Handle line continuation with backslash
    while line.endsWith("\\") and i + 1 < lines.len:
      line = line[0 ..^ 2] # remove trailing backslash
      i += 1
      line.add lines[i].strip
    # Handle incomplete macro calls (missing closing paren)
    let stripped = line.strip
    if stripped.len > 0 and (
      stripped.startsWith("x2(") or stripped.startsWith("x3(") or
      stripped.startsWith("n(") or stripped.startsWith("e(")
    ):
      var accumulated = stripped
      var parenDepth = 0
      var inStr = false
      var escaped = false
      for ch in accumulated:
        if escaped:
          escaped = false
          continue
        if ch == '\\' and inStr:
          escaped = true
          continue
        if ch == '"':
          inStr = not inStr
          continue
        if not inStr:
          if ch == '(':
            inc parenDepth
          elif ch == ')':
            dec parenDepth
      while parenDepth > 0 and i + 1 < lines.len:
        i += 1
        let nextLine = lines[i].strip
        accumulated.add " " & nextLine
        parenDepth = 0
        inStr = false
        escaped = false
        for ch in accumulated:
          if escaped:
            escaped = false
            continue
          if ch == '\\' and inStr:
            escaped = true
            continue
          if ch == '"':
            inStr = not inStr
            continue
          if not inStr:
            if ch == '(':
              inc parenDepth
            elif ch == ')':
              dec parenDepth
        line = accumulated
    result.add NumberedLine(text: line, lineNo: origLineNo)
    i += 1

proc parseMacroCall(line: string, lineNo: int): TestCase =
  let stripped = line.strip
  var pos = 0

  # Detect which macro
  var kind: TestKind
  if stripped.startsWith("x2("):
    kind = tkMatch
    pos = 3
  elif stripped.startsWith("x3("):
    kind = tkCapture
    pos = 3
  elif stripped.startsWith("n("):
    kind = tkNoMatch
    pos = 2
  elif stripped.startsWith("e("):
    kind = tkError
    pos = 2
  else:
    raise newException(ValueError, "Unknown macro at line " & $lineNo & ": " & stripped)

  # Handle string concatenation: "abc" "def" -> "abcdef"
  proc parseConcatString(s: string, p: var int): string =
    skipWhitespace(s, p)
    result = parseCString(s, p)
    # Check for adjacent string literals (C string concatenation)
    while true:
      var saved = p
      skipWhitespace(s, saved)
      if saved < s.len and s[saved] == '"':
        p = saved
        result.add parseCString(s, p)
      else:
        break

  let pattern = parseConcatString(stripped, pos)
  skipComma(stripped, pos)
  let subject = parseConcatString(stripped, pos)

  result = TestCase(kind: kind, pattern: pattern, subject: subject, line: lineNo)

  case kind
  of tkMatch:
    skipComma(stripped, pos)
    result.fromPos = parseInt(stripped, pos)
    skipComma(stripped, pos)
    result.toPos = parseInt(stripped, pos)
  of tkCapture:
    skipComma(stripped, pos)
    result.fromPos = parseInt(stripped, pos)
    skipComma(stripped, pos)
    result.toPos = parseInt(stripped, pos)
    skipComma(stripped, pos)
    result.mem = parseInt(stripped, pos)
  of tkNoMatch:
    discard
  of tkError:
    skipComma(stripped, pos)
    result.errorName = parseIdent(stripped, pos)

proc toHex(s: string): string =
  ## Encode a string as hex bytes for safe JSON transport (avoids invalid UTF-8).
  result = ""
  for ch in s:
    result.add toHex(ord(ch), 2)

proc toJsonNode(tc: TestCase): JsonNode =
  result = %*{
    "kind": $tc.kind,
    "pattern": toHex(tc.pattern),
    "subject": toHex(tc.subject),
    "line": tc.line,
  }
  case tc.kind
  of tkMatch:
    result["from"] = %tc.fromPos
    result["to"] = %tc.toPos
  of tkCapture:
    result["from"] = %tc.fromPos
    result["to"] = %tc.toPos
    result["mem"] = %tc.mem
  of tkNoMatch:
    discard
  of tkError:
    result["error"] = %tc.errorName

proc isMacroLine(line: string): bool =
  let s = line.strip
  # Remove line comments first
  s.startsWith("x2(") or s.startsWith("x3(") or s.startsWith("n(") or s.startsWith("e(")

proc main() =
  if paramCount() < 1:
    echo "Usage: port_oniguruma_tests <input.c> [--backward]"
    quit(1)

  let inputFile = paramStr(1)
  let backward = paramCount() >= 2 and paramStr(2) == "--backward"

  let rawLines = readFile(inputFile).splitLines
  let lines = joinContinuationLines(rawLines)

  var tests = newJArray()

  for nl in lines:
    let lineNo = nl.lineNo
    let line = nl.text

    # Strip comments from end of line (not inside strings)
    var cleanLine = line
    var inStr = false
    var escaped = false
    var commentStart = -1
    for j, ch in line:
      if escaped:
        escaped = false
        continue
      if ch == '\\' and inStr:
        escaped = true
        continue
      if ch == '"':
        inStr = not inStr
        continue
      if not inStr and ch == '/' and j + 1 < line.len and line[j + 1] == '/':
        commentStart = j
        break
    if commentStart >= 0:
      cleanLine = line[0 ..< commentStart]

    if not isMacroLine(cleanLine):
      continue

    try:
      let tc = parseMacroCall(cleanLine, lineNo)
      tests.add tc.toJsonNode()
    except ValueError as e:
      # Output parsing failures as comments for debugging
      stderr.writeLine "WARNING: Failed to parse line " & $lineNo & ": " & e.msg

  let output = %*{
    "source": inputFile.extractFilename,
    "backward": backward,
    "count": tests.len,
    "tests": tests,
  }

  echo output.pretty

when isMainModule:
  main()
