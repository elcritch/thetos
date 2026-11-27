## Persistent (immutable) vector with fast concatenation and slicing, after
## `immer::flex_vector`.
##
## `FlexVec[T]` is a relaxed radix balanced (RRB) tree: a 32-way trie whose
## inner nodes may carry a size table, plus a tail buffer like `TrieVec`.
## Leaves hold up to 128 trivially copyable one-byte elements or up to 32
## elements of other types.
## Nodes built by appends stay regular and are indexed by radix, so indexing,
## `[]=` and `add` cost about the same as on `TrieVec`. Concatenation,
## `drop`, `take`, slicing, `insert`, `erase` and `pushFront` are
## O(log n) and share structure with their inputs.
##
## `FlexDeque[T]` is the same tree with a head buffer for its first
## elements, so `pushFront` and repeated small `drop`s are amortized O(1).
## It has the same API, is one word larger, and indexing, `[]=` and
## concatenation cost a little more. `toFlexDeque` converts a `FlexVec` in
## O(1) and `toFlexVec` converts back in O(log n); `&`, `add` and `==` accept
## the two types mixed. Both are aliases of `FlexImpl`, which the generated
## docs list for every proc.
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

  var d = toFlexDeque(b)
  for i in countdown(0, -2):
    d = d.pushFront(i) # amortized O(1)
  assert d.len == 8 and d[0] == -2 and d.drop(3) == b

import std/[hashes, macros, options, typetraits]
import ./private/core
import ./trievec

type RcCount = DefaultRc

include ./private/flexvecimpl
