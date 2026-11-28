## Persistent JSON values and hookable conversions between JSON and Nim.
##
## `JsonValue` uses `TrieMap` for objects, `FlexVec` for arrays and
## `ImmStr` for text. Copies share storage, and edits return new values.
## Object member order is unspecified.
##
## `toJson`, `jsonTo` and `fromJson` use the conversion options and hook
## signatures familiar from `std/jsonutils`. Here `JsonNode` is a persistent
## `JsonValue`, and nested fields and containers dispatch persistent hooks.

runnableExamples:
  let before = parseJsonValue("""{"items":[1,2]}""")
  let after = before.put("items", before["items"].pushBack(toJson(3)))
  assert before["items"].jsonTo(seq[int]) == @[1, 2]
  assert after["items"].jsonTo(seq[int]) == @[1, 2, 3]

import
  std/[
    enumutils, formatfloat, hashes, macros, math, options, parsejson, sets, strbasics,
    streams, strtabs, strutils, tables, typetraits,
  ]
from std/json import JsonNodeKind, `$`, `[]=`, add, items, pairs
import ./[box, flexstr, flexvec, immstr, triemap, triemultimap, trieset, trievec]
from ./local import `[]`, `[]=`, `$`, add, incl, isEmpty, items, pairs
from ./private/core import raiseKeyError, resetOnError
from ./triemap {.all.} as maps import findWritableValue
from ./flexvec {.all.} as vectors import writableValue

export JsonNodeKind, JsonParsingError

type JsonValue* = object ## Persistent JSON tree. The default value is JSON null.
  case tag: JsonNodeKind
  of JNull:
    discard
  of JBool:
    boolean: bool
  of JInt:
    integer: BiggestInt
  of JFloat:
    real: float
  of JString:
    text: ImmStr
    rawNumber: bool
  of JArray:
    elements: FlexVec[JsonValue]
  of JObject:
    members: TrieMap[ImmStr, JsonValue]

const MaxJsonDepth = 1000

proc kind*(value: JsonValue): JsonNodeKind {.inline.} =
  ## The JSON kind. The stdlib represents raw number literals as `JString`.
  value.tag

proc isRawNumber*(value: JsonValue): bool {.inline.} =
  ## Whether a `JString` holds an unquoted numeric literal.
  value.tag == JString and value.rawNumber

proc requireKind(actual, expected: JsonNodeKind) {.inline.} =
  if actual != expected:
    raise newException(ValueError, "Expected " & $expected & ", got " & $actual)

proc getBool*(value: JsonValue): bool =
  ## Returns a boolean, or raises `ValueError` for a different kind.
  requireKind(value.tag, JBool)
  value.boolean

proc getInt*(value: JsonValue): BiggestInt =
  ## Returns an integer, or raises `ValueError` for a different kind.
  requireKind(value.tag, JInt)
  value.integer

proc getFloat*(value: JsonValue): float =
  ## Returns a floating point number or promotes an integer.
  ## Raises `ValueError` for other kinds.
  if value.tag == JInt:
    return float(value.integer)
  requireKind(value.tag, JFloat)
  value.real

proc getImmStr*(value: JsonValue): ImmStr =
  ## Returns the text of a JSON string or a raw number.
  ## Raises `ValueError` for other kinds.
  requireKind(value.tag, JString)
  value.text

proc getStr*(value: JsonValue): string =
  ## Copies the text into a Nim string. Use `getImmStr` to share its storage.
  $value.getImmStr

proc initJsonArray*(values: openArray[JsonValue] = []): JsonValue =
  ## Creates a JSON array containing the given values in order.
  JsonValue(tag: JArray, elements: toFlexVec(values))

proc initJsonObject*(fields: openArray[(string, JsonValue)] = []): JsonValue =
  ## Creates a JSON object. If a key occurs twice, its last value wins.
  result = JsonValue(tag: JObject)
  for (key, value) in fields:
    result.members[toImmStr(key)] = value

proc len*(value: JsonValue): int =
  ## The number of array elements or object members. Scalars have length zero.
  case value.tag
  of JArray: value.elements.len
  of JObject: value.members.len
  else: 0

