## thetos: persistent, immutable data structures for Nim, after the C++
## library immer.
##
## * `Map[K, V] <thetos/hashmap.html>`_: CHAMP hash map
## * `Set[T] <thetos/hashset.html>`_: CHAMP hash set
## * `Vector[T] <thetos/vector.html>`_: radix-balanced vector
## * `Box[T] <thetos/box.html>`_: shared immutable value
## * `Atom[T] <thetos/atom.html>`_: lock-free cell for publishing new
##   versions between threads
##
## All containers are value types with O(1) copies and structural sharing.
## Nodes use atomic reference counts and are never mutated while shared,
## so values can be passed between threads under `--mm:arc`, `orc` or
## `atomicArc` without locks.

import thetos/[hashmap, hashset, vector, box, atom]
export hashmap, hashset, vector, box, atom
