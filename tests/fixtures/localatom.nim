## Stores a thread-local container in an Atom. Must not compile with
## threads on (see tlocal.nim).
import thetos
import thetos/local

when defined(nested):
  var a: Atom[thetos.TrieMap[int, local.TrieVec[int]]]
  a.store(thetos.toTrieMap({1: local.toTrieVec([1])}))
elif defined(localAlias):
  type Scratch[T] = local.TrieVec[T]
  var a: Atom[Scratch[int]]
  a.store(local.toTrieVec([1]))
elif defined(localRef):
  type Scratch = ref object
    items: local.TrieVec[int]
    next: Scratch

  var a = initAtom(Scratch(items: local.toTrieVec([1])))
  discard a.load()
elif defined(shadowedSeq):
  type seq[T] = object
    items: local.Box[int]

  var a = initAtom(seq[int](items: local.box(1)))
  discard a.load()
else:
  var a: Atom[local.TrieMap[int, int]]
  a.store(local.toTrieMap({1: 1}))