proc immKey(key: string | ImmStr): ImmStr {.inline.} =
  when key is ImmStr:
    key
  else:
    toImmStr(key)

proc hasKey*(value: JsonValue, key: string | ImmStr): bool =
  ## Whether the object contains `key`. Returns false for other kinds.
  value.tag == JObject and value.members.hasKey(immKey(key))

proc `[]`*(value: JsonValue, key: string | ImmStr): lent JsonValue =
  ## Returns the object member at `key`. Raises `KeyError` for a missing
  ## member and `ValueError` for a value of a different kind.
  requireKind(value.tag, JObject)
  value.members[immKey(key)]

proc `[]`*(value: JsonValue, index: Natural): lent JsonValue =
  ## Returns an array element. Raises `IndexDefect` for an out-of-range
  ## index and `ValueError` for a value of a different kind.
  requireKind(value.tag, JArray)
  value.elements[index]

proc get*(value: JsonValue, key: string | ImmStr): Option[JsonValue] =
  ## Returns an object member, or `none` if the value has no such member.
  if value.tag == JObject:
    value.members.get(immKey(key))
  else:
    none(JsonValue)

proc get*(value: JsonValue, index: int): Option[JsonValue] =
  ## Returns an array element, or `none` if the value has no such element.
  if value.tag == JArray:
    value.elements.get(index)
  else:
    none(JsonValue)

# Instantiate the heterogeneous CHAMP lookup here, where ImmStr's hash and
# equality with a string are in scope regardless of the caller's imports.
proc writableMember(node: var JsonValue, key: string): ptr JsonValue {.inline.} =
  requireKind(node.kind, JObject)
  maps.findWritableValue(node.members, key)

proc writableMember(node: var JsonValue, key: ImmStr): ptr JsonValue {.inline.} =
  requireKind(node.kind, JObject)
  maps.findWritableValue(node.members, key)

proc `[]=`*(node: var JsonValue, key: string, item: sink JsonValue) =
  let member = writableMember(node, key)
  if member != nil:
    member[] = item
  else:
    node.members[toImmStr(key)] = item

proc `[]=`*(node: var JsonValue, key: ImmStr, item: sink JsonValue) =
  requireKind(node.kind, JObject)
  node.members[key] = item

proc `[]=`*(node: var JsonValue, i: Natural, item: sink JsonValue) =
  requireKind(node.kind, JArray)
  node.elements[i] = item

proc assignPath[P: tuple](
    node: var JsonValue, path: P, depth: static[int], item: var JsonValue
) {.inline.} =
  template key(): untyped =
    path[depth]

  when depth + 1 == path.tupleLen:
    node[key] = move(item)
  elif key is string | ImmStr:
    let member = writableMember(node, key)
    if member == nil:
      raiseKeyError(key)
    assignPath(member[], path, depth + 1, item)
  else:
    requireKind(node.kind, JArray)
    assignPath(vectors.writableValue(node.elements, key), path, depth + 1, item)

proc setPath*(node: var JsonValue, path: tuple, item: sink JsonValue) {.inline.} =
  ## Assigns a nested JSON value, reusing uniquely owned nodes along the path.
  ## `string` or `ImmStr` keys select object members and nonnegative indices select
  ## array elements. The final object key may be new. A missing intermediate
  ## key raises `KeyError`, an index past the end raises `IndexDefect`, and
  ## a mismatched container kind raises `ValueError`.
  runnableExamples:
    var doc = parseJsonValue("""{"rows":[{"id":1}]}""")
    let snapshot = doc
    doc.setPath(("rows", 0, "id"), toJson(2))
    assert doc["rows"][0]["id"].getInt == 2
    assert snapshot["rows"][0]["id"].getInt == 1

  static:
    doAssert path.tupleLen > 0, "Expected a nonempty JSON path"
  var replacement = item
  assignPath(node, path, 0, replacement)

proc put*(
    value: sink JsonValue, key: string | ImmStr, item: sink JsonValue
): JsonValue =
  ## Returns an object with `key` added or replaced.
  requireKind(value.tag, JObject)
  result = value
  result.members[immKey(key)] = item

