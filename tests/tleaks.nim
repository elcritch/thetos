## Every node allocated by the containers must be freed again. Built with
## `-d:thetosTrackAllocs` (see tleaks.nims).

import std/[unittest, random, typedthreads, hashes]
import thetos
import thetos/private/core

type BadKey = object
  id: int

proc hash(k: BadKey): Hash =
  Hash(k.id mod 2)

proc `==`(a, b: BadKey): bool =
  a.id == b.id

type
  FallibleCopy = object
    value: Box[int]

  AlignedPayload {.byref.} = object
    value {.align: 64.}: int

var copiesBeforeFailure = -1

proc `=copy`(dst: var FallibleCopy, src: FallibleCopy) =
  dst.value = src.value
  if copiesBeforeFailure == 0:
    raise newException(ValueError, "copy failed")
  if copiesBeforeFailure > 0:
    dec copiesBeforeFailure

proc fallibleValue(id: int): FallibleCopy =
  FallibleCopy(value: box(id))

template checkNoLeaks(body: untyped) =
  let before = liveAllocations()
  block:
    body
  check liveAllocations() == before

proc churn() =
  var r = initRand(11)
  var m: TrieMap[int, TrieVec[string]]
  var s: TrieSet[BadKey]
  var v: TrieVec[TrieMap[int, int]]
  var keep:
    seq[(TrieMap[int, TrieVec[string]], TrieSet[BadKey], TrieVec[TrieMap[int, int]])]
  for step in 0 ..< 5_000:
    let k = r.rand(500)
    case r.rand(5)
    of 0:
      m.del(k)
      s.excl(BadKey(id: k))
    of 1:
      if v.len > 0:
        discard v.pop()
    of 2:
      if v.len > 0:
        v[r.rand(v.high)] = toTrieMap({k: step})
    else:
      m[k] = toTrieVec([$step])
      s.incl(BadKey(id: k))
      v.add(toTrieMap({k: step}))
    if step mod 500 == 0:
      keep.add((m, s, v))
  for (km, ks, kv) in keep.mitems:
    km = km.erase(1)
    ks = ks.erase(BadKey(id: 1))
    kv = kv.take(kv.len div 2)

suite "leaks":
  test "containers free all nodes":
    checkNoLeaks:
      churn()

  test "boxes and atoms free their cells":
    checkNoLeaks:
      var a = initAtom(box(toTrieMap({1: "a"})))
      for i in 0 ..< 100:
        a.update(
          proc(b: Box[TrieMap[int, string]]): Box[TrieMap[int, string]] =
            box(b[].put(i, $i))
        )
      discard a.exchange(box(initTrieMap[int, string]()))
      check a.load()[].len == 0

  test "throwing atom updates release their snapshots":
    checkNoLeaks:
      var a = initAtom(box(1))
      proc reject(value: Box[int]): Box[int] =
        doAssert value[] == 1
        raise newException(ValueError, "update failed")

      expect ValueError:
        discard a.update(reject)
      check a.load()[] == 1
      a.store(box(2))
      check a.load()[] == 2

  test "throwing copies release unpublished atom cells":
    checkNoLeaks:
      var a = initAtom(fallibleValue(1))
      copiesBeforeFailure = 0
      expect ValueError:
        discard a.update(
          proc(value: FallibleCopy): FallibleCopy =
            fallibleValue(value.value[] + 1)
        )
      copiesBeforeFailure = -1
      check a.load().value[] == 1

  test "throwing copies release partial map clones":
    checkNoLeaks:
      var m = toTrieMap({1: fallibleValue(1), 2: fallibleValue(2)})
      let snapshot = m
      copiesBeforeFailure = 1
      expect ValueError:
        m[1] = fallibleValue(3)
      copiesBeforeFailure = -1
      check m == snapshot
      check m[1].value[] == 1
      m[1] = fallibleValue(3)
      check snapshot[1].value[] == 1

  test "throwing copies release partial vector clones":
    checkNoLeaks:
      var v = toTrieVec([fallibleValue(1), fallibleValue(2)])
      let snapshot = v
      copiesBeforeFailure = 1
      expect ValueError:
        v.add(fallibleValue(3))
      copiesBeforeFailure = 1
      expect ValueError:
        v[0] = fallibleValue(3)
      copiesBeforeFailure = -1
      check v == snapshot
      check v.len == 2
      v.add(fallibleValue(3))
      check snapshot.len == 2

  test "throwing copies release partial collision nodes":
    for other in [0, 3]:
      checkNoLeaks:
        var m = toTrieMap(
          {BadKey(id: 1): fallibleValue(1), BadKey(id: other): fallibleValue(other)}
        )
        let snapshot = m
        copiesBeforeFailure = 1
        expect ValueError:
          m[BadKey(id: 5)] = fallibleValue(5)
        copiesBeforeFailure = -1
        check snapshot.len == 2
        check m == snapshot

  test "boxes and atoms honor payload alignment":
    checkNoLeaks:
      let value = AlignedPayload(value: 1)
      let b = box(value)
      let alignment = uint(alignof(AlignedPayload))
      check cast[uint](unsafeAddr b[]) mod alignment == 0
      check b[].value == 1

      var a = initAtom(value)
      let updated = a.update(
        proc(current: AlignedPayload): AlignedPayload =
          doAssert cast[uint](unsafeAddr current) mod uint(alignof(AlignedPayload)) == 0
          AlignedPayload(value: current.value + 1)
      )
      check updated.value == 2
      check a.exchange(value).value == 2
      check a.load().value == 1

  test "concurrent atom traffic frees all cells":
    var at {.global.}: Atom[TrieMap[int, int]]
    proc work(id: int) {.thread.} =
      for i in 0 ..< 300:
        at.update(
          proc(m: TrieMap[int, int]): TrieMap[int, int] =
            m.put(id * 300 + i, i)
        )
        discard at.load().len

    let before = liveAllocations()
    var ts: array[4, Thread[int]]
    for i in 0 ..< ts.len:
      createThread(ts[i], work, i)
    joinThreads(ts)
    check at.load().len == 1_200
    at.store(default(TrieMap[int, int]))
    # Only the atom's cell for the (node-free) empty map remains.
    check liveAllocations() == before + 1

  test "concurrent loads, stores and exchanges release all retired cells":
    var a {.global.}: Atom[int]
    proc work(id: int) {.thread.} =
      for i in 0 ..< 1_000:
        a.store(i + id)
        doAssert a.load() >= 0
        doAssert a.exchange(i) >= 0

    let before = liveAllocations()
    var ts: array[4, Thread[int]]
    for i in 0 ..< ts.len:
      createThread(ts[i], work, i)
    joinThreads(ts)
    check liveAllocations() == before + 1
