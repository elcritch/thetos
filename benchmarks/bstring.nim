## Benchmarks: `string` vs `ImmStr` vs `FlexStr`.
##
## Run with:
##   nim r -d:danger benchmarks/bstring.nim
##
## Results and discussion: docs/benchmark_std_string.md

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
    echo "| ", alignLeft(name, 44), " | ", align(shown, 10), " |"

proc text(n: int): string =
  ## Mixed ASCII and multi-byte UTF-8.
  const sample = "persistent wörld 😀 "
  result = newStringOfCap(n)
  while result.len < n:
    result.add sample
  result.setLen(n)

var rng = 88172645463325252'u64
proc next(n: int): int =
  rng = rng xor (rng shl 13)
  rng = rng xor (rng shr 7)
  rng = rng xor (rng shl 17)
  int(rng mod uint64(n))

const sizes = [16, 1024, 65536]

proc section(title: string) =
  echo ""
  echo "### ", title
  echo ""
  echo "| ", alignLeft("operation", 44), " | ", align("time/op", 10), " |"
  echo "|", repeat('-', 46), "|", repeat('-', 12), "|"

# Copying ---------------------------------------------------------------

section("Copying one value (into an array slot)")
for n in sizes:
  let s = text(n)
  let i = toImmStr(s)
  let f = toFlexStr(s)
  const N = 100_000
  var a: array[8, string]
  var b: array[8, ImmStr]
  var c: array[8, FlexStr]
  bench("string copy, " & $n & " B", N):
    for k in 0 ..< N:
      a[k and 7] = s
    sink0 += a[3].len
  bench("ImmStr copy, " & $n & " B", N):
    for k in 0 ..< N:
      b[k and 7] = i
    sink0 += b[3].len
  bench("FlexStr copy, " & $n & " B", N):
    for k in 0 ..< N:
      c[k and 7] = f
    sink0 += c[3].len

section("Persistent TrieMap update with 1 KiB values (path copying)")
block:
  const M = 10_000
  const N = 10_000
  let value = text(1024)
  var ms: TrieMap[int, string]
  var mi: TrieMap[int, ImmStr]
  for k in 0 ..< M:
    ms[k] = value
    mi[k] = toImmStr(value)
  let newS = text(1024)
  let newI = toImmStr(newS)
  bench("TrieMap[int, string].put (shared map)", N):
    for k in 0 ..< N:
      let m2 = ms.put(next(M), newS)
      sink0 += m2.len
  bench("TrieMap[int, ImmStr].put (shared map)", N):
    for k in 0 ..< N:
      let m2 = mi.put(next(M), newI)
      sink0 += m2.len

section("Atom.load of a 1 KiB value")
block:
  const N = 100_000
  var as1: Atom[string]
  var ai: Atom[ImmStr]
  as1.store(text(1024))
  ai.store(toImmStr(text(1024)))
  bench("Atom[string].load", N):
    for k in 0 ..< N:
      sink0 += as1.load().len
  bench("Atom[ImmStr].load", N):
    for k in 0 ..< N:
      sink0 += ai.load().len

# Reading ---------------------------------------------------------------

