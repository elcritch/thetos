import std/unittest
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
