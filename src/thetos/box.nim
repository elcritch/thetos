## Immutable boxed value, after `immer::box`.
##
## `Box[T]` holds one heap-allocated `T` shared between copies through an
## atomic reference count. Copying a box is O(1), and boxes can cross
## threads without locks. Use it to share a large value cheaply or to give a
## value a stable identity.

runnableExamples:
  let a = box(@[1, 2, 3])
  let b = a.update(
    proc(s: seq[int]): seq[int] =
      s & 4
  )
  assert a[] == @[1, 2, 3]
  assert b[] == @[1, 2, 3, 4]

import std/[hashes]
import ./private/core

type RcCount = DefaultRc

include ./private/boximpl
