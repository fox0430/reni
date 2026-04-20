## PCRE2 testoutput file parser
## Extracts pattern/subject/expected-result triples and outputs JSON test data.
##
## Usage: nim r tools/port_pcre2_tests.nim <testoutput_file>
## Output goes to stdout as JSON.

import std/[strutils, json, os]

type
  Pcre2TestKind = enum
    ptkMatch = "match"
    ptkNoMatch = "no_match"

  Pcre2CaptureGroup = object
    index: int
    value: string

  Pcre2TestCase = object
    kind: Pcre2TestKind
    pattern: string
    flags: string
    subject: string
    groups: seq[Pcre2CaptureGroup]
    line: int

proc toHex(s: string): string =
  result = ""
  for ch in s:
    result.add toHex(ord(ch), 2)

proc encodeUtf8(result: var string, cp: int) =
  ## Encode a Unicode code point as UTF-8 bytes.
  if cp <= 0x7F:
    result.add chr(cp)
  elif cp <= 0x7FF:
    result.add chr(0xC0 or (cp shr 6))
    result.add chr(0x80 or (cp and 0x3F))
  elif cp <= 0xFFFF:
    result.add chr(0xE0 or (cp shr 12))
    result.add chr(0x80 or ((cp shr 6) and 0x3F))
    result.add chr(0x80 or (cp and 0x3F))
  elif cp <= 0x10FFFF:
    result.add chr(0xF0 or (cp shr 18))
    result.add chr(0x80 or ((cp shr 12) and 0x3F))
    result.add chr(0x80 or ((cp shr 6) and 0x3F))
    result.add chr(0x80 or (cp and 0x3F))

proc expandSubjectRepeat(s: string): string =
  ## Expand pcre2test subject repeat syntax: \[text]{N} -> text repeated N times.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '[' and
        not (i > 0 and s[i - 1] == '\\'):
      let closeB = s.find(']', i + 2)
      if closeB > 0 and closeB + 1 < s.len and s[closeB + 1] == '{':
        let closeC = s.find('}', closeB + 2)
        if closeC > 0:
          let content = s[i + 2 ..< closeB]
          let countStr = s[closeB + 2 ..< closeC]
          try:
            let count = parseInt(countStr)
            if count >= 0:
              for _ in 0 ..< count:
                result.add content
              i = closeC + 1
              continue
          except ValueError:
            discard
    result.add s[i]
    inc i

proc unescapePcre2Subject(s: string, isUtf: bool = false): string =
  ## Unescape PCRE2 subject line escapes:
  ## \xHH -> byte, \x{HHHH} -> code point, \o{NNN} -> code point from octal,
  ## \N{U+HHHH} -> code point, \n \r \t \a \e \f \\ \NNN (octal byte)
  ## \[text]{N} -> repeat text N times.
  ## Non-alphanumeric escapes like \$ -> $ (backslash dropped).
  let s = expandSubjectRepeat(s)
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'x':
        if i + 2 < s.len and s[i + 2] == '{':
          let closePos = s.find('}', i + 3)
          if closePos > 0:
            let hexStr = s[i + 3 ..< closePos]
            if hexStr.len > 0 and hexStr.allCharsInSet(HexDigits):
              let cp = parseHexInt(hexStr)
              if cp <= 0xFF and not isUtf:
                result.add chr(cp)
              else:
                result.encodeUtf8(cp)
            i = closePos + 1
            continue
          else:
            result.add s[i]
            inc i
            continue
        else:
          var hexStr = ""
          var j = i + 2
          while j < s.len and s[j] in HexDigits and hexStr.len < 2:
            hexStr.add s[j]
            inc j
          if hexStr.len > 0:
            result.add chr(parseHexInt(hexStr) and 0xFF)
            i = j
            continue
          else:
            result.add s[i]
            inc i
            continue
      of 'o':
        if i + 2 < s.len and s[i + 2] == '{':
          let closePos = s.find('}', i + 3)
          if closePos > 0:
            let octalStr = s[i + 3 ..< closePos].strip
            if octalStr.len > 0:
              var cp = 0
              for ch in octalStr:
                if ch in {'0' .. '7'}:
                  cp = cp * 8 + (ord(ch) - ord('0'))
              if cp <= 0xFF and not isUtf:
                result.add chr(cp)
              else:
                result.encodeUtf8(cp)
            i = closePos + 1
            continue
        result.add s[i]
        inc i
        continue
      of 'N':
        if i + 2 < s.len and s[i + 2] == '{':
          let closePos = s.find('}', i + 3)
          if closePos > 0:
            let inner = s[i + 3 ..< closePos]
            if inner.startsWith("U+") and inner.len > 2:
              let hexStr = inner[2 ..^ 1]
              if hexStr.len > 0 and hexStr.allCharsInSet(HexDigits):
                let cp = parseHexInt(hexStr)
                if cp <= 0xFF and not isUtf:
                  result.add chr(cp)
                else:
                  result.encodeUtf8(cp)
              i = closePos + 1
              continue
        result.add s[i]
        inc i
        continue
      of '0' .. '7':
        var octalStr = ""
        var j = i + 1
        while j < s.len and s[j] in {'0' .. '7'} and octalStr.len < 3:
          octalStr.add s[j]
          inc j
        result.add chr(parseOctInt(octalStr) and 0xFF)
        i = j
        continue
      of 'n':
        result.add '\n'
        i += 2
        continue
      of 'r':
        result.add '\r'
        i += 2
        continue
      of 't':
        result.add '\t'
        i += 2
        continue
      of 'a':
        result.add '\x07'
        i += 2
        continue
      of 'e':
        result.add '\x1B'
        i += 2
        continue
      of 'f':
        result.add '\x0C'
        i += 2
        continue
      of '\\':
        result.add '\\'
        i += 2
        continue
      else:
        if not s[i + 1].isAlphaNumeric:
          result.add s[i + 1]
          i += 2
          continue
        else:
          result.add s[i]
          inc i
          continue
    else:
      result.add s[i]
      inc i

