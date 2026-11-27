import std/unittest
import thetos/[atom, hashmap, vector]

suite "Atom":
  test "default atom holds default value":
    var a: Atom[int]
    check a.load() == 0
    check a.exchange(5) == 0
    check a.load() == 5

  test "store, exchange and update":
    var a = initAtom(toMap({"a": 1}))
    let snap = a.load()
    a.store(snap.put("b", 2))
    check snap.len == 1
    check a.load().len == 2
    let old = a.exchange(initMap[string, int]())
    check old.len == 2
    let now = a.update(
      proc(m: Map[string, int]): Map[string, int] =
        m.put("c", 3)
    )
    check now.len == 1
    check a.load()["c"] == 3

  test "atom of vector":
    var a = initAtom(toVector([1]))
    for i in 2 .. 100:
      a.update(
        proc(v: Vector[int]): Vector[int] =
          v.pushBack(i)
      )
    check a.load().len == 100
    check a.load()[99] == 100
