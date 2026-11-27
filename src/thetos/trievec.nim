## Persistent (immutable) vector, after `immer::vector`.
##
## `TrieVec[T]` is a 32-way radix-balanced tree with a tail buffer. Indexing
## and updates are O(log32 n) (effectively constant), appends are amortized
## O(1), and copies are O(1) with full structural sharing. Reference counts
## are atomic, so vectors can be passed between threads without locks.
##
## Uniquely owned nodes are edited in place, so `add` in a loop on a single
## vector does not path-copy.

runnableExamples:
  var v = toTrieVec([1, 2, 3])
  let w = v.pushBack(4)
  v[0] = 10
  assert v.len == 3 and w.len == 4
  assert v[0] == 10 and w[0] == 1

import std/[hashes, options]
import ./private/core

type RcCount = DefaultRc

include ./private/trievecimpl
