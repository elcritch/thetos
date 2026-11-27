## FlexStr: persistent strings (ropes). Built with -d:thetosTrackAllocs (see
## tflexstr.nims); also run against thetos/local with -d:thetosTestLocal.

import std/[unittest, unicode, random, strutils]
when defined(thetosTestLocal):
  import thetos/local
else:
  import thetos/[flexstr, immstr]
import thetos/private/core

template checkNoLeaks(body: untyped) =
  let before = liveAllocations()
  block:
    body
  check liveAllocations() == before

suite "FlexStr":
  test "basics":
    let e = default(FlexStr)
    check e.len == 0 and e.isEmpty and $e == "" and e == ""
    let s = toFlexStr("hello")
    check s.len == 5 and s[0] == 'h' and s[^1] == 'o' and $s == "hello"
    check s == "hello" and "hello" == s and s == toFlexStr("hello")
    check $toFlexStr(toImmStr("imm")) == "imm" and toImmStr(s) == "hello"

  test "edits keep old versions":
    checkNoLeaks:
      let doc = toFlexStr("hello world")
      let a = doc.insert(5, ",")
      let b = a.replace(7 .. 11, "there")
      let c = b.erase(0 .. 6)
      check $doc == "hello world"
      check $a == "hello, world" and $b == "hello, there" and $c == "there"
      check $(doc & "!") == "hello world!" and $("> " & doc) == "> hello world"
      check $doc[6 .. ^1] == "world" and $doc.take(5) == "hello"
      check $doc.drop(6) == "world"
      var grow = doc
      grow.add '!'
      grow.add " ok"
      grow.add toFlexStr("?")
      check $grow == "hello world! ok?" and $doc == "hello world"
      check doc.startsWith("hello") and doc.endsWith("world")
      expect IndexDefect:
        discard doc.insert(20, "x")

  test "replace supports empty ranges, single bytes and edits across leaves":
    let bytes = repeat("0123456789", 12)
    let s = toFlexStr(bytes)
    check s.replace(^1 .. ^1, "!") == bytes[0 ..< bytes.high] & "!"
    check s.replace(31 .. 64, "xy") == bytes[0 ..< 31] & "xy" & bytes[65 .. ^1]
    check s.replace(32 .. 31, "xy") == bytes[0 ..< 32] & "xy" & bytes[32 .. ^1]
    check s.replace(0 .. ^1, "").isEmpty
    check default(FlexStr).replace(0 ..< 0, "abc") == "abc"
    expect IndexDefect:
      discard s.replace(s.len .. s.len, "x")
    check s == bytes

  test "equality follows bytes across different leaf boundaries":
    let bytes = repeat("pattern", 650)
    let a = toFlexStr(bytes)
    let b = toFlexStr("shift" & bytes).drop(5)
    check a == a and a == b and b == a
    check hash(a) == hash(b)
    for i in [0, 26, 31, 32, 1023, bytes.high]:
      check a != b.replace(i .. i, "!")
    check a != b.take(b.len - 1)

  test "random edits agree with string":
    var r = initRand(11)
    checkNoLeaks:
      var s: FlexStr
      var model = ""
      for step in 0 ..< 3000:
        case r.rand(4)
        of 0:
          let text = $r.rand(1000)
          let i = r.rand(model.len)
          s = s.insert(i, text)
          model.insert(text, i)
        of 1:
          if model.len > 0:
            let a = r.rand(model.high)
            let b = r.rand(a .. min(model.high, a + 20))
            s = s.erase(a .. b)
            model.delete(a .. b)
        of 2:
          let text = $step
          s.add text
          model.add text
        of 3:
          if model.len > 0:
            let a = r.rand(model.high)
            let b = r.rand(a .. model.high)
            check $s[a .. b] == model[a .. b]
        else:
          s = s & s.take(min(s.len, 50))
          model = model & model[0 ..< min(model.len, 50)]
        if model.len > 20_000:
          s = s.take(1000)
          model.setLen(1000)
        if step mod 50 == 0:
          check $s == model and s.len == model.len
      check $s == model

  test "UTF-8":
    let s = toFlexStr("añb€😀") & toFlexStr("é")
    check s.runeLen == 6
    var runes: seq[Rune]
    for r in s.runes:
      runes.add r
    check runes == toRunes("añb€😀é")

  test "rune traversal follows std/unicode across leaf boundaries and at EOF":
    for offset in 123 .. 129:
      for tail in ["€😀", "\x80", "\xf0\x9f", "\xe2a", "\xf8abcd", "\xfcabcde"]:
        let bytes = repeat('x', offset) & tail
        let s = toFlexStr(bytes)
        var decoded: seq[Rune]
        for r in s.runes:
          decoded.add r
        check decoded == toRunes(bytes)
        check s.runeLen == runeLen(bytes)