proc unescapePcre2Output(s: string, isUtf: bool = false): string =
  ## Unescape PCRE2 capture output values.
  ## pcre2test output prints matched text as-is for printable characters,
  ## and uses \xHH or \x{HHHH} for non-printable bytes. All other
  ## characters (including backslash) are literal.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == 'x':
      if i + 2 < s.len and s[i + 2] == '{':
        let closePos = s.find('}', i + 3)
        if closePos > 0:
          let hexStr = s[i + 3 ..< closePos]
          if hexStr.len > 0 and hexStr.allCharsInSet(HexDigits):
            let cp = parseHexInt(hexStr)
            if cp <= 0xFF and not isUtf:
              result.add chr(cp)
            else:
              result.encodeUtf8(cp)
          i = closePos + 1
          continue
      else:
        var hexStr = ""
        var j = i + 2
        while j < s.len and s[j] in HexDigits and hexStr.len < 2:
          hexStr.add s[j]
          inc j
        if hexStr.len > 0:
          let val = parseHexInt(hexStr) and 0xFF
          # pcre2test only uses \xHH for non-printable bytes in output;
          # printable \xHH (0x20..0x7E) is literal text, not an escape.
          if val < 0x20 or val > 0x7E:
            result.add chr(val)
            i = j
            continue
    result.add s[i]
    inc i

proc toJsonNode(tc: Pcre2TestCase): JsonNode =
  result = %*{
    "kind": $tc.kind,
    "pattern": toHex(tc.pattern),
    "flags": tc.flags,
    "subject": toHex(tc.subject),
    "line": tc.line,
  }
  if tc.kind == ptkMatch and tc.groups.len > 0:
    var groups = newJArray()
    for g in tc.groups:
      groups.add %*{"index": g.index, "value": toHex(g.value)}
    result["groups"] = groups

proc findClosingDelimiter(s: string, start: int = 1): int =
  ## Find the closing / respecting only backslash escapes.
  ## pcre2test does NOT track character classes for delimiter matching:
  ## / is always a delimiter even inside [...].
  var i = start
  var escaped = false
  while i < s.len:
    if escaped:
      escaped = false
      inc i
      continue
    if s[i] == '\\':
      escaped = true
      inc i
      continue
    if s[i] == '/':
      return i
    inc i
  return -1

proc splitSubjectModifiers(s: string): tuple[subject: string, modifiers: string] =
  ## Split "subject\=modifiers" into parts. The \= is the modifier separator.
  ## Must not be inside an escape sequence.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      if s[i + 1] == '=':
        result.subject = s[0 ..< i]
        result.modifiers = s[i + 2 .. ^1]
        return
      # Skip known escape sequences to avoid false matches
      i += 2
      continue
    inc i
  result.subject = s
  result.modifiers = ""

proc isCaptureOutputLine(line: string): bool =
  ## Check if a line is a capture output line: leading spaces + digits + ": "
  ## Format: " 0: text" or "10: text" (double-digit may have less leading space)
  if line.len < 3:
    return false
  var j = 0
  while j < line.len and line[j] == ' ':
    inc j
  if j == 0 and not line[0].isDigit:
    return false # Must have space or start with digit
  if j >= line.len or not line[j].isDigit:
    return false
  var numEnd = j
  while numEnd < line.len and line[numEnd].isDigit:
    inc numEnd
  if numEnd < line.len and line[numEnd] == ':' and numEnd + 1 < line.len and
      line[numEnd + 1] == ' ':
    let idxStr = line[j ..< numEnd]
    try:
      let idx = parseInt(idxStr)
      return idx <= 99
    except ValueError:
      return false
  # Also handle " N: " with empty value (colon at end or colon+space at end)
  if numEnd < line.len and line[numEnd] == ':':
    let idxStr = line[j ..< numEnd]
    try:
      let idx = parseInt(idxStr)
      return idx <= 99 and (numEnd + 1 >= line.len or line[numEnd + 1] == ' ')
    except ValueError:
      return false
  return false

