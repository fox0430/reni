# reni

A **re**gular expression engine compatible with O**ni**guruma

A pure Nim regex engine that replicates the syntax and semantics of [Oniguruma](https://github.com/kkos/oniguruma).

This project aims to implement a tmLanguage parser.

## Features

- Capture groups (numbered and named)
- Backreferences and named backreferences with recursion-level support
- Lookaround assertions (lookahead, lookbehind, negative variants)
- Atomic groups `(?>...)`
- Conditionals `(?(cond)yes|no)`
- Subexpression calls `\g<name>`, `\g<n>`
- Absent operator `(?~...)`
- POSIX character classes, and every Unicode property Oniguruma names in
  `\p{...}`: general categories, scripts, blocks and binary properties
- Greedy, lazy, and possessive quantifiers
- Grapheme cluster mode `(?y{g})`, word mode `(?y{w})`
- Flags: `(?i)`, `(?m)`, `(?x)`, `(?W)`, `(?D)`, `(?S)`, `(?P)`, `(?I)`, `(?L)`
- ReDoS protection via step limit

## Requirements

- Nim >= 2.0.2

## Usage

### Search

```nim
import pkg/reni

let m = search("hello world", re("(\\w+)\\s(\\w+)"))
assert m.found
assert m.boundaries[0] == 0 .. 11  # full match
assert m.boundaries[1] == 0 .. 5   # group 1
assert m.boundaries[2] == 6 .. 11  # group 2
```

### Named captures

```nim
import std/options

let r = re("(?<user>\\w+)@(?<host>\\w+)")
let m = search("user@host", r)
assert m.found
assert captureText(m, "user", "user@host", r) == some("user")
assert captureText(m, "host", "user@host", r) == some("host")
```

By default, a pattern containing named groups captures only those groups and
rejects numbered references, as Oniguruma does. TextMate uses
`ONIG_OPTION_CAPTURE_GROUP` instead. Pass `rfCaptureGroup` to keep both kinds
of captures in opening-parenthesis order and allow numbered backreferences,
subexpression calls, and conditionals alongside named ones:

```nim
let r = re(r"(a)(?<name>b)\1\k<name>", {rfCaptureGroup})
let m = search("abab", r)
assert m.boundaries == @[span(0, 4), span(0, 1), span(1, 2)]
assert captureIndex(r, "name") == 2
```

This is a compile option, with no inline flag spelling. Numeric references
can address individual groups even when several groups share a name.

### Per-call anchor options

`search`, `searchBackward`, `matchAt`, and their `IntoCtx` variants accept
`options: MatchOptions`. `moNotBeginString` disables `\A` and
`moNotBeginPosition` disables `\G`, including inside lookarounds and
subexpression calls. They correspond to Oniguruma's `NOT_BEGIN_STRING` and
`NOT_BEGIN_POSITION` options. Line anchors and other alternatives remain
available. Options apply only to the current call and reset when omitted.

```nim
let r = re(r"\Gx|y")
assert search(">xy", r, start = 1).matchSpan == 1 .. 2
assert search(">xy", r, start = 1,
  options = {moNotBeginPosition}).matchSpan == 2 .. 3
```

This lets a line tokenizer share one compiled pattern across anchor modes.
See [the TextMate benchmark](bench/README.md#textmate-captures-and-anchor-options)
for a comparison with separately compiled variants.

### Line mode

Compile with `rfLineMode` to search a buffer of lines the way grep does: each
line, without its `\n`, is matched as a subject of its own, and positions are
reported in the whole buffer.

- No match holds a `\n`, so `\s` and `[^x]` stop at the end of the line.
- `\A` and `^` hold at the start of a line, and `\z`, `\Z` and `$` at its
  end.
- Look-arounds do not see past the line, nor past a byte that is not
  well-formed UTF-8. So `(?!.)` holds before such a byte, where `$` does not.
- A byte that is not well-formed UTF-8 is matched by nothing, as in rg, so
  no match holds one. It is no edge of the line: `^`, `\A`, `$`, `\z` and
  `\Z` hold beside one only at the line's own start or end. `\b` reads it
  as a non-word side, and `\B` does not hold beside it. After stray
  continuation bytes, as in rg, both read the character before those bytes
  when it and they fit in four bytes: up to three such bytes after an ASCII
  character, two after a 2-byte one, one after a 3-byte one and none after a
  4-byte one.
  Under `(?W)` or `(?P)` the byte is simply a non-word side, and `\B` holds
  wherever `\b` does not. `\y` holds on both sides of it, where a
  character or cluster ends or begins, and `\Y` on neither.
- A position you pass (`start`, `pos`) must be a character boundary. From
  inside a character, its remaining bytes may match.
- A final `\n` ends the last line; it does not begin an empty one.
- `moNotBeginString` disables `\A` only in the line at offset 0, the one
  that begins the buffer. `moNotBeginPosition` disables `\G` only in the
  line holding `start`.

```nim
let r = re(r"(\w+\s+){2}\w+\(", {rfLineMode})
assert search("a b\nc(\nd e f(", r).matchSpan == 7 .. 13
```

One search covers the whole buffer. A forward search skips lines that lack a
byte every match needs, or a few in a row, without searching them; a backward
search searches each line from `start` back. A pattern that spells out a newline, such as
`\n`, `\x0a` or `[\n]`, raises `RegexError` under this flag. A class that
also holds other characters, such as `[\na]`, is allowed. The step budget
counts the whole call, not each line. Under a pattern whose matches all end
with their line, such as `(a+)+$`, both searches also skip a line whose last
byte no match ends with, and so cannot run into the step limit in it. `matchAt`
always makes its attempt, and can. Scan with `findAll` or a
`MatchScanner`: they keep the line they are in. A loop of `searchIntoCtx`,
`searchBackwardIntoCtx` or `matchAtIntoCtx` reads to both ends of the line
holding its position on every call, so walking one long line that way takes
quadratic time. Such a loop also cannot step past an empty match with
`nextRunePos`: past a malformed lead byte it steps the length that byte
declares, and skips the starts inside, the start of the next line among them.

Add `rfCrlf` for files with `\r\n` line ends. A `\r` that is the last byte
of a line, before its `\n` or at the end of the buffer, is then left out of
the line. So `foo$` matches `foo\r\n`, and `a.` does not. A `\r` inside a
line is an ordinary character. The pattern may not spell a `\r`, such as
`\r` or `[\r]`. `rfCrlf` without `rfLineMode` raises `RegexError`.

```nim
let crlf = re(r"\w+$", {rfLineMode, rfCrlf})
assert search("ab\r\ncd\r\n", crlf).matchSpan == 0 .. 2
```

### Word edges and smart case

Two more compile options read a pattern the way grep users type it.

`rfWordBeginEnd` reads `\<` as the start of a word and `\>` as its end, as
GNU grep and rg do. `\<` holds where a word character follows and none
precedes. `\>` holds where one precedes and none follows. A word character
is what `\w` matches, and `(?W)` or `(?P)` makes both ASCII-only. Without the option, `\<`
and `\>` are a literal `<` and `>`, as in Oniguruma's own syntax. Inside a
bracket class they are literals either way. This is Oniguruma's
`ONIG_SYN_OP_ESC_LTGT_WORD_BEGIN_END`.

```nim
assert search("a foo", re(r"\<foo\>", {rfWordBeginEnd})).matchSpan == 2 .. 5
```

`rfSmartCase` folds case when the pattern holds a literal and no uppercase
one, as rg's `--smart-case` does. A literal is a character the pattern
writes out, either plainly or as an escape such as `\x41`. Inside a bracket
class, characters and both ends of a range count too. Class escapes, Unicode
properties and POSIX classes are not literals, so `\p{Lu}foo` folds. A
pattern with no literal at all, such as `^\p{Ll}+$`, does not fold.
Uppercase means the Unicode `Uppercase` property. A UTF-8 byte sequence
such as `\xC3\xA9` counts as the one character it encodes, here the
lowercase `é`, so it folds; rg reads `\xC3` as `Ã` and does not. The `\M`
of Oniguruma's `\M-x` is no literal either. Without `rfWordBeginEnd`,
`\<` and `\>` are the literals `<` and `>` and count as such, while rg
always reads them as word edges, so a grep front end should pass both
options. An inline `(?-i)` still
turns folding off where it applies. When the option folds, the compiled
`Regex` has `rfIgnoreCase` in its `flags`.

```nim
assert search("FOO", re("foo", {rfSmartCase})).found
assert not search("FOO", re("Foo", {rfSmartCase})).found
```

### Match at position

```nim
let m = matchAt("abcabc", re("abc"), pos = 3)
assert m.found
assert m.boundaries[0] == 3 .. 6
```

### Find all

```nim
import std/sequtils

let matches = toSeq(findAll("ab12cd34", re("\\d+")))
assert matches.len == 2
```

### Replace

```nim
# Template replacement ($0, $1, ${name})
assert replace("2025-04-05", re("(\\d+)-(\\d+)-(\\d+)"), "$2/$3/$1") == "04/05/2025"

# Callback replacement
let result = replace("hello", re("\\w+"), proc(m: Match, s: string): string =
  let b = m.boundaries[0]
  s[b.a].toUpperAscii & s[b.a + 1 ..< b.b]
)
assert result == "Hello"
```

### Split

```nim
assert split("a,b,,c", re(",")) == @["a", "b", "", "c"]

# Capture groups are included in results (like Python re.split)
assert split("a1b2c", re("(\\d)")) == @["a", "1", "b", "2", "c"]
```

### Backward search

```nim
let m = searchBackward("abcabc", re("abc"))
assert m.found
assert m.boundaries[0] == 3 .. 6
```

### Step limit (ReDoS protection)

```nim
# Limit matching steps to prevent catastrophic backtracking.
# Raises RegexLimitError when an attempt exceeds stepLimit steps.
try:
  let m = search("aaaaaaaaaaab", re("(a+)+$"), stepLimit = 10000)
  doAssert m.found
except RegexLimitError:
  echo "step limit exceeded"
```

An attempt is the match tried at one start position. All the attempts of one
search together may take `stepLimit` steps plus `SearchStepsPerByte` (100)
for every byte the start position has moved, and raise past that. The bytes
count in whole blocks, each a sixteenth of `stepLimit` in steps rounded down
to whole bytes, and at least one byte: 6,250 bytes at the default, one byte
below a limit of 3,200. A search whose start stays in its first block may
take `stepLimit` steps in all. Past that block an attempt can run a second
time and be charged once, so a search can do up to about twice that work.

The default, `DefaultStepLimit`, is 10,000,000, the number Oniguruma's retry
limit defaults to. Oniguruma counts backtracks rather than steps, so the two
limits are not the same amount of work; where they were measured to give up
alike is in the documentation of `DefaultStepLimit`.

A search that finds the subject lacks something every match needs, such as
the `b` of `(a+)+b`, answers no match without trying any position, so it
does not raise there. A search that does not raise has not shown the pattern
safe from catastrophic backtracking.

### Stack budget (stack-overflow protection)

Matching keeps its backtrack state on the heap, so native stack usage does
not grow with the subject length. The budget bounds only pattern-nested
re-entry such as nested lookarounds, measured in bytes of native stack.
Exceeding it raises `RegexLimitError`, both when matching and when parsing
with `re()`.

The default is 1 MiB, half of a 2 MiB worker thread. A main thread has 8 MiB.
When the target's budget is known, set it explicitly:

```
nim c -d:reniMaxStackBytes=4194304 yourapp.nim
```

Raise it for main-thread-only builds that match deeply nested patterns;
lower it for small stacks such as musl's 128 KiB default. Keep the budget at
no more than half of the real thread stack, and no less than 16 KiB.

What bounds the *work* a match may do is `stepLimit`, described above.
Debug builds may additionally stop at Nim's call-depth limit before reaching
the byte budget.

### Threads

A `Regex` and a `MatchContext` belong to the thread that built them. A
thread that searches compiles its own `Regex` and uses its own
`MatchContext`; it must not use another thread's, not even only to search
with it, and not even after the other thread is done with it.

```nim
import std/typedthreads
import reni

proc worker(pattern: string) {.thread.} =
  let r = re(pattern) # this thread's own Regex
  let ctx = newMatchContext() # and its own context
  var m: Match
  if searchIntoCtx(ctx, "an IOError here", r, m):
    echo m.matchSpan # 3 .. 10

var threads: array[4, Thread[string]]
for t in threads.mitems:
  createThread(t, worker, r"\w+Error")
joinThreads(threads)
```

Compiling costs little next to searching: a few microseconds for a typical
grep pattern, a few hundred for an alternation of a few hundred literals,
and threads that compile at the same time do not wait for each other.

Every proc that compiles or runs a pattern is `gcsafe`, so a `{.thread.}`
proc can call it; `replace` with a callback is `gcsafe` when the callback is.

## What `import reni` gives you

The package module exports the matching API and the few types it speaks in,
and nothing else. The full list is in the [generated
docs](https://fox0430.github.io/reni/reni.html);
`tests/test_public_api.nim` names every entry through `import reni` alone --
the ones it does not call, it touches for their mere existence -- so an entry
that stops being exported fails a test.

Everything else in `reni/` is the parser's and the matcher's own: the `Node`
tree and its kinds, the character-class tables, the compiler's analyses. Those
are reachable by importing a submodule such as `reni/types` directly, which is
how this repository's own parser and engine tests inspect a compiled tree.
They carry no compatibility promise and change whenever the implementation
does -- a submodule import is the point at which you take that on.

## Documentation

https://fox0430.github.io/reni/reni.html

## License

MIT
