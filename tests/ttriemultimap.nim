import std/[hashes, random, sequtils, tables, unittest]
when defined(thetosTestLocal):
  import thetos/local
else:
  import thetos/triemultimap
import ./fixtures/falliblecopy

type
  CollisionKey = distinct int
  LargeKey = object
    id: int
    data: array[256, byte]

proc hash(k: CollisionKey): Hash =
  Hash(int(k) mod 3)

proc `==`(a, b: CollisionKey): bool {.borrow.}

var keyCopies: int

proc `=copy`(dst: var LargeKey, src: LargeKey) =
  inc keyCopies
  dst.id = src.id
  dst.data = src.data

proc hash(k: LargeKey): Hash =
  Hash(k.id)

proc `==`(a, b: LargeKey): bool =
  a.id == b.id

suite "TrieMultiMap":
  test "empty and missing keys":
    var m = initTrieMultiMap[string, int]()
    check m == default(TrieMultiMap[string, int])
    check m.len == 0 and m.keyCount == 0
    check "a" notin m and m.count("a") == 0
    check toSeq(m.values("a")).len == 0
    expect KeyError:
      discard m["a"]
    m.del("a")
    m.del("a", 1)
    check m.len == 0

  test "nil is a valid key and value":
    let n: ptr int = nil
    var x: int
    let p = addr x
    let m = toTrieMultiMap({n: n, p: n, n: p})
    check m.keyCount == 2 and m[n] == @[n, p] and m[p] == @[n]
    check m.erase(n, n)[n] == @[p]

  test "values retain duplicates and per-key insertion order across versions":
    let original = toTrieMultiMap({"a": 1, "b": 9, "a": 2, "a": 1})
    let more = original.insert("b", 8).insert("a", 3)
    check more.len == 6 and more.keyCount == 2 and more.hasKey("a")
    check more.count("a") == 4 and toSeq(more.values("a")) == @[1, 2, 1, 3]
    check more.erase("a", 1)["a"] == @[2, 1, 3]
    check more.erase("a", 2)["a"] == @[1, 1, 3]
    check more.erase("a", 3)["a"] == @[1, 2, 1]
    check more.erase("a", 42) == more
    let onlyB = more.erase("a")
    check onlyB.keyCount == 1 and onlyB.len == 2 and onlyB["b"] == @[9, 8]
    check onlyB.erase("b", 9).erase("b", 8).keyCount == 0
    check original["a"] == @[1, 2, 1] and original["b"] == @[9]

  test "the stored key survives leaf splits, snapshot copies and head removal":
    checkNoLeaks:
      let key = LargeKey(id: 42)
      var m = initTrieMultiMap[LargeKey, int]()
      keyCopies = 0
      m.add(key, 0)
      check keyCopies == 1
      for i in 1 .. 2200:
        m.add(key, i)
      let old = m
      m.del(key, 0)
      m.add(key, 2201)
      check m.keyCount == 1 and m.count(key) == 2201
      check old[key][0] == 0 and m[key][0] == 1
      check keyCopies == 1

  test "distinct keys with the same hash have independent runs":
    let a = CollisionKey(0)
    let b = CollisionKey(3)
    let c = CollisionKey(6)
    var m = toTrieMultiMap({a: 0, b: 9, c: 7})
    for i in 1 .. 1100:
      m.add(a, i)
      m.add(b, -i)
    let before = m
    m.del(a, 0)
    m.del(b)
    check m[a] == toSeq(1 .. 1100)
    check m[c] == @[7] and b notin m
    check before.count(b) == 1101 and before[b][^1] == -1100
    let left = toTrieMultiMap({a: 1, b: 0, a: 2})
    let right = toTrieMultiMap({b: 0, a: 1, a: 2})
    check left == right and hash(left) == hash(right)
    check left != toTrieMultiMap({b: 0, a: 2, a: 1})

  test "iterators keep a snapshot while the map is reassigned":
    let before = toTrieMultiMap({1: "a", 2: "c", 1: "b"})
    var m = before
    var read: seq[string]
    for v in m.values(1):
      m.del(1)
      read.add v
    check read == @["a", "b"]
    m = before
    var seen: seq[(int, string)]
    for k, v in m:
      reset(m)
      seen.add (k, v)
    check seen == toSeq(before.pairs)
    check toSeq(before.keys).len == 2
    check toSeq(before.values).len == before.len

  test "packed runs span every small size and survive representation changes":
    checkNoLeaks:
      var m: TrieMultiMap[CollisionKey, int]
      let a = CollisionKey(0)
      let b = CollisionKey(3)
      for n in 1 .. 32:
        m.add(a, n)
        check m[a] == toSeq(1 .. n)
        check m.keyCount == 1 and m.count(b) == 0
      let packed = m
      m.add(b, 0)
      check m.len == 33 and toSeq(m.values(b)) == @[0]
      let tree = m
      for n in countdown(32, 18):
        m.del(a, n)
      var same = initTrieMultiMap[CollisionKey, int]()
      same.add(b, 0)
      for n in 1 .. 17:
        same.add(a, n)
      check m == same and same == m and hash(same) == hash(m)
      m.del(a, 1)
      m.del(a, 2)
      check m.len == 16 and m[a] == toSeq(3 .. 17)
      m.del(a)
      check m.len == 1 and m[b] == @[0]
      check tree.len == 33 and packed.len == 32 and b notin packed

      var singletons: TrieMultiMap[CollisionKey, int]
      for i in 0 ..< 32:
        singletons.add(CollisionKey(i), i)
      for i in 0 ..< 32:
        let key = CollisionKey(i)
        check singletons.count(key) == 1 and singletons[key] == @[i]
        let edited = singletons.erase(key).insert(key, -i)
        check edited.keyCount == 32 and edited[key] == @[-i]
        check singletons[key] == @[i]

  test "last owner can be released or replaced inside a packed iterator":
    checkNoLeaks:
      var m = toTrieMultiMap({1: "abc", 1: "def", 2: "xyz"})
      var seen: seq[string]
      for value in m.values(1):
        m = toTrieMultiMap({9: "replacement"})
        seen.add(value)
      check seen == @["abc", "def"]
      for key, value in m:
        reset(m)
        check key == 9 and value == "replacement"
      check m.len == 0

  test "raising copies preserve packed snapshots and both tree transitions":
    for budget in 0 ..< 32:
      checkNoLeaks:
        var m: TrieMultiMap[int, FallibleCopy]
        for i in 0 ..< 32:
          m.add(i mod 2, fallibleValue(i))
        let before = m
        expectCopyFailure(budget):
          m.add(2, fallibleValue(32))
        check m == before and m.len == 32
    for budget in 0 ..< 8:
      checkNoLeaks:
        var m: TrieMultiMap[int, FallibleCopy]
        for i in 0 ..< 8:
          m.add(1, fallibleValue(i))
        let packed = m
        expectCopyFailure(budget):
          m.add(1, fallibleValue(8))
        if budget < 7:
          expectCopyFailure(budget):
            m.del(1, fallibleValue(3))
        check m == packed
        for i in 0 ..< 25:
          m.add(2, fallibleValue(i))
        let large = m
        expectCopyFailure(budget):
          m.del(2)
        check m == large and m.keyCount == 2
        m.del(2)
        check m == packed

  test "mixed edits agree with a table of sequences":
    var rng = initRand(837)
    var m: TrieMultiMap[int, int]
    var model: Table[int, seq[int]]
    for step in 0 ..< 4800:
      let k = rng.rand(220)
      let v = rng.rand(12)
      case rng.rand(9)
      of 0:
        m.del(k)
        model.del(k)
      of 1, 2:
        m.del(k, v)
        if k in model:
          let i = model[k].find(v)
          if i >= 0:
            model[k].delete(i)
            if model[k].len == 0:
              model.del(k)
      else:
        m.add(k, v)
        model.mgetOrPut(k, @[]).add(v)
      if step mod 137 == 0 or step == 4799:
        var total = 0
        for key, vals in model:
          check m[key] == vals
          total += vals.len
        check m.len == total and m.keyCount == model.len

  test "raising value copies release temporary trees and preserve the map":
    checkNoLeaks:
      var m: TrieMultiMap[int, FallibleCopy]
      for i in 0 ..< 80:
        m.add(i mod 2, fallibleValue(i))
      let old = m
      expectCopyFailure(1):
        discard m[0]
      expectCopyFailure(1):
        m.add(0, fallibleValue(80))
      expectCopyFailure(1):
        m.del(0, fallibleValue(0))
      check m == old and m.count(0) == 40
