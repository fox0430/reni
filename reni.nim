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
##   engine. ``Regex``, ``Match``, ``Span`` and the flags reach callers
##   through this package; the AST and the matcher's tables only by
##   importing ``reni/types`` directly.
## - `compiler <reni/compiler.html>`_ — Pattern compilation entry point.
##   Exposes ``re(pattern, flags)`` which parses, validates, and optimizes
##   a pattern into a reusable ``Regex``.
## - `api <reni/api.html>`_ — High-level matching API: ``search``,
##   ``searchBackward``, ``matchAt``, ``findAll``, ``replace``, ``split``,
##   plus ``Match`` / capture-group accessors.

import reni/[types, compiler, api]

export compiler, api

# ``types`` is exported by name rather than whole: the rest of it -- the
# ``Node`` tree, the class tables, the compiler's analyses -- is the parser's
# and the matcher's, and exporting it made each of them part of this library's
# API. Tests that inspect a tree import ``reni/types`` directly.
# The names are qualified with ``types.``: a bare ``==`` or ``$`` here would
# resolve in this module's scope and re-export every overload visible in it,
# including ones a future import drags in.
#
# Qualifying still carries a name whole: ``types.`==` `` re-exports the
# ``NameRefs`` and ``NodeId`` overloads along with the ``Span`` ones. Those
# two are harmless only because neither type is re-exported below, so a caller
# with only ``import reni`` cannot name an argument for them -- which is the
# condition an operator added to ``types`` for an internal type has to keep
# meeting. Narrowing this to the ``Span`` overloads by forwarding them from
# here is not an option: a module that imports both ``reni`` and
# ``reni/types``, as the engine tests do, then sees two identical ``==`` and
# every comparison is ambiguous.
export
  # Errors.
  types.RegexError,
  types.RegexLimitError,
  # The pattern and the options it was compiled under.
  types.Regex,
  types.pattern,
  types.flags,
  types.captureCount,
  types.namedCaptures,
  types.RegexFlag,
  types.RegexFlags,
  # What a match answers with.
  types.Match,
  types.Span,
  types.UnsetSpan,
  types.span,
  types.`==`,
  types.`$`,
  # The limits ``search`` and friends take.
  types.DefaultStepLimit,
  types.DefaultMaxRecursionDepth
