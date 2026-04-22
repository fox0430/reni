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

- Nim >= 2.0.0

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

## Internal API notice

`Regex.ast`, the `Node` type, and `NodeKind` are exposed by the library but
they are **internal implementation details**. They are re-exported so that
tests inside this repository can inspect parsed trees. User code should not
depend on them, and they may be removed or restricted in a future release.
Use `captureText`, `captureSpan`, `captureIndex`, `captureCount`,
`namedCaptures`, and `pattern` instead.

## Documentation

https://fox0430.github.io/reni/reni.html

## License

MIT
