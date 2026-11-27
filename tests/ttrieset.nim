import std/[unittest, random, sequtils, algorithm]
import std/sets
import thetos/trieset

suite "TrieSet":
  test "basic insert and erase keep versions":
    let a = toTrieSet([1, 2, 3])
    let b = a.insert(4)
    let c = b.erase(1)
    check a.len == 3 and b.len == 4 and c.len == 3
    check 4 notin a and 4 in b and 1 notin c
    check toSeq(c.items).sorted == @[2, 3, 4]

  test "incl of existing element does not grow":
    var s = toTrieSet(["a"])
    s.incl("a")
    check s.len == 1
    s.excl("missing")
    check s.len == 1

  test "set algebra":
    let a = toTrieSet([1, 2, 3, 4])
    let b = toTrieSet([3, 4, 5])
    check a + b == toTrieSet([1, 2, 3, 4, 5])
    check a * b == toTrieSet([3, 4])
    check a - b == toTrieSet([1, 2])
    check b - a == toTrieSet([5])
    check toTrieSet([3]) <= a
    check not (a <= b)

  test "random operations agree with HashSet":
    var r = initRand(42)
    var s = initTrieSet[int]()
    var model = initHashSet[int]()
    var snaps: seq[(TrieSet[int], HashSet[int])]
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
    check hash(toTrieSet([1, 2, 3])) == hash(toTrieSet([3, 2, 1]))
    check $toTrieSet([7]) == "{7}"

suite "TrieSet diff":
  test "added and removed":
    let a = toTrieSet([1, 2, 3])
    let b = a.erase(1).insert(4).insert(2)
    var got: seq[(DiffKind, int)]
    for d in diff(a, b):
      got.add (d.kind, d.item)
    check got.sorted() == @[(dkAdded, 4), (dkRemoved, 1)]

  test "random edits agree with HashSet":
    var r = initRand(5)
    for round in 0 ..< 40:
      var a = initTrieSet[int]()
      for i in 0 ..< r.rand(3000):
        a.incl r.rand(5000)
      var b = a
      for i in 0 ..< r.rand(200):
        let x = r.rand(5000)
        if r.rand(1) == 0:
          b.excl x
        else:
          b.incl x
      var want: seq[(DiffKind, int)]
      for x in a:
        if x notin b:
          want.add (dkRemoved, x)
      for x in b:
        if x notin a:
          want.add (dkAdded, x)
      var got: seq[(DiffKind, int)]
      for d in diff(a, b):
        got.add (d.kind, d.item)
      check got.sorted() == want.sorted()
