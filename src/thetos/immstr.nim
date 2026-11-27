## Immutable strings with O(1) copies.
##
## `ImmStr` keeps its bytes in one reference-counted allocation with the
## length and a hash computed once, so copying one is a reference count
## increment. That makes it cheap to keep inside persistent containers,
## where path copying copies entries, and as an `Atom` payload, where every
## `load` copies the value. A plain `string` would copy all its bytes each
## time.
##
## Like `string`, it holds bytes: UTF-8 text works as usual, `len` and
## indexing count bytes, and `runes` and `runeLen` work in code points.
## Building a new string (`&`, slicing) copies; use `FlexStr` for long text
## that is edited often.

runnableExamples:
  let a = toImmStr("hello")
  let b = a # O(1): shares the bytes
  let c = a & ", wörld"
  assert b == "hello" and c.len == 13 and c.runeLen == 12
  assert c.startsWith("hello") and c.find("wörld") == 7
  assert $c[7 .. ^1] == "wörld"

import std/[atomics, hashes, unicode]
import ./private/core

type RcCount = DefaultRc

include ./private/immstrimpl
