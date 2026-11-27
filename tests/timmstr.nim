## ImmStr: immutable strings with O(1) copies. Built with
## -d:thetosTrackAllocs (see timmstr.nims); also run against thetos/local
## with -d:thetosTestLocal.

import std/[unittest, hashes, unicode, random, algorithm, math]
when defined(thetosTestLocal):
  import thetos/local
else:
  import thetos/immstr
import thetos/private/core

template checkNoLeaks(body: untyped) =
  let before = liveAllocations()
  block:
    body
  check liveAllocations() == before

suite "ImmStr":
  test "empty and basic access":
    let e = default(ImmStr)
    check e.len == 0 and e.isEmpty and $e == "" and e == ""
    check toImmStr("").isEmpty
    check $e.toCString == ""
    let s = toImmStr("hello")
    check s.len == 5 and s.high == 4 and s[1] == 'e' and s[^1] == 'o'
    check $s == "hello" and $s.toCString == "hello"
    expect IndexDefect:
      discard s[5]

  test "copies share bytes and free them once":
    checkNoLeaks:
      let a = toImmStr("shared text")
      var copies: seq[ImmStr]
      for i in 0 ..< 10:
        copies.add a
      check copies[9] == a and copies[9].toCString == a.toCString # same bytes

  test "equality, ordering and hash match string":
    let words = ["pear", "apple", "fig", "", "apples", "wörld"]
    for x in words:
      check hash(toImmStr(x)) == hash(x)
      check toImmStr(x) == x and x == toImmStr(x)
      for y in words:
        check (toImmStr(x) == toImmStr(y)) == (x == y)
        check cmp(toImmStr(x), toImmStr(y)).sgn == cmp(x, y).sgn
    var sorted = @words
    sorted.sort()
    var imm: seq[ImmStr]
    for w in words:
      imm.add toImmStr(w)
    imm.sort(cmp)
    for i in 0 ..< words.len:
      check imm[i] == sorted[i]

  test "concatenation and slicing":
    checkNoLeaks:
      let a = toImmStr("hello")
      check $(a & ", " & toImmStr("world")) == "hello, world"
      check $("<" & a) == "<hello"
      check (a & default(ImmStr)) == a
      check $a[1 .. 3] == "ell" and $a[^3 .. ^1] == "llo"
      check a[3 .. 2].isEmpty
      expect IndexDefect:
        discard a[2 .. 9]

  test "searching":
    let s = toImmStr("abcabc")
    check s.find("bc") == 1 and s.find("bc", 2) == 4 and s.find("x") == -1
    check s.find('c') == 2 and s.find('c', 3) == 5
    check "cab" in s and 'z' notin s
    check s.startsWith("abc") and s.endsWith("cabc") and not s.endsWith("ab")
    check s.find("") == 0 and s.startsWith("") and s.endsWith("")

  test "UTF-8":
    let s = toImmStr("añb€😀")
    check s.len == len("añb€😀") and s.runeLen == 5
    var runes: seq[Rune]
    for r in s.runes:
      runes.add r
    check runes == toRunes("añb€😀")
    check s.validateUtf8() == -1
    check toImmStr("ok\xff").validateUtf8() == 2

  test "toOpenArray needs no copy":
    let s = toImmStr("bytes")
    proc count(x: openArray[char]): int =
      x.len

    check count(s.toOpenArray) == 5 and count(default(ImmStr).toOpenArray) == 0

  test "random strings round-trip":
    var r = initRand(3)
    checkNoLeaks:
      for _ in 0 ..< 200:
        var x = newString(r.rand(40))
        for c in x.mitems:
          c = char(r.rand(255))
        let s = toImmStr(x)
        check $s == x and s.len == x.len and hash(s) == hash(x)
