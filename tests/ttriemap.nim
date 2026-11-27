import std/[unittest, tables, random, hashes, options, sequtils, algorithm]
import thetos/triemap

type BadKey = object ## Key whose hash collides heavily, to exercise collision nodes.
  id: int

proc hash(k: BadKey): Hash =
  Hash(k.id mod 3)

proc `==`(a, b: BadKey): bool =
  a.id == b.id

type FlakyKey = object ## Key whose hash raises on demand, to test exception safety.
  id: int

var flakyId = -1 # hashing this id raises

proc hash(k: FlakyKey): Hash =
  if k.id == flakyId:
    raise newException(ValueError, "hash failed")
  Hash(7) # all keys collide, forcing the existing entry to be rehashed

proc `==`(a, b: FlakyKey): bool =
  a.id == b.id

proc checkModel[K, V](m: TrieMap[K, V], model: Table[K, V]) =
  check m.len == model.len
  var seen = 0
  for k, v in m:
    check model.hasKey(k)
    check model[k] == v
    inc seen
  check seen == model.len
  for k, v in model:
    check k in m
    check m[k] == v

suite "TrieMap":
  test "empty map":
    let m = initTrieMap[int, int]()
    check m.len == 0
    check 1 notin m
    check $m == "{:}"
    check m.getOrDefault(1, 7) == 7
    check m.get(1).isNone
    expect KeyError:
      discard m[1]
    check default(TrieMap[int, int]) == m

  test "insert, lookup and update keep older versions intact":
    var a = initTrieMap[string, int]()
    a["one"] = 1
    let b = a.put("two", 2)
    let c = b.put("one", 100)
    check a.len == 1
    check b.len == 2
    check c.len == 2
    check a["one"] == 1
    check b["one"] == 1
    check c["one"] == 100
    check "two" notin a
    check b.get("two") == some(2)

  test "erase and del":
    let a = toTrieMap({1: "a", 2: "b", 3: "c"})
    let b = a.erase(2)
    check a.len == 3
    check b.len == 2
    check 2 in a
    check 2 notin b
    var c = b
    c.del(42) # missing key is a no-op
    check c == b
    c.del(1)
    c.del(3)
    check c.len == 0
    check b.len == 2

  test "update applies a function, default for missing keys":
    let a = toTrieMap({"x": 1})
    let b = a.update(
      "x",
      proc(v: int): int =
        v + 10,
    )
    let c = b.update(
      "y",
      proc(v: int): int =
        v + 5,
    )
    check a["x"] == 1
    check b["x"] == 11
    check c["y"] == 5

  test "random operations agree with Table and snapshots stay frozen":
    var r = initRand(1234)
    var m = initTrieMap[int, int]()
    var model = initTable[int, int]()
    var snapshots: seq[(TrieMap[int, int], Table[int, int])]
    for step in 0 ..< 20_000:
      let k = r.rand(3000)
      if r.rand(3) == 0:
        m.del(k)
        model.del(k)
      else:
        m[k] = step
        model[k] = step
      if step mod 2000 == 0:
        snapshots.add((m, model))
    checkModel(m, model)
    for (snap, snapModel) in snapshots:
      checkModel(snap, snapModel)

  test "deleting everything returns to empty":
    var m = initTrieMap[int, int]()
    for i in 0 ..< 5000:
      m[i] = i
    let full = m
    var keys = toSeq(0 ..< 5000)
    var r = initRand(7)
    r.shuffle(keys)
    for k in keys:
      m.del(k)
    check m.len == 0
    check m == initTrieMap[int, int]()
    check full.len == 5000
    for i in 0 ..< 5000:
      check full[i] == i

  test "hash collisions":
    var m = initTrieMap[BadKey, int]()
    var model = initTable[BadKey, int]()
    var r = initRand(99)
    for step in 0 ..< 3000:
      let k = BadKey(id: r.rand(200))
      if r.rand(2) == 0:
        m.del(k)
        model.del(k)
      else:
        m[k] = step
        model[k] = step
      if step mod 100 == 0:
        checkModel(m, model)
    checkModel(m, model)

  test "a raising hash leaves the map intact":
    for shared in [false, true]:
      flakyId = -1
      var m = initTrieMap[FlakyKey, string]()
      m[FlakyKey(id: 1)] = "one"
      let snapshot =
        if shared:
          m
        else:
          initTrieMap[FlakyKey, string]()
      flakyId = 1 # rehashing the existing key 1 now raises
      expect ValueError:
        m[FlakyKey(id: 2)] = "two"
      flakyId = -1
      check m.len == 1
      check m[FlakyKey(id: 1)] == "one"
      check FlakyKey(id: 2) notin m
      if shared:
        check snapshot[FlakyKey(id: 1)] == "one"

  test "equality and hashing are order independent":
    var a, b: TrieMap[int, string]
    for i in 0 ..< 300:
      a[i] = $i
    for i in countdown(299, 0):
      b[i] = $i
    check a == b
    check hash(a) == hash(b)
    b[0] = "zero"
    check a != b

  test "nested persistent values":
    var outer = initTrieMap[string, TrieMap[int, int]]()
    outer["a"] = toTrieMap({1: 1})
    let before = outer
    var inner = outer["a"]
    inner[2] = 2
    outer["a"] = inner
    check before["a"].len == 1
    check outer["a"].len == 2

  test "iterating while reassigning the source sees a snapshot":
    var m = toTrieMap({1: 1, 2: 2, 3: 3})
    var total = 0
    for k, v in m:
      m.del(k)
      total += v
    check total == 6
    check m.len == 0

  test "keys and values":
    let m = toTrieMap({3: "c", 1: "a", 2: "b"})
    check toSeq(m.keys).sorted == @[1, 2, 3]
    check toSeq(m.values).sorted == @["a", "b", "c"]

  test "trie stays shallow":
    var m = initTrieMap[int, int]()
    for i in 0 ..< 100_000:
      m[i] = i
    check m.depth <= 9 # log32(100k) ~ 4, plus random prefix collisions
