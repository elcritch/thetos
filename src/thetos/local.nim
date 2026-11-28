## Thread-local variants of the thetos containers, with plain (non-atomic)
## reference counts.
##
## `local.TrieMap`, `local.TrieMultiMap`, `local.TrieSet`, `local.TrieVec`, `local.FlexVec` and
## `local.Box` have the same API and behavior as the containers in
## `thetos`, built from the same source. Their reference counts use plain
## integer operations, which makes updates of shared versions faster (about
## 20% for maps and sets) but means a value must never be shared with, or
## sent to, another thread.
##
## They are distinct types, so a program can use both kinds: thread-local
## containers for private work and the `thetos` ones for state shared
## between threads. When both modules are imported, qualify the types and
## constructors with the module name, as in `local.toTrieVec([1, 2])`;
## other procs resolve by argument type. `Atom` rejects these types at
## compile time.
##
## A program built with `--threads:off` cannot share values between threads
## at all, so there the `thetos` containers use plain counts too.

runnableExamples:
  import thetos
  import thetos/local

  var scratch = local.toTrieVec([1, 2, 3]) # thread-local, plain counts
  scratch.add 4
  let shared = thetos.toTrieVec([1, 2, 3]) # atomic counts
  assert scratch.len == 4 and shared.len == 3
  assert scratch[0] == shared[0]

import std/[atomics, bitops, hashes, macros, options, typetraits, unicode]
import ./private/core
export DiffKind

type RcCount = int

include ./private/champimpl
include ./private/triemapimpl
include ./private/triesetimpl
include ./private/trievecimpl
include ./private/boximpl
include ./private/flexvecimpl
include ./private/triemultimapimpl
include ./private/immstrimpl
include ./private/flexstrimpl
