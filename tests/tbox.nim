import std/[unittest, with, options]
when defined(thetosTestLocal):
  import thetos/local # the same tests, against the thread-local variants
else:
  import thetos/box
import ./fixtures/boxrecord

type Counted = object ## Counts copies, to check `copyWith` moves when it can.
  id: int

var copies = 0

proc `=copy`(dst: var Counted, src: Counted) =
  inc copies
  dst.id = src.id

proc `=dup`(src: Counted): Counted =
  inc copies
  Counted(id: src.id)

type Holder = object
  item: Counted
  label: string

# Called here, for a type from another module: `hidden` is private there,
# so it gets no getter.
boxAccessors(Shape)
boxAccessors(Holder)

suite "Box":
  test "shares and updates":
    let a = box(@[1, 2, 3])
    let b = a
    let c = a.update(
      proc(s: seq[int]): seq[int] =
        s & 4
    )
    check a[] == @[1, 2, 3]
    check b == a
    check c[] == @[1, 2, 3, 4]
    check $box(1) == "box(1)"

  test "unique update reuses storage":
    var a = box("x")
    a = a.update(
      proc(s: string): string =
        s & "y"
    )
    check a[] == "xy"

  test "empty box":
    let e = default(Box[int])
    check e.isEmpty
    expect ValueError:
      discard e[]

  test "copyWith replaces fields and leaves the original":
    let a = box(Record(id: 1, name: "a"))
    let b = a.copyWith(name = "b")
    check a.name == "a" and b.name == "b"
    check b.id == 1 and a.secretOf == 7 and b.secretOf == 7
    let c = default(Box[Record]).copyWith(id = 3) # starts from field defaults
    check c.id == 3 and c.secretOf == 7

  test "boxAccessors follows field visibility":
    let r = box(Record(name: "r"))
    check r.name == "r" and r.id == 0
    check not compiles(r.secret) # private getter in boxrecord
    check not compiles(r.copyWith(secret = 1)) # private field
    check not compiles(r.copyWith(missing = 1))
    let round = box(Shape(kind: true, radius: 2.0))
    check round.kind and round.radius == 2.0
    check not compiles(round.hidden)
    expect FieldDefect:
      discard round.side

  test "copyWith moves the value when it can":
    var a = box(Holder(item: Counted(id: 1), label: "x"))
    copies = 0
    let shared = a.copyWith(label = "y") # `a` is used below, so the value is copied
    check copies == 1
    copies = 0
    let moved = move(a).copyWith(label = "z") # sole owner: moved, not copied
    check copies == 0
    check shared.item.id == 1 and moved.label == "z"

  test "unbox moves out of a sole owner and copies otherwise":
    let shared = box(Counted(id: 5))
    copies = 0
    check unbox(shared).id == 5 # `shared` is a let: copied
    check copies == 1
    var only = box(Counted(id: 6))
    copies = 0
    check unbox(move only).id == 6
    check copies == 0
    check unbox(default(Box[int])) == 0

  test "std/with still works on a Box":
    # `copyWith` was named to avoid this clash with std/with's `with`.
    var calls = 0
    proc touch(b: Box[Record]) =
      calls += b.id

    let r = box(Record(id: 2))
    with r:
      touch()
      touch()
    check calls == 4

suite "Box updateIt":
  test "updates with an expression of it":
    let a = box(@[1, 2, 3])
    let b = a.updateIt(it & 4)
    check a[] == @[1, 2, 3] and b[] == @[1, 2, 3, 4]
    expect ValueError:
      discard default(Box[int]).updateIt(it + 1)

  test "updateIt uses the boxed type for its expression":
    check box(1'i8).updateIt(0)[] == 0'i8

  test "updateIt moves the value out of a sole owner":
    # The expression builds a new Counted, so any copy comes from unboxing.
    var a = box(Holder(item: Counted(id: 1), label: "x"))
    copies = 0
    let shared = a.updateIt(Holder(item: Counted(id: it.item.id + 1), label: "y"))
    check copies == 1 # `a` is used below: its value is copied out
    copies = 0
    let moved = move(a).updateIt(Holder(item: Counted(id: it.item.id + 2), label: "z"))
    check copies == 0
    check shared.item.id == 2 and moved.item.id == 3

suite "Box get":
  test "get and getOrDefault do not raise":
    check box("x").get() == some("x")
    check default(Box[string]).get().isNone
    check box(3).getOrDefault() == 3
    check default(Box[int]).getOrDefault() == 0
    check default(Box[int]).getOrDefault(9) == 9

  test "get represents a stored nil as none":
    var fallback: int
    let missing: ptr int = nil
    check box(missing).get().isNone
    check box(missing).getOrDefault(addr fallback) == nil
