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

template checkNoLeaks(body: untyped) =
  let before = liveAllocations()
  block:
    body
  check liveAllocations() == before

proc churn() =
  var r = initRand(11)
  var m: Map[int, Vector[string]]
  var s: Set[BadKey]
  var v: Vector[Map[int, int]]
  var keep: seq[(Map[int, Vector[string]], Set[BadKey], Vector[Map[int, int]])]
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
        v[r.rand(v.high)] = toMap({k: step})
    else:
      m[k] = toVector([$step])
      s.incl(BadKey(id: k))
      v.add(toMap({k: step}))
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
      var a = initAtom(box(toMap({1: "a"})))
      for i in 0 ..< 100:
        a.update(
          proc(b: Box[Map[int, string]]): Box[Map[int, string]] =
            box(b[].put(i, $i))
        )
      discard a.exchange(box(initMap[int, string]()))
      check a.load()[].len == 0

  test "concurrent atom traffic frees all cells":
    var at {.global.}: Atom[Map[int, int]]
    proc work(id: int) {.thread.} =
      for i in 0 ..< 300:
        at.update(
          proc(m: Map[int, int]): Map[int, int] =
            m.put(id * 300 + i, i)
        )
        discard at.load().len

    let before = liveAllocations()
    var ts: array[4, Thread[int]]
    for i in 0 ..< ts.len:
      createThread(ts[i], work, i)
    joinThreads(ts)
    check at.load().len == 1_200
    at.store(default(Map[int, int]))
    # Only the atom's cell for the (node-free) empty map remains.
    check liveAllocations() == before + 1
