## Persistent (immutable) hash set, after `immer::set`.
##
## `TrieSet[T]` shares the CHAMP trie of `TrieMap` and has the same properties:
## O(1) copies, O(log32 n) updates by path copying, in-place updates when
## uniquely owned, and atomic reference counts so sets can be shared across
## threads without locks.

runnableExamples:
  let a = toTrieSet([1, 2, 3])
  let b = a.insert(4)
  assert 4 notin a and 4 in b
  assert (a + toTrieSet([9])).len == 4

import std/[bitops, hashes, options]
import ./private/core
export DiffKind

type RcCount = DefaultRc

include ./private/champimpl
include ./private/triesetimpl
