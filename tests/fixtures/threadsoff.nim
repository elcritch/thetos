## Built and run with `--threads:off -d:thetosTrackAllocs` by tthreadsoff.nim.
## Without threads the containers use plain reference counts, and Atom still
## works.
import thetos
import thetos/private/core

static:
  doAssert not thetosAtomicRc

let before = liveAllocations()
block:
  var m: TrieMap[int, string]
  var s: TrieSet[int]
  var v: TrieVec[int]
  var f: FlexVec[int]
  for i in 0 ..< 2000:
    m[i] = $i
    s.incl i
    v.add i
    f.add i
  let m0 = m
  let s0 = s
  let v0 = v
  let f0 = f
  for i in 0 ..< 2000:
    m[i] = "x"
    s.excl i
    v[i] = -i
  m.del 7
  f = f.drop(10) & f0
  doAssert m0.len == 2000 and m0[7] == "7" and m.len == 1999
  doAssert s0.len == 2000 and s.len == 0
  doAssert v0[5] == 5 and v[5] == -5
  doAssert f0.len == 2000 and f.len == 3990 and f[0] == 10
  let b = box(@[1, 2])
  let c = b.update(
    proc(x: seq[int]): seq[int] =
      x & 3
  )
  doAssert b[] == @[1, 2] and c[] == @[1, 2, 3]

  var a = initAtom(m0)
  a.update(
    proc(x: TrieMap[int, string]): TrieMap[int, string] =
      x.put(-1, "atom")
  )
  doAssert a.load()[-1] == "atom" and m0.len == 2000
doAssert liveAllocations() == before, $(liveAllocations() - before) & " leaked"
echo "threads-off ok"
