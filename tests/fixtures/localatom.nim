## Stores a thread-local container in an Atom, directly or nested inside an
## atomic one. Must not compile with threads on (see tlocal.nim).
import thetos
import thetos/local

when defined(nested):
  var a: Atom[thetos.TrieMap[int, local.TrieVec[int]]]
  a.store(thetos.toTrieMap({1: local.toTrieVec([1])}))
else:
  var a: Atom[local.TrieMap[int, int]]
  a.store(local.toTrieMap({1: 1}))