proc parseCaptureOutput(line: string): Pcre2CaptureGroup =
  ## Parse a capture output line into index + value.
  var j = 0
  while j < line.len and line[j] == ' ':
    inc j
  var numEnd = j
  while numEnd < line.len and line[numEnd].isDigit:
    inc numEnd
  result.index = parseInt(line[j ..< numEnd])
  if numEnd + 2 < line.len:
    result.value = line[numEnd + 2 .. ^1] # skip ": "
  else:
    result.value = ""

proc isCalloutPositionLine(line: string): bool =
  ## Detect callout position output lines like "  0 ^  ^       d"
  ## and auto-callout lines like " ^          x" or "^^          x".
  ## These lines contain '^' as position markers with significant whitespace.
  let s = line.strip
  if s.len == 0:
    return false
  # Numbered callout lines: digit(s) + space (not ':') + contains '^'
  var j = 0
  while j < s.len and s[j].isDigit:
    inc j
  if j > 0 and j < s.len and s[j] == ' ' and '^' in s:
    return true
  # Auto-callout lines: start with '^' and have significant trailing whitespace
  # (e.g., "^          x" or "^^          x")
  if s[0] == '^' and s.len >= 3:
    # Count spaces: callout markers have lots of spaces between ^ and the suffix
    var spaceCount = 0
    for ch in s:
      if ch == ' ':
        inc spaceCount
    if spaceCount >= 4:
      return true
  return false

proc isAftertextLine(line: string): bool =
  ## Detect aftertext output lines like " 0+ rest of text" or " 0+ " (empty text).
  ## Format: leading spaces + small group number (0-99) + '+' + space or end.
  ## The group number limit avoids false positives on subjects like "12345+".
  if line.len == 0 or line[0] != ' ':
    return false # must have leading space
  let s = line.strip
  if s.len == 0:
    return false
  var j = 0
  while j < s.len and s[j].isDigit:
    inc j
  if j > 0 and j <= 2 and j < s.len and s[j] == '+':
    # Group number is 0-99 (1-2 digits); followed by space or end of string
    return j + 1 >= s.len or s[j + 1] == ' '
  return false

proc isSubstituteOutputLine(s: string): bool =
  ## Detect substitute output lines like "1(1) Old 1 4 "abc" New 1 2 "Z""
  ## Format: digit(s) + '(' + digit(s) + ')' + ' Old '
  if s.len < 10:
    return false
  var j = 0
  while j < s.len and s[j].isDigit:
    inc j
  if j == 0 or j >= s.len or s[j] != '(':
    return false
  inc j
  while j < s.len and s[j].isDigit:
    inc j
  if j >= s.len or s[j] != ')':
    return false
  inc j
  return j + 4 < s.len and s[j .. j + 4] == " Old "

proc isKnownOutputLine(line: string): bool =
  ## Lines that are pcre2test output, not subject lines.
  let s = line.strip
  s.startsWith("No match") or s == "Partial match" or s.startsWith("Error") or
    s.startsWith("Failed") or s.startsWith("Matched, but") or
    s.startsWith("Start of matched string") or s.startsWith("Callout") or
    s.startsWith("--->") or # callout pointer lines
  s.startsWith("Copy ") or s.startsWith("Get ") or s.startsWith("List:") or
    s.startsWith(" L ") or # mark lines
  s.startsWith("global repeat") or # global repeat warnings
  s.startsWith("MK:") or (s.len > 0 and s[0] == '+') or # continuation indicator
  isCalloutPositionLine(line) or isSubstituteOutputLine(s) # substitute_skip output

