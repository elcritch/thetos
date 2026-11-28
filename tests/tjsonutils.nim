import std/[hashes, options, strutils, sets, strtabs, tables, unittest]
from std/json import `[]`, `[]=`, getStr
import thetos
import thetos/jsonutils as persistent
from thetos/local import add
from thetos/private/core import allocCount, liveAllocations

type
  Label = distinct string
  Status = enum
    queued
    ready

  Entry = object
    label: Label
    status: Status
    count: int

proc toJsonHook(value: Label, opt: ToJsonOptions): JsonNode =
  newJString("label:" & string(value))

proc fromJsonHook(value: var Label, node: JsonNode, opt: Joptions) =
  let s = node.getStr()
  if s.len < 6 or s[0 ..< 6] != "label:":
    raise newException(ValueError, "Invalid Label")
  value = Label(s[6 .. ^1])

suite "Persistent JsonValue":
  test "reads JSON kinds, nested members and escaped text":
    let value =
      parseJsonValue("""{"items":[null,true,-2,1.5,"a\u0000🌍"],"text":""}""")
    let items = value["items"]
    check default(JsonValue).kind == JNull
    check value.kind == JObject and value.len == 2
    check items.kind == JArray and items.len == 5
    check items[0] == default(JsonValue)
    check items[1].getBool and items[2].getInt == -2
    check items[2].getFloat == -2.0 and items[3].getFloat == 1.5
    check items[4].getStr == "a\x00🌍" and value["text"].getStr == ""
    check parseJsonValue($value) == value
    check value.get("missing").isNone and items.get(-1).isNone
    check items.get(5).isNone and items.get("missing").isNone
    check value.get(0).isNone and not items.hasKey("missing")
    expect KeyError:
      discard value["missing"]
    expect IndexDefect:
      discard items[5]
    expect ValueError:
      discard items[0].getInt
    expect JsonParsingError:
      discard parseJsonValue("""{"a":]""")

  test "object and array edits preserve prior versions":
    let before = parseJsonValue("""{"items":[1,2],"name":"before"}""")
    let items = before[toImmStr("items")]
    let edited =
      items.put(0, persistent.toJson(3)).pushBack(persistent.toJson(4)).erase(1)
    let after = before.put("items", edited).erase("name")
    check before["name"].getStr == "before"
    check $before["items"] == "[1,2]"
    check after.len == 1 and $after["items"] == "[3,4]"
    check after.erase("unknown") == after
    check items[0].getInt == 1
    check initJsonObject([("items", initJsonArray([items[0], items[1]]))]) ==
      before.erase("name")
    var sum = 0
    for item in edited:
      sum += item.getInt.int
    check sum == 7
    for key, value in after:
      check key == "items" and value == edited

  test "nested assignments reuse owned nodes and preserve shared rows":
    let baseline = liveAllocations()
    block:
      var doc = initJsonObject()
      var rows = initJsonArray()
      for i in 0 ..< 70:
        rows.add(initJsonObject([("id", newJInt(i))]))
      doc["rows"] = move(rows)
      let before = allocCount()
      for i in [0, 32, 69]:
        doc.setPath(("rows", i, "id"), newJInt(-i))
      check allocCount() == before
      let snapshot = doc
      let savedRows = doc["rows"]
      for i in [0, 32, 69]:
        doc.setPath((toImmStr("rows"), i, "id"), newJInt(i + 100))
        check doc["rows"][i]["id"].getInt == i + 100
        check snapshot["rows"][i]["id"].getInt == -i
        check savedRows[i]["id"].getInt == -i
      doc.setPath(("rows", 1, "copy"), doc["rows"][0])
      doc.setPath(("rows", 0, "id"), newJInt(7))
      check doc["rows"][1]["copy"]["id"].getInt == 100
      doc.setPath(("rows", 2), doc)
      check doc["rows"][2]["rows"][2]["id"].getInt == 2
    check liveAllocations() == baseline

  test "nested assignments isolate shared object branches":
    var doc = initJsonObject()
    let row = parseJsonValue("""{"id":0}""")
    for i in 0 ..< 128:
      doc["row" & $i] = row
    let snapshot = doc
    for i in 0 ..< 128:
      let key = "row" & $i
      doc.setPath((key, "id"), newJInt(i + 1))
    for i in 0 ..< 128:
      let key = "row" & $i
      check doc[key]["id"].getInt == i + 1
      check snapshot[key]["id"].getInt == 0

  test "failed nested assignments preserve the document and release their values":
    let baseline = liveAllocations()
    block:
      var doc = parseJsonValue("""{"rows":[{"id":1}]}""")
      let before = doc
      expect KeyError:
        doc.setPath(("rows", 0, "missing", "id"), newJString("unused"))
      expect IndexDefect:
        doc.setPath(("rows", 1, "id"), newJString("unused"))
      expect ValueError:
        doc.setPath(("rows", 0, "id", "key"), newJString("unused"))
      check doc == before
    check liveAllocations() == baseline

  test "objects compare and hash by contents":
    let a = parseJsonValue("""{"a":1,"b":[true]}""")
    let b = parseJsonValue("""{"b":[true],"a":0,"a":1}""")
    check a == b and hash(a) == hash(b)
    check hash(parseJsonValue("-0.0")) == hash(parseJsonValue("0.0"))
    check a != a.put("a", persistent.toJson(2))
    check a != initJsonArray()

  test "nested snapshots across vector leaves release their nodes":
    let baseline = liveAllocations()
    block:
      var document = initJsonArray()
      for i in 0 ..< 70:
        document = document.pushBack(initJsonObject([("index", persistent.toJson(i))]))
      let edited = document.put(32, document[32].put("index", persistent.toJson(-1)))
      let nested = document.put(0, document)
      check document[32]["index"].getInt == 32
      check edited[32]["index"].getInt == -1
      check nested[0][69]["index"].getInt == 69
      check edited[69] == document[69]
    check liveAllocations() == baseline

  test "mutable stdlib JSON trees are independent of persistent values":
    var source = json.parseJson("""{"word":"before","items":[1]}""")
    let stable = toJsonValue(source)
    source["word"] = json.newJString("after")
    var restored = stable.toJsonNode()
    json.add(restored["items"], json.newJInt(2))
    check stable["word"].getStr == "before" and stable["items"].len == 1
    check toJsonValue(nil).kind == JNull

  test "text I/O handles escaped keys, all control bytes and numeric tokens":
    var escaped = "quotes \" and backslash \\ with 🌍"
    for i in 0 ..< 32:
      escaped.add(char(i))
    let text = "{" & json.escapeJson(escaped) & ":" & json.escapeJson(escaped) & "}"
    let parsed = parseJsonValue(text)
    check parsed[escaped].getStr == escaped
    check $parsed == text
    let numeric =
      "/* values */ [-9223372036854775808, -0.0, 3.25e5, false, true, null,]"
    check parseJsonValue(numeric) == toJsonValue(json.parseJson(numeric))
    check parseJsonValue($parseJsonValue(numeric)) == parseJsonValue(numeric)

  test "malformed and deeply nested text release partial trees":
    let baseline = liveAllocations()
    for text in [
      "", "[1] true", "{1:2}", """{"a" 1}""", "[1 2]", """{"ok":["saved"],"bad":[1}"""
    ]:
      expect JsonParsingError:
        discard parseJsonValue(text)
    expect JsonParsingError:
      discard parseJsonValue(repeat('[', 1002) & "0" & repeat(']', 1002))
    check liveAllocations() == baseline

  test "a too-deep stdlib tree releases partially converted nodes":
    var source = json.newJArray()
    for i in 0 ..< 1001:
      var parent = json.newJArray()
      json.add(parent, json.newJString("sibling"))
      json.add(parent, source)
      source = parent
    let baseline = liveAllocations()
    expect ValueError:
      discard toJsonValue(source)
    check liveAllocations() == baseline

  test "raw large numbers and numeric-looking strings stay distinct":
    let literal = "18446744073709551615"
    let number = parseJsonValue(literal)
    let quoted = persistent.toJson(literal)
    check number.isRawNumber and not quoted.isRawNumber
    check number != quoted
    check $number == literal and $quoted == json.escapeJson(literal)
    check number.jsonTo(uint64) == high(uint64)
    check persistent.toJson(high(uint64)) == number
    check $parseJsonValue("123456789012345678901234567890") ==
      "123456789012345678901234567890"

  when compileOption("threads"):
    test "can publish persistent JSON through Atom":
      var state = initAtom(parseJsonValue("""{"version":1}"""))
      let prior = state.load()
      state.store(prior.put("version", persistent.toJson(2)))
      check prior["version"].getInt == 1 and state.load()["version"].getInt == 2

