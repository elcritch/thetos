## thetos: persistent, immutable data structures for Nim, after the C++
## library immer.
##
## * `TrieMap[K, V] <thetos/triemap.html>`_: CHAMP hash map
## * `TrieSet[T] <thetos/trieset.html>`_: CHAMP hash set
## * `TrieVec[T] <thetos/trievec.html>`_: radix-balanced vector
## * `FlexVec[T] <thetos/flexvec.html>`_: relaxed radix-balanced vector with
##   O(log n) concatenation and slicing
## * `Box[T] <thetos/box.html>`_: shared immutable value
## * `Atom[T] <thetos/atom.html>`_: lock-free cell for publishing new
##   versions between threads
##
## All containers are value types with O(1) copies and structural sharing.
## Nodes use atomic reference counts and are never mutated while shared,
## so values can be passed between threads under `--mm:arc`, `orc` or
## `atomicArc` without locks.
##
## Programs that never share thetos values between threads can build with
## `-d:thetosSingleThread` to use plain, non-atomic reference counts. `Atom`
## is not available in that mode.

import thetos/[triemap, trieset, trievec, flexvec, box]
export triemap, trieset, trievec, flexvec, box

when not defined(thetosSingleThread):
  import thetos/atom
  export atom
