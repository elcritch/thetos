## Concurrency stress tests. Run under arc, orc and atomicArc; the
## containers must not depend on atomic `ref` counting.

import std/[unittest, typedthreads]
import thetos/[atom, triemap, triemultimap, trievec, trieset]

const
  threadCount = 8
  perThread = 2_000

var
  shared: Atom[TrieMap[int, int]]
  base: TrieMap[int, int]
  baseVec: TrieVec[string]
  stop: Atom[bool]

proc writer(id: int) {.thread.} =
  for i in 0 ..< perThread:
    let key = id * perThread + i
    shared.update(
      proc(m: TrieMap[int, int]): TrieMap[int, int] =
        m.put(key, i)
    )

proc reader(id: int) {.thread.} =
  var last = 0
  while not stop.load():
    let m = shared.load()
    doAssert m.len >= last, "atom went backwards"
    last = m.len
    var n = 0
    for k, v in m:
      doAssert k mod perThread == v
      inc n
    doAssert n == m.len

proc forker(id: int) {.thread.} =
  ## Edits a private copy of structure shared with every other thread.
  for round in 0 ..< 20:
    var mine = base
    var vec = baseVec
    for i in 0 ..< 500:
      mine[i] = id * 1_000_000 + round
      mine.del(i + 500)
      vec[i] = $id
      vec.add($round)
    doAssert mine.len == base.len - 500
    doAssert mine[0] == id * 1_000_000 + round
    doAssert vec[0] == $id and vec.len == baseVec.len + 500
  doAssert base[0] == 0 and base[700] == 700
  doAssert baseVec[0] == "0"

suite "threads":
  test "concurrent CAS updates lose nothing":
    shared.store(initTrieMap[int, int]())
    stop.store(false)
    var writers: array[threadCount, Thread[int]]
    var readers: array[2, Thread[int]]
    for i in 0 ..< readers.len:
      createThread(readers[i], reader, i)
    for i in 0 ..< threadCount:
      createThread(writers[i], writer, i)
    joinThreads(writers)
    stop.store(true)
    joinThreads(readers)
    let final = shared.load()
    check final.len == threadCount * perThread
    for id in 0 ..< threadCount:
      for i in 0 ..< perThread:
        check final[id * perThread + i] == i
    shared.store(initTrieMap[int, int]())

  test "threads path-copy shared structure independently":
    base = initTrieMap[int, int]()
    baseVec = initTrieVec[string]()
    for i in 0 ..< 5_000:
      base[i] = i
      baseVec.add($i)
    var ts: array[threadCount, Thread[int]]
    for i in 0 ..< threadCount:
      createThread(ts[i], forker, i)
    joinThreads(ts)
    check base.len == 5_000
    for i in 0 ..< 5_000:
      check base[i] == i
      check baseVec[i] == $i
    base = initTrieMap[int, int]()
    baseVec = initTrieVec[string]()

  test "threads edit shared packed and tree multimaps independently":
    type Roots = tuple[small, large: TrieMultiMap[int, string]]
    proc edit(roots: Roots) {.thread.} =
      for i in 1 .. 100:
        var small = roots.small
        var large = roots.large
        small.add(1, $i)
        large.del(1)
        doAssert small.count(1) == 1 and large == roots.small

    var roots: Roots
    roots.small.add(0, "original")
    roots.large = roots.small
    for i in 0 ..< 32:
      roots.large.add(1, $i)
    var workers: array[threadCount, Thread[Roots]]
    for i in 0 ..< workers.len:
      createThread(workers[i], edit, roots)
    joinThreads(workers)
    check roots.small[0] == @["original"] and roots.small.len == 1
    check roots.large[0] == @["original"] and roots.large.count(1) == 32

  test "sets cross threads through an atom":
    var a {.global.}: Atom[TrieSet[int]]
    proc adder(id: int) {.thread.} =
      for i in 0 ..< 500:
        a.update(
          proc(s: TrieSet[int]): TrieSet[int] =
            s.insert(id * 500 + i)
        )

    var ts: array[4, Thread[int]]
    for i in 0 ..< ts.len:
      createThread(ts[i], adder, i)
    joinThreads(ts)
    check a.load().len == 2_000