suite "JSON conversion hooks":
  test "persistent options and custom hooks work inside nested containers":
    let entries = toFlexVec([Entry(label: Label("first"), status: ready, count: 2)])
    let source = (entries: entries, meta: {"optional": some(3)}.toTable)
    let node = persistent.toJson(source, ToJsonOptions(enumMode: joptEnumString))
    check node["entries"][0]["label"].getStr == "label:first"
    check node["entries"][0]["status"].getStr == "ready"
    let decoded = node.jsonTo(typeof(source))
    check string(decoded.entries[0].label) == "first"
    check decoded.entries[0].status == ready and decoded.meta["optional"].get == 3
    var entry = entries[0]
    persistent.fromJson(
      entry,
      parseJsonValue("""{"count":9,"extra":true}"""),
      Joptions(allowMissingKeys: true, allowExtraKeys: true),
    )
    check entry.count == 9 and string(entry.label) == "first"

  test "persistent entry points recognize hooks for thetos types":
    let original = (
      strings: toTrieVec([toImmStr("text")]),
      rope: toFlexStr("rope"),
      list: toFlexVec([1, 2, 3]),
      deque: toFlexDeque([0, 1]).pushFront(-1),
      flags: toTrieSet([2, 7]),
      payload: parseJsonValue("""{"data":true}"""),
    )
    let node = persistent.toJson(original)
    check $node["strings"] == """["text"]""" and $node["rope"] == """"rope""""
    check $node["deque"] == "[-1,0,1]"
    check persistent.jsonTo(node, typeof(original)) == original

  test "persistent maps use objects for strings and pairs for other keys":
    let text = toTrieMap([(toImmStr("a"), 1), (toImmStr("b"), 2)])
    let nodes = persistent.toJson(text)
    check nodes == parseJsonValue("""{"a":1,"b":2}""")
    check nodes.jsonTo(typeof(text)) == text
    let plain = toTrieMap([("a", 1)])
    check persistent.toJson(plain).jsonTo(typeof(plain)) == plain
    let rope = toTrieMap([(toFlexStr("a"), 1)])
    check nodes.jsonTo(typeof(rope))[toFlexStr("a")] == 1
    let indexed = toTrieMap([(2, "two")])
    check $persistent.toJson(indexed) == """[[2,"two"]]"""
    check persistent.toJson(indexed).jsonTo(typeof(indexed)) == indexed
    check parseJsonValue("""[[2,"two"],[2,"second"]]""").jsonTo(typeof(indexed))[2] ==
      "second"

  test "empty and full boxes round trip even when the contents are null":
    let full = box(none(int))
    let empty = default(Box[Option[int]])
    check $persistent.toJson(full) == "[null]"
    check $persistent.toJson(empty) == "[]"
    check persistent.toJson(full).jsonTo(typeof(full)) == full
    check persistent.toJson(empty).jsonTo(typeof(empty)).isEmpty
    expect ValueError:
      discard parseJsonValue("[1,2]").jsonTo(Box[int])

  test "local containers use the same wire format":
    let original = (
      map: local.toTrieMap([(local.toImmStr("a"), local.toFlexStr("b"))]),
      vec: local.toTrieVec([1, 2]),
      flex: local.toFlexVec([3]),
      deque: local.toFlexDeque([5]),
      flags: local.toTrieSet([4]),
      item: local.box(local.toImmStr("box")),
    )
    let node = persistent.toJson(original)
    check node ==
      parseJsonValue(
        """{"map":{"a":"b"},"vec":[1,2],"flex":[3],"deque":[5],
      "flags":[4],"item":["box"]}"""
      )
    let decoded = node.jsonTo(typeof(original))
    check persistent.toJson(decoded) == node

  test "invalid input does not replace a destination container":
    var values = toFlexVec([Label("kept")])
    expect ValueError:
      persistent.fromJson(values, parseJsonValue("""["label:parsed","invalid"]"""))
    check values.len == 1 and string(values[0]) == "kept"
    expect ValueError:
      persistent.fromJson(values, initJsonObject())
    check values.len == 1 and string(values[0]) == "kept"