proc main() =
  if paramCount() < 1:
    echo "Usage: port_pcre2_tests <testoutput_file>"
    quit(1)

  let inputFile = paramStr(1)
  let lines = readFile(inputFile).splitLines

  var tests = newJArray()
  var i = 0
  var currentPattern = ""
  var currentFlags = ""
  var patternLine = 0
  var expectNoMatch = false
  var skipBlock = false
  var skipDepth = 0

  while i < lines.len:
    let line = lines[i]
    let stripped = line.strip

    # Skip empty lines - reset expect-no-match on blank line
    if stripped.len == 0:
      expectNoMatch = false
      i += 1
      continue

    # Handle directives (lines starting with #)
    if stripped.startsWith("#"):
      if stripped.startsWith("#if"):
        if skipBlock:
          inc skipDepth
        elif "ebcdic" in stripped and "!" notin stripped:
          skipBlock = true
          skipDepth = 1
      elif stripped.startsWith("#endif"):
        if skipBlock:
          dec skipDepth
          if skipDepth <= 0:
            skipBlock = false
            skipDepth = 0
      # Skip #subject, #pattern, #newline_default, #perltest, #forbid_utf etc.
      i += 1
      continue

    if skipBlock:
      i += 1
      continue

    # Pattern line: starts with /
    if stripped.len > 0 and stripped[0] == '/':
      let closePos = findClosingDelimiter(stripped, 1)
      if closePos >= 0:
        currentPattern = stripped[1 ..< closePos]
        currentFlags = stripped[closePos + 1 .. ^1].strip
        patternLine = i + 1
        expectNoMatch = false
        i += 1
      else:
        # Multi-line pattern
        currentPattern = stripped[1 .. ^1]
        patternLine = i + 1
        expectNoMatch = false
        i += 1
        while i < lines.len:
          let contLine = lines[i]
          let cp = findClosingDelimiter(contLine, 0)
          if cp >= 0:
            currentPattern.add "\n" & contLine[0 ..< cp]
            currentFlags = contLine[cp + 1 .. ^1].strip
            i += 1
            break
          else:
            currentPattern.add "\n" & contLine
            i += 1
      continue

    # "\= Expect no match" marker
    if stripped.startsWith("\\= Expect no match"):
      expectNoMatch = true
      i += 1
      continue

    # Other \= directives (skip)
    if stripped.startsWith("\\="):
      i += 1
      continue

    # Known output lines to skip
    if isKnownOutputLine(stripped):
      i += 1
      continue

    # Aftertext output line (outside of subject context - skip)
    if isAftertextLine(line):
      i += 1
      continue

    # Capture output line (outside of subject context - skip)
    if isCaptureOutputLine(line):
      i += 1
      continue

    # Subject line: starts with spaces (typically 4) and we have a current pattern
    if line.len > 0 and line[0] == ' ' and currentPattern.len > 0:
      let rawSubject = line.strip

      # Split subject from inline modifiers (\=offset=5 etc.)
      let (subjectPart, subjectModifiers) = splitSubjectModifiers(rawSubject)
      let flagsUtf = "utf" in currentFlags
      let subject = unescapePcre2Subject(subjectPart, isUtf = flagsUtf)

      i += 1

      if expectNoMatch:
        let tc = Pcre2TestCase(
          kind: ptkNoMatch,
          pattern: currentPattern,
          flags: currentFlags,
          subject: subject,
          line: patternLine,
        )
        tests.add tc.toJsonNode()
        # Skip following "No match" line
        if i < lines.len and lines[i].strip.startsWith("No match"):
          i += 1
      else:
        # Expect match - parse capture group output lines
        let isReplace = "replace=" in currentFlags or "replace=" in subjectModifiers
        var groups: seq[Pcre2CaptureGroup]
        var inCalloutBlock = false
        while i < lines.len:
          # Skip known non-capture output lines between subject and captures
          if isKnownOutputLine(lines[i].strip):
            # Track whether we're inside a callout output block;
            # capture lines after "Callout N:" are snapshots, not results
            inCalloutBlock =
              lines[i].strip.startsWith("Callout") or lines[i].strip.startsWith("--->")
            i += 1
            continue
          # Aftertext line (N+ text) ends the current match's capture groups
          if isAftertextLine(lines[i]):
            break
          if isCaptureOutputLine(lines[i]):
            if inCalloutBlock:
              # Capture lines inside callout blocks are snapshots, not final results
              i += 1
              continue
            inCalloutBlock = false
            if isReplace:
              # In replace mode, capture lines show replacement results
              # and ovector values, not actual match groups - skip all
              i += 1
              continue
            let g = parseCaptureOutput(lines[i])
            # Skip <unchanged> (allvector metadata, not a real capture)
            if g.value == "<unchanged>":
              i += 1
              continue
            # Duplicate group index means start of next global match - stop
            var isDup = false
            for prev in groups:
              if prev.index == g.index:
                isDup = true
                break
            if isDup:
              break
            let val =
              if g.value == "<unset>":
                g.value
              else:
                unescapePcre2Output(g.value, isUtf = flagsUtf)
            groups.add Pcre2CaptureGroup(index: g.index, value: val)
            i += 1
          else:
            break

        if groups.len > 0:
          let tc = Pcre2TestCase(
            kind: ptkMatch,
            pattern: currentPattern,
            flags: currentFlags,
            subject: subject,
            groups: groups,
            line: patternLine,
          )
          tests.add tc.toJsonNode()
      continue

    # Skip unrecognized lines
    i += 1

  let output =
    %*{"source": inputFile.extractFilename, "count": tests.len, "tests": tests}

  echo output.pretty

when isMainModule:
  main()
