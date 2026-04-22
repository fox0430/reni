## reni - A **re**gular expression engine compatible with O**ni**guruma
##
## A pure Nim regex engine that replicates the syntax and semantics of
## `Oniguruma <https://github.com/kkos/oniguruma>`_.
##
## Features
## ========
##
## - Capture groups (numbered and named)
## - Backreferences and named backreferences with recursion-level support
## - Lookaround assertions (lookahead, lookbehind, negative variants)
## - Atomic groups ``(?>...)``
## - Conditionals ``(?(cond)yes|no)``
## - Subexpression calls ``\g<name>``, ``\g<n>``
## - Absent operator ``(?~...)``
## - POSIX character classes, Unicode properties ``\p{...}``
## - Greedy, lazy, and possessive quantifiers
## - Grapheme cluster mode ``(?y{g})``, word mode ``(?y{w})``
## - Flags: ``(?i)``, ``(?m)``, ``(?x)``, ``(?W)``, ``(?D)``, ``(?S)``,
##   ``(?P)``, ``(?I)``, ``(?L)``
## - ReDoS protection via step limit
##
## Basic usage
## ===========
##
## .. code-block:: nim
##   import pkg/reni
##
##   let m = search("hello world", re("(\\w+)\\s(\\w+)"))
##   assert m.found
##   assert m.boundaries[0] == 0 .. 11  # full match
##   assert m.boundaries[1] == 0 .. 5   # group 1
##   assert m.boundaries[2] == 6 .. 11  # group 2
##
## See the project README for more examples including named captures,
## `matchAt`, `findAll`, `replace`, `split`, and backward search.

## Modules
## =======
## - `types <reni/types.html>`_ — Core type definitions shared across the
##   engine: ``Regex``, ``Match``, ``Span``, flag and anchor enums, and the
##   (internal) AST node tags.
## - `compiler <reni/compiler.html>`_ — Pattern compilation entry point.
##   Exposes ``re(pattern, flags)`` which parses, validates, and optimizes
##   a pattern into a reusable ``Regex``.
## - `api <reni/api.html>`_ — High-level matching API: ``search``,
##   ``searchBackward``, ``matchAt``, ``findAll``, ``replace``, ``split``,
##   plus ``Match`` / capture-group accessors.

import reni/[types, compiler, api]

export types, compiler, api