section("Hashing (8 equal values in separate allocations, rotated)")
for n in sizes:
  var ss: array[8, string]
  var ii: array[8, ImmStr]
  var ff: array[8, FlexStr]
  for k in 0 ..< 8:
    ss[k] = text(n)
    ii[k] = toImmStr(ss[k])
    ff[k] = toFlexStr(ss[k])
  let N = (if n >= 65536: 2_000 else: 100_000)
  bench("string hash, " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += hash(ss[k and 7])
  bench("ImmStr hash (cached after first), " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += hash(ii[k and 7])
  bench("FlexStr hash, " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += hash(ff[k and 7])

section("Equality of equal values in separate allocations")
for n in sizes:
  var ss: array[8, string]
  var ii: array[8, ImmStr]
  var ff: array[8, FlexStr]
  for k in 0 ..< 8:
    ss[k] = text(n)
    ii[k] = toImmStr(ss[k])
    ff[k] = toFlexStr(ss[k])
  let N = (if n >= 65536: 2_000 else: 100_000)
  bench("string ==, " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += ord(ss[k and 7] == ss[(k + 1) and 7])
  bench("ImmStr ==, " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += ord(ii[k and 7] == ii[(k + 1) and 7])
  bench("FlexStr ==, " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += ord(ff[k and 7] == ff[(k + 1) and 7])

section("Random byte access, 64 KiB")
block:
  const N = 1_000_000
  let s = text(65536)
  let i = toImmStr(s)
  let f = toFlexStr(s)
  var idx = newSeq[int](N)
  for k in 0 ..< N:
    idx[k] = next(65536)
  bench("string s[i]", N):
    var acc = 0
    for k in 0 ..< N:
      acc += ord(s[idx[k]])
    sink0 += acc
  bench("ImmStr s[i]", N):
    var acc = 0
    for k in 0 ..< N:
      acc += ord(i[idx[k]])
    sink0 += acc
  bench("FlexStr s[i]", N):
    var acc = 0
    for k in 0 ..< N:
      acc += ord(f[idx[k]])
    sink0 += acc

section("Iterating every byte, 64 KiB (per byte)")
block:
  let s = text(65536)
  let i = toImmStr(s)
  let f = toFlexStr(s)
  bench("string items", s.len):
    var acc = 0
    for c in s:
      acc += ord(c)
    sink0 += acc
  bench("ImmStr items", s.len):
    var acc = 0
    for c in i:
      acc += ord(c)
    sink0 += acc
  bench("FlexStr items", s.len):
    var acc = 0
    for c in f:
      acc += ord(c)
    sink0 += acc

# Building and editing ----------------------------------------------------

section("Appending 64 KiB one byte at a time (per byte)")
block:
  const N = 65536
  bench("string add", N):
    var s: string
    for k in 0 ..< N:
      s.add char(97 + (k and 15))
    sink0 += s.len
  bench("FlexStr add", N):
    var f: FlexStr
    for k in 0 ..< N:
      f.add char(97 + (k and 15))
    sink0 += f.len

section("Concatenating two equal-size values")
for n in [65536, 1048576]:
  let N = (if n > 65536: 100 else: 1_000)
  let s = text(n)
  let i = toImmStr(s)
  let f = toFlexStr(s)
  bench("string &, " & $n & " B each", N):
    for k in 0 ..< N:
      sink0 += (s & s).len
  bench("ImmStr &, " & $n & " B each", N):
    for k in 0 ..< N:
      sink0 += (i & i).len
  bench("FlexStr &, " & $n & " B each", N):
    for k in 0 ..< N:
      sink0 += (f & f).len

section("Inserting 8 bytes in the middle (new version each time)")
for n in [65536, 1048576]:
  let s = text(n)
  let f = toFlexStr(s)
  let N = (if n > 65536: 200 else: 2_000)
  bench("string copy + insert, " & $n & " B", N):
    for k in 0 ..< N:
      var t = s
      t.insert("inserted", next(n))
      sink0 += t.len
  bench("FlexStr insert, " & $n & " B", N):
    for k in 0 ..< N:
      sink0 += f.insert(next(n), "inserted").len

section("Slicing half of a 1 MiB value")
block:
  const n = 1048576
  const N = 200
  let s = text(n)
  let i = toImmStr(s)
  let f = toFlexStr(s)
  bench("string s[a .. b]", N):
    for k in 0 ..< N:
      let a = next(n div 2)
      sink0 += s[a .. a + n div 2].len
  bench("ImmStr s[a .. b]", N):
    for k in 0 ..< N:
      let a = next(n div 2)
      sink0 += i[a .. a + n div 2].len
  bench("FlexStr s[a .. b]", N):
    for k in 0 ..< N:
      let a = next(n div 2)
      sink0 += f[a .. a + n div 2].len

section("Editing a 64 KiB document 1000 times, keeping every version")
block:
  const n = 65536
  const edits = 1000
  let s = text(n)
  var memString, memFlex: int
  bench("seq[string] history (per edit)", edits):
    let before = getOccupiedMem()
    var history = @[s]
    for k in 0 ..< edits:
      var next = history[^1]
      next[next(next.len)] = 'x'
      history.add next
    memString = getOccupiedMem() - before
    sink0 += history.len
  bench("seq[FlexStr] history (per edit)", edits):
    let before = getOccupiedMem()
    var history = @[toFlexStr(s)]
    for k in 0 ..< edits:
      let last = history[^1]
      let at = next(last.len)
      history.add last.replace(at .. at, "x")
    memFlex = getOccupiedMem() - before
    sink0 += history.len
  echo ""
  echo "Memory held by the 1001 versions: `seq[string]` ",
    formatFloat(memString / 1048576, ffDecimal, 1),
    " MiB, `seq[FlexStr]` ",
    formatFloat(memFlex / 1048576, ffDecimal, 1),
    " MiB."

# Conversion ----------------------------------------------------------------

section("Converting from and to string, 64 KiB")
block:
  const N = 1_000
  let s = text(65536)
  let i = toImmStr(s)
  let f = toFlexStr(s)
  bench("toImmStr(string)", N):
    for k in 0 ..< N:
      sink0 += toImmStr(s).len
  bench("toFlexStr(string)", N):
    for k in 0 ..< N:
      sink0 += toFlexStr(s).len
  bench("$ImmStr", N):
    for k in 0 ..< N:
      sink0 += len($i)
  bench("$FlexStr", N):
    for k in 0 ..< N:
      sink0 += len($f)

if sink0 == 42:
  echo ""
