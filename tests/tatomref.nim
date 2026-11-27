## AtomRef: a copyable, reference-counted handle to one shared Atom.
## Built with -d:thetosTrackAllocs (see tatomref.nims).

import std/[unittest, typedthreads, os, strutils]
import thetos
import thetos/private/core

template checkNoLeaks(body: untyped) =
  let before = liveAllocations()
  block:
    body
  check liveAllocations() == before

suite "AtomRef":
  test "copies share one atom":
    checkNoLeaks:
      let a = newAtomRef(toTrieMap({"x": 1}))
      let b = a
      var c: AtomRef[TrieMap[string, int]]
      c = b
      c.store(a.load().put("y", 2))
      check a.load().len == 2 and b.load()["y"] == 2
      check a == b and a == c
      check a != newAtomRef(toTrieMap({"x": 1}))
      check hash(a) == hash(c)
      check $newAtomRef(3) == "AtomRef(3)"

  test "exchange and update return values":
    let r = newAtomRef("a")
    check r.exchange("b") == "a"
    check r.update(
      proc(s: string): string =
        s & "c"
    ) == "bc"
    check r.load() == "bc"

  test "version counts stores and refresh reloads on change":
    let r = newAtomRef(0)
    check r.version == 0
    var snapshot = 99
    var seen = -1
    check r.refresh(snapshot, seen) and snapshot == 0 and seen == 0
    check not r.refresh(snapshot, seen)
    r.store(1)
    discard r.exchange(2)
    r.update(
      proc(x: int): int =
        x + 1
    )
    check r.version == 3
    check r.refresh(snapshot, seen) and snapshot == 3 and seen == 3
    check not r.refresh(snapshot, seen)

  test "nil handles":
    let r = default(AtomRef[int])
    check r.isNil and $r == "AtomRef(nil)"
    expect ValueError:
      discard r.load()
    expect ValueError:
      r.store(1)
    expect ValueError:
      discard r.version
    var moved = newAtomRef(1)
    let taken = move(moved)
    check moved.isNil and taken.load() == 1

  test "the atom lives until the last handle goes away":
    checkNoLeaks:
      var handles: seq[AtomRef[TrieVec[int]]]
      block:
        let r = newAtomRef(toTrieVec([1, 2, 3]))
        for i in 0 ..< 10:
          handles.add r
      handles[3].store(toTrieVec([4]))
      check handles[0].load() == toTrieVec([4])
      handles.setLen(1)
      check handles[0].load().len == 1

  test "handles passed to threads see each other's updates":
    const workers = 4
    const perWorker = 1000
    proc worker(r: AtomRef[TrieMap[int, int]]) {.thread.} =
      for i in 0 ..< perWorker:
        r.update(
          proc(m: TrieMap[int, int]): TrieMap[int, int] =
            m.put(m.len, i)
        )

    proc watcher(r: AtomRef[TrieMap[int, int]]) {.thread.} =
      var snapshot: TrieMap[int, int]
      var seen = -1
      var last = 0
      while last < workers * perWorker:
        if r.refresh(snapshot, seen):
          doAssert snapshot.len >= last # versions only move forward
          last = snapshot.len

    checkNoLeaks:
      let shared = newAtomRef(initTrieMap[int, int]())
      var ts: array[workers, Thread[AtomRef[TrieMap[int, int]]]]
      var w: Thread[AtomRef[TrieMap[int, int]]]
      createThread(w, watcher, shared)
      for i in 0 ..< workers:
        createThread(ts[i], worker, shared)
      joinThreads(ts)
      joinThread(w)
      check shared.load().len == workers * perWorker
      check shared.version == workers * perWorker

  test "Atom's thread-safety check applies":
    const fixture = currentSourcePath().parentDir() / "fixtures" / "refatomref.nim"
    const src = currentSourcePath().parentDir().parentDir() / "src"
    const res = gorgeEx(
      quoteShell(getCurrentCompilerExe()) &
        " check --hints:off --skipParentCfg --threads:on --mm:arc --path:" &
        quoteShell(src) & " " & quoteShell(fixture)
    )
    check res.exitCode != 0
    check "holds Nim refs or closures" in res.output
