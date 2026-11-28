import std/unittest

import thetos

suite "thetos":
  test "umbrella module exports every container":
    var m = initTrieMap[string, TrieVec[int]]()
    m["xs"] = toTrieVec([1, 2, 3])
    let s = toTrieSet(["a", "b"])
    let tags = toTrieMultiMap({"nim": 1, "nim": 2})
    var shared = initAtom(tags)
    check shared.load()["nim"] == @[1, 2]
    let b = box(m)
    var a = initAtom(s)
    check b[]["xs"][2] == 3
    check "a" in a.load()
