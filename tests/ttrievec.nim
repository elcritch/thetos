import std/[unittest, random]
import thetos/trievec

type Counted = object ## Element that counts how often it is copied.
  id: int

var copies = 0

proc `=copy`(dst: var Counted, src: Counted) =
  inc copies
  dst.id = src.id

proc `=dup`(src: Counted): Counted =
  inc copies
  Counted(id: src.id)

proc checkModel[T](v: TrieVec[T], model: seq[T]) =
  check v.len == model.len
  var i = 0
  for x in v:
    check x == model[i]
    inc i
  check i == model.len
  for j in 0 ..< model.len:
    check v[j] == model[j]

suite "TrieVec":
  test "empty vector":
    let v = initTrieVec[int]()
    check v.len == 0
    check $v == "[]"
    expect IndexDefect:
      discard v[0]

  test "push, set and pop keep versions":
    var v = toTrieVec([1, 2, 3])
    let w = v.pushBack(4)
    v[0] = 10
    check v.len == 3 and w.len == 4
    check v[0] == 10 and w[0] == 1
    check w[^1] == 4
    let u = w.popBack()
    check u == toTrieVec([1, 2, 3])
    check w.len == 4
    check w.put(1, 20)[1] == 20
    check w[1] == 2
    check w.update(
      3,
      proc(x: int): int =
        x * 10,
    )[3] == 40

  test "growth and shrink across tree levels":
    # 32 (tail only), 1056 (root overflow), 33824 (third level)
    const n = 40_000
    var v = initTrieVec[int]()
    var model: seq[int]
    var snaps: seq[(TrieVec[int], seq[int])]
    for i in 0 ..< n:
      v.add(i)
      model.add(i)
      if i in [0, 31, 32, 33, 1055, 1056, 1057, 33823, 33824, 33825]:
        snaps.add((v, model))
    checkModel(v, model)
    while v.len > 0:
      check v.pop() == model.pop()
      if v.len in [33824, 1056, 33, 32, 31, 1]:
        checkModel(v, model)
    check v.len == 0
    for (s, m) in snaps:
      checkModel(s, m)

  test "random edits agree with seq":
    var r = initRand(5)
    var v = initTrieVec[string]()
    var model: seq[string]
    var snaps: seq[(TrieVec[string], seq[string])]
    for step in 0 ..< 30_000:
      let op = r.rand(9)
      if op < 5 or model.len == 0:
        v.add($step)
        model.add($step)
      elif op < 8:
        let i = r.rand(model.high)
        v[i] = "s" & $step
        model[i] = "s" & $step
      else:
        check v.pop() == model.pop()
      if step mod 3000 == 0:
        snaps.add((v, model))
    checkModel(v, model)
    for (s, m) in snaps:
      checkModel(s, m)

  test "take, concat, equality and hash":
    let v = toTrieVec([1, 2, 3, 4, 5])
    check v.take(2) == toTrieVec([1, 2])
    check v & toTrieVec([6]) == toTrieVec([1, 2, 3, 4, 5, 6])
    check hash(v) == hash(toTrieVec([1, 2, 3, 4, 5]))
    check $toTrieVec(["a"]) == "[\"a\"]"
    var total = 0
    for i, x in v:
      total += i * x
    check total == 0 * 1 + 1 * 2 + 2 * 3 + 3 * 4 + 4 * 5

  test "pop moves elements out of an unshared vector":
    var v = initTrieVec[Counted]()
    for i in 0 ..< 100: # spans tree leaves and the tail
      v.add(Counted(id: i))
    copies = 0
    for i in countdown(99, 0):
      check v.pop().id == i
    check copies == 0

  test "pop from a shared vector leaves the original":
    var a = initTrieVec[seq[int]]()
    for i in 0 ..< 100:
      a.add(@[i])
    var b = a
    for i in countdown(99, 0):
      check b.pop() == @[i]
    check a.len == 100
    check a[99] == @[99]
