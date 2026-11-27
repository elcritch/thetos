import std/[unittest, random, sequtils, algorithm]
import std/sets except toSet, initSet
import thetos/hashset

suite "Set":
  test "basic insert and erase keep versions":
    let a = toSet([1, 2, 3])
    let b = a.insert(4)
    let c = b.erase(1)
    check a.len == 3 and b.len == 4 and c.len == 3
    check 4 notin a and 4 in b and 1 notin c
    check toSeq(c.items).sorted == @[2, 3, 4]

  test "incl of existing element does not grow":
    var s = toSet(["a"])
    s.incl("a")
    check s.len == 1
    s.excl("missing")
    check s.len == 1

  test "set algebra":
    let a = toSet([1, 2, 3, 4])
    let b = toSet([3, 4, 5])
    check a + b == toSet([1, 2, 3, 4, 5])
    check a * b == toSet([3, 4])
    check a - b == toSet([1, 2])
    check b - a == toSet([5])
    check toSet([3]) <= a
    check not (a <= b)

  test "random operations agree with HashSet":
    var r = initRand(42)
    var s = initSet[int]()
    var model = initHashSet[int]()
    var snaps: seq[(Set[int], HashSet[int])]
    for step in 0 ..< 20_000:
      let x = r.rand(2000)
      if r.rand(2) == 0:
        s.excl(x)
        model.excl(x)
      else:
        s.incl(x)
        model.incl(x)
      if step mod 3000 == 0:
        snaps.add((s, model))
    snaps.add((s, model))
    for (snap, m) in snaps:
      check snap.len == m.len
      for x in snap:
        check x in m
      for x in m:
        check x in snap

  test "hash and string":
    check hash(toSet([1, 2, 3])) == hash(toSet([3, 2, 1]))
    check $toSet([7]) == "{7}"
