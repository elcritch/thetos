## thetos: persistent, immutable data structures for Nim, after the C++
## library immer.
##
## * `TrieMap[K, V] <thetos/triemap.html>`_: CHAMP hash map
## * `TrieSet[T] <thetos/trieset.html>`_: CHAMP hash set
## * `TrieVec[T] <thetos/trievec.html>`_: radix-balanced vector
## * `FlexVec[T] <thetos/flexvec.html>`_: relaxed radix-balanced vector with
##   O(log n) concatenation and slicing, and `FlexDeque[T]`, the same with
##   amortized O(1) `pushFront`
## * `Box[T] <thetos/box.html>`_: shared immutable value
## * `ImmStr <thetos/immstr.html>`_: immutable string with O(1) copies
## * `FlexStr <thetos/flexstr.html>`_: persistent string (rope) with
##   O(log n) concatenation, slicing and editing
## * `Atom[T] <thetos/atom.html>`_: lock-free cell for publishing new
##   versions between threads, and `AtomRef[T]`, a copyable handle to one
##   shared atom
##
## All containers are value types with O(1) copies and structural sharing.
## Nodes use atomic reference counts and are never mutated while shared,
## so values can be passed between threads under `--mm:arc`, `orc` or
## `atomicArc` without locks.
##
## `thetos/local <thetos/local.html>`_ has thread-local variants of the
## containers (`local.TrieMap` and so on) with plain, non-atomic reference
## counts, for values that never leave one thread. It is not exported from
## this module. A program built with `--threads:off` cannot share values
## between threads at all, so there every container uses plain counts.

import thetos/[triemap, trieset, trievec, flexvec, box, atom, immstr, flexstr]
export triemap, trieset, trievec, flexvec, box, atom, immstr, flexstr
