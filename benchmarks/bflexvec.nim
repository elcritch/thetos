## Benchmarks: FlexVec iteration, comparison, concatenation and edits at
## the front, and FlexDeque for the edits where the two differ.
##
## Run with:
##   nim r -d:danger benchmarks/bflexvec.nim

import std/[monotimes, times, strutils, hashes]
import thetos

const Runs = 7

var sink0: int # defeats dead-code elimination

template bench(name: string, ops: int, body: untyped) =
  block:
    var best = high(int64)
    for run in 0 ..< Runs:
      let t0 = getMonoTime()
      body
      let dt = (getMonoTime() - t0).inNanoseconds
      if dt < best:
        best = dt
    let perOp = best.float / ops.float
    let shown =
      if perOp >= 100_000:
        formatFloat(perOp / 1000, ffDecimal, 1) & " µs"
      else:
        formatFloat(perOp, ffDecimal, 1) & " ns"
    echo "| ", alignLeft(name, 48), " | ", align(shown, 10), " |"

var rng = 88172645463325252'u64
proc next(n: int): int =
  rng = rng xor (rng shl 13)
  rng = rng xor (rng shr 7)
  rng = rng xor (rng shl 17)
  int(rng mod uint64(n))

proc section(title: string) =
  echo ""
  echo "### ", title
  echo ""
  echo "| ", alignLeft("operation", 48), " | ", align("time/op", 10), " |"
  echo "|", repeat('-', 50), "|", repeat('-', 12), "|"

proc regular(n: int): FlexVec[int] =
  for i in 0 ..< n:
    result.add i

proc relaxed(n: int): FlexVec[int] =
  ## Same elements as `regular(n)`, built from concatenated pieces of
  ## random length so the tree holds size tables.
  var i = 0
  while i < n:
    let k = min(1 + next(60), n - i)
    var piece: FlexVec[int]
    for j in i ..< i + k:
      piece.add j
    result = result & piece
    i += k

proc strings(n: int): FlexVec[string] =
  for i in 0 ..< n:
    result.add "item-" & $i

const sizes = [1_000, 100_000]

section("Iteration and comparison")
for n in sizes:
  let reps = 10_000_000 div n
  let a = regular(n)
  let b = relaxed(n)
  let b2 = relaxed(n)
  bench("items, regular, " & $n, n * reps):
    for r in 0 ..< reps:
      for x in a:
        sink0 += x
  bench("items, relaxed, " & $n, n * reps):
    for r in 0 ..< reps:
      for x in b:
        sink0 += x
  bench("== regular vs relaxed, " & $n, n * reps):
    for r in 0 ..< reps:
      sink0 += ord(a == b)
  bench("== relaxed vs relaxed, " & $n, n * reps):
    for r in 0 ..< reps:
      sink0 += ord(b == b2)
  bench("hash, relaxed, " & $n, n * reps):
    for r in 0 ..< reps:
      sink0 += hash(b)

section("Indexing")
for n in sizes:
  let a = regular(n)
  let b = relaxed(n)
  const N = 10_000_000
  var idx = newSeq[int](4096)
  for k in 0 ..< idx.len:
    idx[k] = next(n)
  bench("v[i] random, regular, " & $n, N):
    for k in 0 ..< N:
      sink0 += a[idx[k and 4095]]
  bench("v[i] random, relaxed, " & $n, N):
    for k in 0 ..< N:
      sink0 += b[idx[k and 4095]]
  bench("v[i] sequential, regular, " & $n, N):
    var i = 0
    for k in 0 ..< N:
      sink0 += a[i]
      inc i
      if i == n:
        i = 0
  bench("v[i] = x random, unique, " & $n, N div 10):
    var v = a
    for k in 0 ..< N div 10:
      v[idx[k and 4095]] = k
    sink0 += v[0]

