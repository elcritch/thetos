## FlexVec tests. Built with `-d:thetosDebug` (for `checkInvariants`) and
## `-d:thetosTrackAllocs` (for leak checks); see tflexvec.nims.

import std/[unittest, random, hashes, options]
when defined(thetosTestLocal):
  import thetos/local # the same tests, against the thread-local variants
else:
  import thetos/[flexvec, trievec]
import ./fixtures/falliblecopy

proc toSeq[T](v: FlexVec[T]): seq[T] =
  for x in v:
    result.add x

proc agrees[T](v: FlexVec[T], model: seq[T]): bool =
  discard v.checkInvariants()
  if v.len != model.len:
    return false
  var i = 0
  for x in v:
    if x != model[i]:
      return false
    inc i
  for j in 0 ..< model.len:
    if v[j] != model[j]:
      return false
  true

proc rangeVec(a, b: int): FlexVec[int] =
  for i in a ..< b:
    result.add i

suite "FlexVec":
  test "empty vector":
    let v = initFlexVec[int]()
    check v.len == 0
    check v == default(FlexVec[int])
    check $v == "[]"
    check toSeq(v).len == 0
    expect IndexDefect:
      discard v[0]
    var w = v
    expect IndexDefect:
      discard w.pop()
    check (v & v).len == 0
    check v.take(3).len == 0
    check v.drop(3).len == 0
    check v[0 .. -1].len == 0
    discard v.checkInvariants()

  test "basic API":
    var v = toFlexVec([1, 2, 3])
    let w = v.pushBack(4)
    v[0] = 10
    check v == toFlexVec([10, 2, 3])
    check w == toFlexVec([1, 2, 3, 4])
    check v[^1] == 3 and v.first == 10 and v.last == 3
    check v.high == 2 and v.low == 0
    check $v == "[10, 2, 3]"
    check v.put(1, 7)[1] == 7 and v[1] == 2
    check v.update(
      2,
      proc(x: int): int =
        x * 2,
    )[2] == 6
    check v.popBack() == toFlexVec([10, 2])
    check v.pop() == 3 and v.len == 2
    var pairs: seq[(int, int)]
    for p in w.pairs:
      pairs.add p
    check pairs == @[(0, 1), (1, 2), (2, 3), (3, 4)]
    check hash(toFlexVec([1, 2])) == hash(toFlexVec([1, 2]))
    check toFlexVec(["a"]) & toFlexVec(["b"]) == toFlexVec(["a", "b"])

  test "flex operations":
    let v = rangeVec(0, 100)
    check toSeq(v.drop(30)) == toSeq(rangeVec(30, 100))
    check toSeq(v.take(30)) == toSeq(rangeVec(0, 30))
    check toSeq(v[10 .. 19]) == toSeq(rangeVec(10, 20))
    check toSeq(v[^10 .. ^1]) == toSeq(rangeVec(90, 100))
    check v.pushFront(-1)[0] == -1 and v.pushFront(-1).len == 101
    check toSeq(v.insert(50, -5))[49 .. 51] == @[49, -5, 50]
    check v.insert(100, -5)[100] == -5
    check toSeq(v.erase(0))[0] == 1 and v.erase(99).len == 99
    expect IndexDefect:
      discard v.insert(101, 0)
    expect IndexDefect:
      discard v.erase(100)
    expect IndexDefect:
      discard v[5 .. 100]
    var u = v
    u.add(v)
    check toSeq(u) == toSeq(v) & toSeq(v)
    u.add(u) # aliasing
    check u.len == 400 and u[399] == 99
    discard u.checkInvariants()

  test "equality across trees with different leaf boundaries":
    var r = initRand(11)
    proc pieces(n: int, r: var Rand): FlexVec[int] =
      var i = 0
      while i < n:
        let k = min(1 + r.rand(40), n - i)
        result = result & rangeVec(i, i + k)
        i += k

    for n in [1, 31, 32, 33, 500, 5000]:
      let a = rangeVec(0, n)
      let b = pieces(n, r)
      check b.checkInvariants().relaxed > 0 or n <= 33
      check a == b and b == a
      check a.drop(1) == b.drop(1)
      for i in [0, n div 2, n - 1]:
        check a != b.put(i, -1) and b.put(i, -1) != a
      let s = toFlexVec(["x", "y"]) & toFlexVec(["z"])
      check s == toFlexVec(["x", "y", "z"])
      check s != toFlexVec(["x", "y", "w"])
      var c: FlexVec[char]
      var model: seq[char]
      while c.len < n:
        var piece: FlexVec[char]
        for k in 0 .. r.rand(150):
          piece.add char(ord('a') + (c.len + k) mod 26)
        c = c & piece
      for x in c:
        model.add x
      check c == toFlexVec(model) and toFlexVec(model) == c
      model[^1] = '!'
      check c != toFlexVec(model)

  test "converts from TrieVec":
    let t = toTrieVec([1, 2, 3, 4])
    check toFlexVec(t) == toFlexVec([1, 2, 3, 4])
    var big: TrieVec[int]
    for i in 0 ..< 5000:
      big.add i
    let f = toFlexVec(big)
    check f.len == 5000 and f[4999] == 4999
    check f.checkInvariants().relaxed == 0

  test "appends stay regular":
    var v: FlexVec[int]
    for i in 0 ..< 40_000:
      v.add i
    let stats = v.checkInvariants()
    check stats.relaxed == 0
    # 39,968 elements in the tree need four levels (32^3 = 32,768).
    check stats.depth == 4
    for i in countdown(39_999, 0):
      check v.pop() == i
      if i mod 997 == 0:
        discard v.checkInvariants()
    check v.len == 0

  test "chunk iteration keeps its version alive during reassignment":
    var v = rangeVec(0, 2100)
    var seen = 0
    for (p, n) in v.chunks:
      v = default(FlexVec[int])
      for i in 0 ..< n:
        check p[i] == seen
        inc seen
    check seen == 2100

  test "one-byte elements use wider leaves across tree levels":
    var model = newSeq[byte](128 * 65 + 1)
    for i in 0 ..< model.len:
      model[i] = byte((i xor (i shr 7)) and 255)
    let v = toFlexVec(model)
    let stats = v.checkInvariants()
    check stats.leaves == 65 and stats.depth == 3 and stats.relaxed == 0
    check v.agrees(model)

    var seen = 0
    for (_, n) in v.chunks:
      check n == min(128, model.len - seen)
      seen += n
    check seen == model.len

    let left = v.take(4205)
    let right = v.drop(4011)
    check (left & right).agrees(model[0 ..< 4205] & model[4011 .. ^1])
    var edited = left
    edited.add [byte(255), byte(0)]
    check edited.agrees(model[0 ..< 4205] & @[byte(255), byte(0)])
    check edited.pop() == 0 and left.len == 4205

  test "appending past high(int) preserves shared vectors":
    checkNoLeaks:
      var v = toFlexVec([1])
      for i in 0 ..< sizeof(int) * 8 - 2:
        v.add(v)
      let size = v.len
      expect OverflowDefect:
        v.add(v)
      check v.len == size
      check v.last == 1

      var full = v & v.take(size - 1)
      check full.len == high(int)
      expect OverflowDefect:
        full.add(2)
      expect OverflowDefect:
        discard full.pushBack(2)
      check full.len == high(int)
      check full.last == 1
      var almostFull = full.take(high(int) - 1)
      expect OverflowDefect:
        almostFull.add([2, 3])
      check almostFull.len == high(int) - 1 and almostFull.last == 1
      expect IndexDefect:
        discard v[0 .. high(int)]

  test "wide leaves support indexing near high(int)":
    checkNoLeaks:
      var v = toFlexVec([byte(3), byte(7)])
      for i in 0 ..< sizeof(int) * 8 - 3:
        v.add(v)
      let full = v & v.take(v.len - 1)
      check full.len == high(int)
      check full[v.len - 1] == 7 and full[v.len] == 3
      check full[high(int) - 2] == 7 and full[^1] == 3

  test "deep trees from repeated concatenation":
    var v = rangeVec(0, 37)
    var model = toSeq(v)
    while v.len < 1_500_000:
      v = v & v.drop(3)
      model = model & model[3 .. ^1]
    let stats = v.checkInvariants()
    check stats.depth >= 4
    check v.len == model.len
    var r = initRand(5)
    for _ in 0 ..< 2000:
      let i = r.rand(v.high)
      check v[i] == model[i]
    for _ in 0 ..< 40:
      let a = r.rand(v.high)
      let b = r.rand(a .. v.high)
      let s = v[a .. b]
      discard s.checkInvariants()
      check s.len == b - a + 1
      check s[0] == model[a] and s[^1] == model[b]
      let joined = v.take(a) & s & v.drop(b + 1)
      discard joined.checkInvariants()
      check joined.len == v.len
      for _ in 0 ..< 20:
        let i = r.rand(joined.high)
        check joined[i] == model[i]

  test "random operations agree with seq and snapshots stay frozen":
    checkNoLeaks:
      for seed in 1 .. 12:
        var r = initRand(seed)
        var v: FlexVec[int]
        var model: seq[int]
        var snaps: seq[(FlexVec[int], seq[int])]
        for step in 0 ..< 1200:
          let x = r.rand(1_000_000)
          case r.rand(12)
          of 0, 1:
            for _ in 0 ..< r.rand(1 .. 80):
              v.add x
              model.add x
          of 2:
            if v.len > 0:
              check v.pop() == model.pop()
          of 3:
            if v.len > 0:
              let i = r.rand(v.high)
              v[i] = x
              model[i] = x
          of 4:
            let n = r.rand(v.len)
            v = v.take(n)
            model.setLen(n)
          of 5:
            let n = r.rand(v.len)
            v = v.drop(n)
            model = model[n .. ^1]
          of 6:
            # Concatenate a piece of a snapshot or of itself.
            let (src, srcModel) =
              if snaps.len > 0 and r.rand(1) == 0:
                snaps[r.rand(snaps.high)]
              else:
                (v, model)
            if src.len > 0:
              let a = r.rand(src.high)
              let b = r.rand(a .. src.high)
              v.add(src[a .. b])
              model.add srcModel[a .. b]
          of 7:
            let i = r.rand(v.len)
            v = v.insert(i, x)
            model.insert(x, i)
          of 8:
            if v.len > 0:
              let i = r.rand(v.high)
              v = v.erase(i)
              model.delete(i)
          of 9:
            v = v.pushFront(x)
            model.insert(x, 0)
          of 10:
            if v.len > 0:
              let a = r.rand(v.high)
              let b = r.rand(a .. v.high)
              v = v[a .. b]
              model = model[a .. b]
          else:
            if v.len < 20_000:
              v.add(v)
              model = model & model
          if v.len > 30_000:
            v = v.take(5_000)
            model.setLen(5_000)
          if step mod 7 == 0:
            snaps.add (v, model)
          if step mod 25 == 0:
            check agrees(v, model)
          else:
            discard v.checkInvariants()
            check v.len == model.len
            if v.len > 0:
              let i = r.rand(v.high)
              check v[i] == model[i]
        check agrees(v, model)
        for (s, m) in snaps:
          check agrees(s, m)

  test "strings are copied and destroyed":
    checkNoLeaks:
      var v: FlexVec[string]
      for i in 0 ..< 3000:
        v.add $i
      let w = v[100 .. 2900] & v.drop(2000)
      check w[0] == "100" and w[^1] == "2999"
      var u = w.insert(5, "x").erase(0)
      u[3] = "y"
      check u[3] == "y" and w[4] == "104"

  test "nested containers":
    checkNoLeaks:
      var v: FlexVec[FlexVec[int]]
      for i in 0 ..< 200:
        v.add rangeVec(0, i)
      let w = v & v.drop(50)
      check w[250][9] == 9
      check w.len == 350

