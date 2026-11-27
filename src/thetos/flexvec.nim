## Persistent (immutable) vector with fast concatenation and slicing, after
## `immer::flex_vector`.
##
## `FlexVec[T]` is a relaxed radix balanced (RRB) tree: a 32-way trie whose
## inner nodes may carry a size table, plus a tail buffer like `TrieVec`.
## Nodes built by appends stay regular and are indexed by radix, so indexing,
## `[]=` and `add` cost about the same as on `TrieVec`. Concatenation,
## `drop`, `take`, slicing, `insert`, `erase` and `pushFront` are
## O(log n) and share structure with their inputs.
##
## Reference counts are atomic, so vectors can be passed between threads
## without locks. Uniquely owned nodes are edited in place.

runnableExamples:
  let a = toFlexVec([1, 2, 3])
  let b = a & toFlexVec([4, 5])
  assert b.len == 5 and a.len == 3
  assert b[1 .. 3] == toFlexVec([2, 3, 4])
  assert b.insert(0, 0)[0] == 0
  assert b.erase(4) == toFlexVec([1, 2, 3, 4])

import std/[hashes, options]
import ./private/core
import ./trievec

type RcCount = DefaultRc

include ./private/flexvecimpl
