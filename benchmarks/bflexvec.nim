## Benchmarks: FlexVec iteration, comparison, concatenation and edits at
## the front.
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

section("Concatenation")
for n in sizes:
  let a = regular(n)
  let b = relaxed(n)
  const N = 20_000
  bench("a & b, " & $n & " + " & $n, N):
    for k in 0 ..< N:
      sink0 += (a & b).len
  bench("unique v.add(w) of 50, until " & $n, n div 50):
    var v: FlexVec[int]
    let w = regular(50)
    while v.len < n:
      v.add w
    sink0 += v.len
  bench("unique v.add(w) of 1000, until " & $(n * 10), n div 100):
    var v: FlexVec[int]
    let w = regular(1000)
    while v.len < n * 10:
      v.add w
    sink0 += v.len
  let s = strings(n)
  bench("strings: s & s, " & $n, N):
    for k in 0 ..< N:
      sink0 += (s & s).len

section("Edits in the middle and at the front")
for n in sizes:
  let a = regular(n)
  const N = 20_000
  bench("insert middle, persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.insert(n div 2, k).len
  bench("erase middle, persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.erase(n div 2).len
  bench("insert random, unique, into " & $n, 2000):
    var v = a
    for k in 0 ..< 2000:
      v = v.insert(next(v.len), k)
    sink0 += v.len
  bench("drop(1), persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.drop(1).len
  bench("drop(1) repeated, unique, half of " & $n, n div 2):
    var v = a
    for k in 0 ..< n div 2:
      v = v.drop(1)
    sink0 += v.len
  bench("pushFront, persistent, " & $n, N):
    for k in 0 ..< N:
      sink0 += a.pushFront(k).len
  bench("pushFront repeated, unique, from empty to " & $n, n):
    var v: FlexVec[int]
    for k in 0 ..< n:
      v = v.pushFront(k)
    sink0 += v.len

echo ""
echo "sink: ", sink0
