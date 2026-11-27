import std/[unittest, options]
when defined(thetosTestLocal):
  import thetos/local # the same tests, against the thread-local variants
else:
  import thetos/box

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

suite "Box updateIt":
  test "updates with an expression of it":
    let a = box(@[1, 2, 3])
    let b = a.updateIt(it & 4)
    check a[] == @[1, 2, 3] and b[] == @[1, 2, 3, 4]
    expect ValueError:
      discard default(Box[int]).updateIt(it + 1)

suite "Box get":
  test "get and getOrDefault do not raise":
    check box("x").get() == some("x")
    check default(Box[string]).get().isNone
    check box(3).getOrDefault() == 3
    check default(Box[int]).getOrDefault() == 0
    check default(Box[int]).getOrDefault(9) == 9
