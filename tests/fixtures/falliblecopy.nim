import std/unittest
import thetos/box
import thetos/private/core

type FallibleCopy* = object
  value*: Box[int]

var copiesBeforeFailure* = -1

proc `=copy`*(dst: var FallibleCopy, src: FallibleCopy) =
  dst.value = src.value
  if copiesBeforeFailure == 0:
    raise newException(ValueError, "copy failed")
  if copiesBeforeFailure > 0:
    dec copiesBeforeFailure

proc `==`*(a, b: FallibleCopy): bool =
  a.value[] == b.value[]

proc fallibleValue*(id: int): FallibleCopy =
  FallibleCopy(value: box(id))

template checkNoLeaks*(body: untyped) =
  let before = liveAllocations()
  block:
    body
  check liveAllocations() == before

template expectCopyFailure*(budget: int, body: untyped) =
  block:
    copiesBeforeFailure = budget
    defer:
      copiesBeforeFailure = -1
    expect ValueError:
      body

template vectorCopyTests*(toVector: untyped) =
  test "failed element copies release partial constructors and appends":
    checkNoLeaks:
      let source = [fallibleValue(1), fallibleValue(2), fallibleValue(3)]
      expectCopyFailure(1):
        discard toVector(source)
    checkNoLeaks:
      let source = [fallibleValue(1), fallibleValue(2), fallibleValue(3)]
      var v = toVector(source.toOpenArray(0, 0))
      expectCopyFailure(1):
        v.add(source)
      check v.len == 2
      check v[1].value[] == 1

  test "failed pop releases the removed element and preserves the vector":
    for budget in 0 .. 2:
      checkNoLeaks:
        let source = toVector([fallibleValue(1), fallibleValue(2), fallibleValue(3)])
        var v = source
        expectCopyFailure(budget):
          discard v.pop()
        check v == source
        check v.pop().value[] == 3
        check source.len == 3

  test "failed functional edits release their working vectors":
    checkNoLeaks:
      let source = toVector([fallibleValue(1), fallibleValue(2), fallibleValue(3)])
      let other = toVector([fallibleValue(4)])
      expectCopyFailure(1):
        discard source.pushBack(fallibleValue(4))
      expectCopyFailure(1):
        discard source.put(0, fallibleValue(4))
      expectCopyFailure(1):
        discard source.update(
          0,
          proc(value: FallibleCopy): FallibleCopy =
            fallibleValue(value.value[] + 1),
        )
      expectCopyFailure(1):
        discard source.popBack()
      expectCopyFailure(1):
        discard source.take(2)
      expectCopyFailure(1):
        discard source & other
      check source.len == 3
      check source[0].value[] == 1
      check other.len == 1

  test "failed functional edit preserves the assignment target":
    checkNoLeaks:
      let source = toVector([fallibleValue(1), fallibleValue(2), fallibleValue(3)])
      var target = toVector([fallibleValue(10)])
      expectCopyFailure(1):
        target = source.pushBack(fallibleValue(4))
      check target.len == 1
      check target[0].value[] == 10
      check source.len == 3