type
  WireCode = distinct int
  Choice = object
    label: string
    case present: bool
    of true: code: WireCode
    else:
      discard

proc toJsonHook(code: WireCode): JsonNode =
  newJInt(10 + int(code))

proc fromJsonHook(code: var WireCode, node: JsonNode) =
  code = WireCode(node.getInt - 10)

suite "Native JSON hooks":
  test "simple hooks and variant objects":
    var choice = Choice(label: "keep")
    fromJson(
      choice,
      parseJsonValue("""{"present":true,"code":15}"""),
      Joptions(allowMissingKeys: true),
    )
    check choice.present and choice.label == "keep" and int(choice.code) == 5
    check toJson(choice)["code"].getInt == 15
    check parseJsonValue("""{"label":"reset","present":false}""").jsonTo(Choice).present ==
      false

  test "scalars, fixed arrays, positional tuples and sets":
    let values = ([1'u16, 2], {'a', 'b'}, (true, 'x'), -Inf)
    check toJson(values).jsonTo(typeof(values)) == values
    expect ValueError:
      discard newJInt(-1).jsonTo(uint8)
    expect ValueError:
      discard newJInt(256).jsonTo(uint8)
    expect ValueError:
      discard newJArray().jsonTo(array[2, int])

suite "Persistent JSON builders":
  test "JSON literals, mutable builder syntax and immutable snapshots":
    var node = %*{"items": [nil, 1, {"active": true}], "empty": {}}
    let before = node
    node["items"] = %*[3]
    check before["items"][2]["active"].getBool
    check node == parseJson("""{"items":[3],"empty":{}}""")
    check node.toJsonNode.toJsonValue == node

  test "multimaps preserve duplicate values":
    let m = toTrieMultiMap([("x", 1), ("x", 2), ("x", 1)])
    check toJson(m).jsonTo(typeof(m)) == m

type Failable = distinct int
proc toJsonHook(value: Failable): JsonNode =
  if int(value) < 0:
    raise newException(ValueError, "negative value")
  newJString($int(value))

suite "Hook errors":
  test "partially encoded containers release their nodes":
    let values = toFlexVec([Failable(1), Failable(-1)])
    let baseline = liveAllocations()
    expect ValueError:
      discard toJson(values)
    check liveAllocations() == baseline
    expect ValueError:
      discard toJson(@[Failable(1), Failable(-1)])
    check liveAllocations() == baseline

type
  WireEnum = enum
    firstWire = (2, "first-wire")
    lastWire = (7, "last-wire")

  Meter = distinct int
  RecordRef = ref object
    id: int

suite "Native standard types":
  test "sparse enum symbols, ordinals and strings work in containers":
    for mode in [joptEnumOrd, joptEnumSymbol, joptEnumString]:
      let data = @[lastWire].toHashSet
      let json = toJson(data, ToJsonOptions(enumMode: mode))
      check json.jsonTo(typeof(data)) == data
    expect ValueError:
      discard newJInt(3).jsonTo(WireEnum)

  test "references, distinct scalars, and string tables":
    check int(toJson(Meter(12)).jsonTo(Meter)) == 12
    check toJson(RecordRef(id: 5)).jsonTo(RecordRef).id == 5
    check newJNull().jsonTo(RecordRef).isNil
    let t = newStringTable("A", "first", modeCaseInsensitive)
    check toJson(t).jsonTo(StringTableRef)["a"] == "first"

  test "object key options propagate through sequences":
    type Row = object
      nr: int

    let node = parseJson("""[{"nr":1,"extra":true}]""")
    expect ValueError:
      discard node.jsonTo(seq[Row])
    check node.jsonTo(seq[Row], Joptions(allowExtraKeys: true))[0].nr == 1
    expect ValueError:
      discard newJObject().jsonTo(Row)