proc put*(value: sink JsonValue, index: Natural, item: sink JsonValue): JsonValue =
  ## Returns an array with the existing element at `index` replaced.
  requireKind(value.tag, JArray)
  result = value
  result.elements[index] = item

proc pushBack*(value: sink JsonValue, item: sink JsonValue): JsonValue =
  ## Returns an array with `item` appended.
  requireKind(value.tag, JArray)
  result = value
  result.elements.add(item)

proc erase*(value: sink JsonValue, key: string | ImmStr): JsonValue =
  ## Returns an object without `key`.
  requireKind(value.tag, JObject)
  result = value
  result.members.del(immKey(key))

proc erase*(value: sink JsonValue, index: Natural): JsonValue =
  ## Returns an array without the element at `index`.
  requireKind(value.tag, JArray)
  result = value
  result.elements = erase(move(result.elements), index)

iterator items*(value: JsonValue): lent JsonValue =
  ## Iterates an array's elements in order.
  requireKind(value.tag, JArray)
  for item in value.elements:
    yield item

iterator pairs*(value: JsonValue): (ImmStr, JsonValue) =
  ## Iterates an object's members in unspecified order.
  requireKind(value.tag, JObject)
  for key, item in value.members:
    yield (key, item)

proc `==`*(a, b: JsonValue): bool =
  ## Compares JSON values structurally. Object member order is ignored.
  if a.tag != b.tag:
    return false
  case a.tag
  of JNull:
    true
  of JBool:
    a.boolean == b.boolean
  of JInt:
    a.integer == b.integer
  of JFloat:
    a.real == b.real
  of JString:
    a.rawNumber == b.rawNumber and a.text == b.text
  of JArray:
    a.elements == b.elements
  of JObject:
    a.members == b.members

proc hash*(value: JsonValue): Hash =
  ## Hashes the JSON value. Object member order is ignored.
  let payload =
    case value.tag
    of JNull:
      0.Hash
    of JBool:
      hash(value.boolean)
    of JInt:
      hash(value.integer)
    of JFloat:
      hash(value.real)
    of JString:
      hash(value.rawNumber) !& hash(value.text)
    of JArray:
      hash(value.elements)
    of JObject:
      hash(value.members)
  !$(hash(value.tag) !& payload)

proc fromNode(node: json.JsonNode, depth: int): JsonValue =
  resetOnError(result):
    if node == nil:
      return default(JsonValue)
    if depth > MaxJsonDepth and node.kind in {JArray, JObject}:
      raise newException(ValueError, "JSON nesting depth exceeds " & $MaxJsonDepth)
    case node.kind
    of JNull:
      result = default(JsonValue)
    of JBool:
      result = JsonValue(tag: JBool, boolean: node.bval)
    of JInt:
      result = JsonValue(tag: JInt, integer: node.num)
    of JFloat:
      result = JsonValue(tag: JFloat, real: node.fnum)
    of JString:
      # std/json stores an unquoted number as JString with a private flag.
      # Only strings that begin like a number can have that flag set.
      let raw =
        node.str.len > 0 and node.str[0] in {'-', '.', '0' .. '9'} and ($node)[0] != '"'
      result = JsonValue(tag: JString, text: toImmStr(node.str), rawNumber: raw)
    of JArray:
      result = JsonValue(tag: JArray)
      for item in node:
        result.elements.add(fromNode(item, depth + 1))
    of JObject:
      result = JsonValue(tag: JObject)
      for key, item in node:
        result.members[toImmStr(key)] = fromNode(item, depth + 1)

proc toJsonValue*(node: json.JsonNode): JsonValue =
  ## Copies a stdlib JSON tree into a persistent value. Nil becomes JSON null.
  ## Raises `ValueError` if the tree is nested beyond 1000 levels.
  fromNode(node, 0)