proc fallible(n: int, offset = 0): FlexVec[FallibleCopy] =
  for i in 0 ..< n:
    result.add fallibleValue(offset + i)

suite "FlexVec exception safety":
  vectorCopyTests(toFlexVec)

  test "failed short concatenation preserves the destination":
    checkNoLeaks:
      var v = fallible(3)
      let source = v
      let other = fallible(3, 10)
      expectCopyFailure(1):
        v.add(other)
      check v == source
      expectCopyFailure(1):
        discard source.pushFront(fallibleValue(-1))
      check source.len == 3

  test "failed slicing, insertion and conversion release their allocations":
    checkNoLeaks:
      let source = fallible(35)
      let trie = toTrieVec([fallibleValue(1), fallibleValue(2), fallibleValue(3)])
      expectCopyFailure(1):
        discard source.drop(1)
      expectCopyFailure(1):
        discard source[1 .. 3]
      expectCopyFailure(1):
        discard source.insert(1, fallibleValue(-1))
      expectCopyFailure(1):
        discard source.erase(1)
      expectCopyFailure(1):
        discard toFlexVec(trie)
      check source.len == 35
      check trie.len == 3

  test "failing copies leave vectors unchanged and leak nothing":
    checkNoLeaks:
      var failures = 0
      for budget in 0 ..< 120:
        var v = fallible(700)
        v = v.drop(13) # relaxed left edge
        let snapshot = v
        let other = fallible(45, 1000).drop(7)
        let ops = [
          proc(v: var FlexVec[FallibleCopy]) =
            v.add(other),
          proc(v: var FlexVec[FallibleCopy]) =
            v.add(fallibleValue(-1)),
          proc(v: var FlexVec[FallibleCopy]) =
            v[400] = fallibleValue(-2),
          proc(v: var FlexVec[FallibleCopy]) =
            v[v.high] = fallibleValue(-3),
        ]
        for op in ops:
          var w = v
          copiesBeforeFailure = budget
          try:
            op(w)
          except ValueError:
            inc failures
            check w == snapshot
          copiesBeforeFailure = -1
          discard w.checkInvariants()
        check v == snapshot
      check failures > 0

suite "FlexVec updateIt":
  test "updates one element of a concatenated vector":
    let v = toFlexVec([1, 2, 3]) & toFlexVec([4, 5])
    let w = v.updateIt(3, it * 10)
    check v[3] == 4 and w[3] == 40 and w.len == 5

suite "FlexVec get":
  test "get and getOrDefault do not raise":
    let v = toFlexVec([10, 20]) & toFlexVec([30])
    check v.get(2) == some(30)
    check v.get(3).isNone and v.get(-1).isNone
    check v.getOrDefault(0) == 10 and v.getOrDefault(9, -1) == -1

  test "get represents a stored nil as none":
    var fallback: int
    let missing: ptr int = nil
    let v = toFlexVec([missing, addr fallback])
    check v.get(0).isNone and v.get(1).get == addr fallback
    check v.getOrDefault(0, addr fallback) == nil
