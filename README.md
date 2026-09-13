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
- POSIX character classes, Unicode properties `\p{...}`
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
# Raises RegexLimitError when the step count exceeds stepLimit.
try:
  let m = search("aaaaaaaaaaab", re("(a+)+$"), stepLimit = 10000)
  doAssert m.found
except RegexLimitError:
  echo "step limit exceeded"
```

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
