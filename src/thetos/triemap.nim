## Persistent (immutable) hash map, after `immer::map`.
##
## `TrieMap[K, V]` is a value type backed by a CHAMP hash trie with atomic
## reference counts. Copying a map is O(1) and shares all structure; an
## update copies only the path to the changed entry (O(log32 n)) and leaves
## every other copy untouched. Maps can be shared freely between threads:
## nodes are never mutated while shared, and reference counts are atomic.
##
## When a map's nodes are uniquely owned (for example the only copy, or a
## `sink` argument at its last use) updates happen in place, so building a
## map in a loop with `[]=` is about as cheap as a mutable table.
##
## Keys need `hash` and `==`. Keys and values must be safe to copy from
## several threads at once: plain values, strings, seqs and thetos
## containers are; Nim `ref`s are only when compiled with `--mm:atomicArc`.

runnableExamples:
  var a = initTrieMap[string, int]()
  a["one"] = 1
  let b = a.put("two", 2) # `a` is unchanged
  assert a.len == 1 and b.len == 2
  assert b["two"] == 2
  assert "two" notin a

import std/[bitops, hashes, options]
import ./private/core
export DiffKind

type RcCount = DefaultRc

include ./private/champimpl
include ./private/triemapimpl
