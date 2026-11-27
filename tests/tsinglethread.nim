## Plain (non-atomic) reference counts with `-d:thetosSingleThread` (see
## tsinglethread.nims). `nim testSingleThread` also runs the container
## suites in this mode.

import std/[unittest, os, strutils]
import thetos
import thetos/private/core

static:
  doAssert not thetosAtomicRc

suite "single-thread reference counts":
  test "atom is rejected at compile time":
    const fixture = currentSourcePath().parentDir() / "fixtures" / "useatom.nim"
    const src = currentSourcePath().parentDir().parentDir() / "src"
    const res = gorgeEx(
      quoteShell(getCurrentCompilerExe()) & " check --hints:off --skipParentCfg" &
        " -d:thetosSingleThread --path:" & quoteShell(src) & " " & quoteShell(fixture)
    )
    check res.exitCode != 0
    check "cannot be used with -d:thetosSingleThread" in res.output

  test "root module omits Atom":
    check not declared(Atom)

  test "copies share and updates path-copy":
    let before = liveAllocations()
    block:
      var m: TrieMap[int, string]
      var s: TrieSet[int]
      var v: TrieVec[int]
      for i in 0 ..< 2000:
        m[i] = $i
        s.incl i
        v.add i
      let m0 = m
      let s0 = s
      let v0 = v
      for i in 0 ..< 2000:
        m[i] = "x"
        s.excl i
        v[i] = -i
      m.del 7
      check m0.len == 2000 and m0[7] == "7" and m.len == 1999
      check s0.len == 2000 and s.len == 0
      check v0[5] == 5 and v[5] == -5
      let b = box(@[1, 2])
      let c = b.update(
        proc(x: seq[int]): seq[int] =
          x & 3
      )
      check b[] == @[1, 2] and c[] == @[1, 2, 3]
    check liveAllocations() == before