section("Concatenation")
for n in sizes:
  let a = regular(n)
  let b = relaxed(n)
  const N = 20_000
  bench("a & b, " & $n & " + " & $n, N):
    for k in 0 ..< N:
      sink0 += (a & b).len
  let reps = 1_000_000 div n # keeps each sample long enough to time
  let w50 = regular(50)
  let w1000 = regular(1000)
  bench("unique v.add(w) of 50, until " & $n, reps * (n div 50)):
    for r in 0 ..< reps:
      var v: FlexVec[int]
      while v.len < n:
        v.add w50
      sink0 += v.len
  bench("unique v.add(w) of 1000, until " & $(n * 10), reps * (n div 100)):
    for r in 0 ..< reps:
      var v: FlexVec[int]
      while v.len < n * 10:
        v.add w1000
      sink0 += v.len
  let s = strings(n)
  bench("strings: s & s, " & $n, N):
    for k in 0 ..< N:
      sink0 += (s & s).len

section("Edits in the middle and at the front")
for n in sizes:
  let a = regular(n)
  let reps = 1_000_000 div n
  const N = 20_000
  bench("insert middle, persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.insert(n div 2, k).len
  bench("erase middle, persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.erase(n div 2).len
  bench("insert random, unique, into " & $n, 20_000):
    for r in 0 ..< 10:
      var v = a
      for k in 0 ..< 2000:
        v = v.insert(next(v.len), k)
      sink0 += v.len
  bench("drop(1), persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.drop(1).len
  bench("drop(1) repeated, unique, half of " & $n, reps * (n div 2)):
    for r in 0 ..< reps:
      var v = a
      for k in 0 ..< n div 2:
        v = v.drop(1)
      sink0 += v.len
  bench("pushFront, persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.pushFront(k).len
  bench("pushFront repeated, unique, from empty to " & $n, reps * n):
    for r in 0 ..< reps:
      var v: FlexVec[int]
      for k in 0 ..< n:
        v = v.pushFront(k)
      sink0 += v.len

when declared(FlexDeque): # older commits have no FlexDeque
  section("FlexDeque: the same operations with a head leaf")
  for n in sizes:
    # Same inputs and loops as the FlexVec rows above.
    let a = toFlexDeque(regular(n))
    let b = toFlexDeque(relaxed(n))
    let reps = 1_000_000 div n
    const N = 20_000
    const M = 10_000_000
    var idx = newSeq[int](4096)
    for k in 0 ..< idx.len:
      idx[k] = next(n)
    bench("deque: v[i] random, regular, " & $n, M):
      for k in 0 ..< M:
        sink0 += a[idx[k and 4095]]
    bench("deque: v[i] = x random, unique, " & $n, M div 10):
      var v = a
      for k in 0 ..< M div 10:
        v[idx[k and 4095]] = k
      sink0 += v[0]
    bench("deque: a & b, " & $n & " + " & $n, N):
      for k in 0 ..< N:
        sink0 += (a & b).len
    bench("deque: insert middle, persistent, " & $n, N):
      for k in 0 ..< N:
        sink0 += a.insert(n div 2, k).len
    bench("deque: erase middle, persistent, " & $n, N):
      for k in 0 ..< N:
        sink0 += a.erase(n div 2).len
    bench("deque: drop(1), persistent, " & $n, N):
      for k in 0 ..< N:
        sink0 += a.drop(1).len
    bench("deque: drop(1) repeated, unique, half of " & $n, reps * (n div 2)):
      for r in 0 ..< reps:
        var v = a
        for k in 0 ..< n div 2:
          v = v.drop(1)
        sink0 += v.len
    bench("deque: pushFront, persistent, " & $n, N):
      for k in 0 ..< N:
        sink0 += a.pushFront(k).len
    bench("deque: pushFront repeated, unique, from empty to " & $n, reps * n):
      for r in 0 ..< reps:
        var v: FlexDeque[int]
        for k in 0 ..< n:
          v = v.pushFront(k)
        sink0 += v.len

echo ""
echo "sink: ", sink0
