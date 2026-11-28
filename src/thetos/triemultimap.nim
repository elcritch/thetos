## Persistent hash multimap backed by one relaxed radix-balanced tree.
##
## Small maps keep their values in one growable packed leaf. A bitmap marks
## the start of each run, and each distinct key has one boxed header. Larger
## maps use an RRB tree. Values retain insertion order, including duplicates.
## Keys need `hash` and `==`.

runnableExamples:
  var tags = initTrieMultiMap[string, int]()
  tags.add("nim", 3)
  let newer = tags.insert("nim", 5).insert("nim", 3)
  assert newer["nim"] == @[3, 5, 3]
  assert newer.erase("nim", 3)["nim"] == @[5, 3]
  assert tags["nim"] == @[3]

import std/[bitops, hashes]
import ./[box, flexvec]
from ./box {.all.} as boxes import writableBox
from ./flexvec {.all.} as tree import MultiEntry, MultiKey, entriesBetween, nextKeyStart
import ./private/core

type RcCount = DefaultRc

include ./private/triemultimapimpl
