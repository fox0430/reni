## What ``import reni`` alone gives a caller, and what it does not.
##
## This is the only test that imports nothing below the package module, so it
## sees the library the way user code does; adding an import would defeat it.
## The positive half is the README's usage section, so the two cannot drift
## apart silently; the negative half pins the internals as reachable through
## ``reni/types`` and not through ``reni``.

import std/[options, sequtils, strutils, unittest]

import reni

suite "the public API is what the README documents":
  test "search reports the whole match and each group":
    let m = search("hello world", re("(\\w+)\\s(\\w+)"))
    check m.found
    check m.boundaries[0] == 0 .. 11
    check m.boundaries[1] == 0 .. 5
    check m.boundaries[2] == 6 .. 11

  test "named captures are read back by name":
    let r = re("(?<user>\\w+)@(?<host>\\w+)")
    let m = search("user@host", r)
    check m.found
    check captureText(m, "user", "user@host", r) == some("user")
    check captureText(m, "host", "user@host", r) == some("host")
    check captureIndex(r, "host") == 2
    check r.captureCount == 2
    check r.namedCaptures.len == 2
    check r.pattern == "(?<user>\\w+)@(?<host>\\w+)"

  test "matchAt anchors at a position":
    let m = matchAt("abcabc", re("abc"), pos = 3)
    check m.found
    check m.boundaries[0] == 3 .. 6

  test "searchBackward finds the last match":
    let m = searchBackward("abcabc", re("abc"))
    check m.found
    check m.boundaries[0] == 3 .. 6

  test "findAll walks every match":
    check toSeq(findAll("ab12cd34", re("\\d+"))).len == 2

  test "replace takes a template or a callback":
    check replace("2025-04-05", re("(\\d+)-(\\d+)-(\\d+)"), "$2/$3/$1") == "04/05/2025"
    check replace(
      "hello",
      re("\\w+"),
      proc(m: Match, s: string): string =
        let b = m.boundaries[0]
        s[b.a].toUpperAscii & s[b.a + 1 ..< b.b],
    ) == "Hello"

  test "split keeps what the groups captured":
    check split("a,b,,c", re(",")) == @["a", "b", "", "c"]
    check split("a1b2c", re("(\\d)")) == @["a", "1", "b", "2", "c"]

  test "a step limit is reported as RegexLimitError":
    expect RegexLimitError:
      discard search("aaaaaaaaaaaaaaaaaaaaaaaaab", re("(a+)+$"), stepLimit = 1000)

  test "a bad pattern is reported as RegexError":
    expect RegexError:
      discard re("(")

  test "flags reach the caller as a set":
    let r = re("a", {rfIgnoreCase})
    check rfIgnoreCase in r.flags
    check search("A", r).found

  test "a span compares against a slice and prints":
    check span(1, 3) == 1 .. 3
    check $span(1, 3) == "1 .. 3"
    check UnsetSpan.a < 0

  test "the step and recursion limits are named constants":
    check DefaultStepLimit > 0
    check DefaultMaxRecursionDepth > 0

  test "a caller-owned MatchContext is reusable across searches":
    let ctx = newMatchContext()
    var m: Match
    searchIntoCtx(ctx, "abcabc", re("b"), m)
    check m.matchSpan == 1 .. 2
    searchIntoCtx(ctx, "abcabc", re("c"), m)
    check m.matchSpan == 2 .. 3

suite "the internals are not part of that API":
  # Each of these is reachable by importing ``reni/types`` -- which is how
  # ``test_parser`` inspects a tree -- and unreachable from here. The point is
  # not secrecy; it is that changing them is not an API change.
  test "the AST type and its kinds are not exported":
    check not declared(Node)
    check not declared(NodeKind)
    check not declared(NodeId)
    check not declared(childNodes)

  test "the accessors that hand out the compiled tree are not exported":
    let r = re("a")
    check not compiles(r.ast)
    check not compiles(r.nodes)
    check not compiles(r.groupBodies)
    check not compiles(r.leadRun)
    check not compiles(r.groupFlags)

  test "the compiled flags cannot be changed from outside":
    # ``flags`` was a public field once, so ``r.flags = ...`` compiled -- and
    # left the flags disagreeing with ``firstCharInfo`` / ``literalScan`` /
    # ``requiredByte``, which were computed from them at compile time. The
    # pattern below then reported ``rfIgnoreCase`` while still not matching
    # "ABC". Reading them is still part of the API.
    var r = re("abc")
    check not compiles(r.flags = r.flags + {rfIgnoreCase})
    check rfIgnoreCase notin r.flags
    check search("ABC", re("abc", {rfIgnoreCase})).found

  test "the per-group flags cannot be cleared from outside":
    # They were a public field once, so ``r.groupFlags = @[]`` compiled. The
    # matcher reads the seq under a bounds check, so clearing it did not
    # crash: a call into a group just stopped restoring the flags the group
    # was defined under, and the pattern below quietly stopped matching "aA".
    var r = re("(?i)(a)(?-i)\\g<1>")
    check not compiles(r.groupFlags = @[])
    check search("aA", r).found

  test "the passes that build a Regex are not exported":
    check not declared(initRegex)
    check not declared(numberNodes)
    check not declared(resolveNameRefs)

  test "the matcher's own analyses and tables are not exported":
    check not declared(lengthBounds)
    check not declared(extractFirstChar)
    check not declared(AsciiClassTable)
    check not declared(PosixClassName)

suite "the README's export list is the whole export list":
  # The tests above call most of what the README promises, but not all of it:
  # the scanner and several accessors were listed and never named, so dropping
  # their export broke a user's build and nothing here. Each name below is
  # touched for its mere existence, which is what the list actually claims.
  template mustExport(name: untyped) =
    checkpoint astToStr(name)
    check declared(name)

  # ``declared`` only asks whether *some* symbol of that name is in scope, so a
  # name an imported std module also exports passes on that module's symbol
  # alone and pins nothing here.  Such a name is pinned by a call only reni's
  # overload can take.
  template mustExportCall(call: untyped) =
    checkpoint astToStr(call)
    check compiles(call)

  test "compiling a pattern":
    mustExport re
    mustExport Regex
    mustExport RegexFlag
    mustExport RegexFlags
    mustExport pattern
    mustExport flags
    mustExport captureCount
    mustExport namedCaptures
    mustExport captureIndex

  test "running one":
    mustExport search
    mustExport searchBackward
    mustExport matchAt
    mustExport findAll
    mustExportCall replace("a", re("a"), "b")
    mustExportCall split("a", re("a"))
    mustExport searchIntoCtx
    mustExport searchBackwardIntoCtx
    mustExport matchAtIntoCtx
    mustExport MatchContext
    mustExport newMatchContext
    mustExport MatchScanner
    mustExport initMatchScanner
    mustExport scanPos
    mustExport scanNext
    mustExport takeGap
    mustExport takeTail

  test "reading a result":
    mustExport Match
    mustExport matchSpan
    mustExport captureSpan
    mustExport captureText
    mustExport captured
    mustExport groupCount
    mustExport consumedSpan
    mustExport Span
    mustExport span
    mustExport UnsetSpan

  test "the Match fields the README names":
    let m = search("abc", re("b"))
    check m.found
    check m.boundaries.len == 1
    check m.startChar == 1

  test "walking a subject by hand":
    mustExport nextRunePos
    # ``advanceAfterMatch`` is deprecated, so it is named rather than called.
    mustExport advanceAfterMatch

  test "limits and errors":
    mustExport DefaultStepLimit
    mustExport DefaultMaxRecursionDepth
    mustExport RegexError
    mustExport RegexLimitError
