import std/unittest

import thetos

suite "thetos":
  test "umbrella module exports every container":
    var m = initMap[string, Vector[int]]()
    m["xs"] = toVector([1, 2, 3])
    let s = toSet(["a", "b"])
    let b = box(m)
    var a = initAtom(s)
    check b[]["xs"][2] == 3
    check "a" in a.load()
