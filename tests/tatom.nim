import std/unittest
import thetos/[atom, triemap, trievec]

type Counted = object ## Element that counts how often it is copied.
  id: int

var copies = 0

proc `=copy`(dst: var Counted, src: Counted) =
  inc copies
  dst.id = src.id

proc `=dup`(src: Counted): Counted =
  inc copies
  Counted(id: src.id)

suite "Atom":
  test "default atom holds default value":
    var a: Atom[int]
    check a.load() == 0
    check a.exchange(5) == 0
    check a.load() == 5

  test "store, exchange and update":
    var a = initAtom(toTrieMap({"a": 1}))
    let snap = a.load()
    a.store(snap.put("b", 2))
    check snap.len == 1
    check a.load().len == 2
    let old = a.exchange(initTrieMap[string, int]())
    check old.len == 2
    let now = a.update(
      proc(m: TrieMap[string, int]): TrieMap[string, int] =
        m.put("c", 3)
    )
    check now.len == 1
    check a.load()["c"] == 3

  test "exchange moves the old value out when unshared":
    var a = initAtom(Counted(id: 1))
    copies = 0
    check a.exchange(Counted(id: 2)).id == 1
    check copies == 0
    let held = a.load() # one copy, and the cell is now shared
    check copies == 1
    check a.exchange(Counted(id: 3)).id == 2
    check held.id == 2

  test "atom of vector":
    var a = initAtom(toTrieVec([1]))
    for i in 2 .. 100:
      a.update(
        proc(v: TrieVec[int]): TrieVec[int] =
          v.pushBack(i)
      )
    check a.load().len == 100
    check a.load()[99] == 100