proc toJsonNode*(value: JsonValue): json.JsonNode =
  ## Returns an independent, mutable stdlib JSON tree.
  case value.tag
  of JNull:
    result = json.newJNull()
  of JBool:
    result = json.newJBool(value.boolean)
  of JInt:
    result = json.newJInt(value.integer)
  of JFloat:
    result = json.newJFloat(value.real)
  of JString:
    if value.rawNumber:
      result = json.parseJson($value.text, rawIntegers = true, rawFloats = true)
    else:
      result = json.newJString($value.text)
  of JArray:
    result = json.newJArray()
    for item in value.elements:
      result.add(toJsonNode(item))
  of JObject:
    result = json.newJObject()
    for key, item in value.members:
      result[$key] = toJsonNode(item)

proc readValue(parser: var JsonParser, depth: int): JsonValue =
  resetOnError(result):
    case parser.tok
    of tkNull:
      result = default(JsonValue)
    of tkTrue, tkFalse:
      result = JsonValue(tag: JBool, boolean: parser.tok == tkTrue)
    of tkString:
      result = JsonValue(tag: JString, text: toImmStr(parser.a))
    of tkInt:
      try:
        result = JsonValue(tag: JInt, integer: parseBiggestInt(parser.a))
      except ValueError:
        result = JsonValue(tag: JString, text: toImmStr(parser.a), rawNumber: true)
    of tkFloat:
      try:
        result = JsonValue(tag: JFloat, real: parseFloat(parser.a))
      except ValueError:
        result = JsonValue(tag: JString, text: toImmStr(parser.a), rawNumber: true)
    of tkBracketLe:
      if depth > MaxJsonDepth:
        parser.raiseParseErr("]")
      result = JsonValue(tag: JArray)
      discard parser.getTok()
      while parser.tok != tkBracketRi:
        result.elements.add(parser.readValue(depth + 1))
        if parser.tok != tkComma:
          break
        discard parser.getTok()
      parser.eat(tkBracketRi)
      return
    of tkCurlyLe:
      if depth > MaxJsonDepth:
        parser.raiseParseErr("}")
      result = JsonValue(tag: JObject)
      discard parser.getTok()
      while parser.tok != tkCurlyRi:
        if parser.tok != tkString:
          parser.raiseParseErr("string literal as key")
        let key = toImmStr(parser.a)
        discard parser.getTok()
        parser.eat(tkColon)
        result.members[key] = parser.readValue(depth + 1)
        if parser.tok != tkComma:
          break
        discard parser.getTok()
      parser.eat(tkCurlyRi)
      return
    else:
      parser.raiseParseErr("JSON value")
    discard parser.getTok()

proc parseJsonValue*(text: string): JsonValue =
  ## Parses JSON text with the stdlib tokenizer. Raises `JsonParsingError`
  ## for malformed input or if nesting exceeds 1000 levels.
  var parser: JsonParser
  parser.open(newStringStream(text), "input")
  defer:
    parser.close()
  discard parser.getTok()
  let value = parser.readValue(0)
  parser.eat(tkEof)
  result = value

proc appendQuoted(output: var string, text: openArray[char]) =
  output.add('"')
  var start = 0
  for i, c in text:
    if c < ' ' or c in {'"', '\\'}:
      if i > start:
        output.add(text.toOpenArray(start, i - 1))
      json.escapeJsonUnquoted($c, output)
      start = i + 1
  if start < text.len:
    output.add(text.toOpenArray(start, text.high))
  output.add('"')

proc appendJson(output: var string, value: JsonValue) =
  case value.tag
  of JNull:
    output.add("null")
  of JBool:
    output.add(if value.boolean: "true" else: "false")
  of JInt:
    output.add($value.integer)
  of JFloat:
    output.addFloat(value.real)
  of JString:
    if value.rawNumber:
      output.add(value.text.toOpenArray())
    else:
      output.appendQuoted(value.text.toOpenArray())
  of JArray:
    output.add('[')
    var first = true
    for item in value.elements:
      if not first:
        output.add(',')
      first = false
      output.appendJson(item)
    output.add(']')
  of JObject:
    output.add('{')
    var first = true
    for key, item in value.members:
      if not first:
        output.add(',')
      first = false
      output.appendQuoted(key.toOpenArray())
      output.add(':')
      output.appendJson(item)
    output.add('}')

proc `$`*(value: JsonValue): string =
  ## Renders compact JSON. Object member order is unspecified.
  result.appendJson(value)

include ./private/jsonhooks
