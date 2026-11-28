# Included by thetos/jsonutils so conversions can build persistent nodes directly.
type
  JsonNode* = JsonValue ## Node type used in persistent hook signatures.
  Joptions* = object
    allowExtraKeys*, allowMissingKeys*: bool

  EnumMode* = enum
    joptEnumOrd
    joptEnumSymbol
    joptEnumString

  JsonNodeMode* = enum
    joptJsonNodeAsRef
    joptJsonNodeAsCopy
    joptJsonNodeAsObject

  ToJsonOptions* = object
    jsonNodeMode*: JsonNodeMode
    enumMode*: EnumMode

func initToJsonOptions*(): ToJsonOptions =
  ToJsonOptions(enumMode: joptEnumOrd)

proc parseJson*(text: string): JsonNode =
  parseJsonValue(text)

proc newJNull*(): JsonNode =
  default(JsonNode)

proc newJBool*(value: bool): JsonNode =
  JsonNode(tag: JBool, boolean: value)

proc newJInt*(value: BiggestInt): JsonNode =
  JsonNode(tag: JInt, integer: value)

proc newJFloat*(value: float): JsonNode =
  JsonNode(tag: JFloat, real: value)

proc newJString*(value: string): JsonNode =
  JsonNode(tag: JString, text: toImmStr(value))

proc newJArray*(): JsonNode =
  initJsonArray()

proc newJObject*(): JsonNode =
  initJsonObject()

proc add*(node: var JsonNode, item: sink JsonNode) =
  requireKind(node.kind, JArray)
  node.elements.add(item)

proc toJson*[T](value: T, opt = initToJsonOptions()): JsonValue
proc fromJson*[T](value: var T, node: JsonValue, opt = Joptions())
proc jsonTo*[T](node: JsonValue, target: typedesc[T], opt = Joptions()): T =
  ## Decodes a JSON value, consulting hooks for each nested type.
  fromJson(result, node, opt)

type
  JsonSequence[T] =
    TrieVec[T] | FlexVec[T] | FlexDeque[T] | TrieSet[T] | local.TrieVec[T] |
    local.FlexVec[T] | local.FlexDeque[T] | local.TrieSet[T] | HashSet[T] | OrderedSet[
      T
    ]
  JsonMap[K, V] = TrieMap[K, V] | local.TrieMap[K, V] | Table[K, V] | OrderedTable[K, V]
  JsonStringKey = string | ImmStr | FlexStr | local.ImmStr | local.FlexStr

proc toJsonHook*(value: ImmStr | FlexStr | local.ImmStr | local.FlexStr): JsonNode =
  when value is ImmStr:
    JsonNode(tag: JString, text: value)
  else:
    newJString($value)

proc fromJsonHook*(
    value: var (ImmStr | FlexStr | local.ImmStr | local.FlexStr), node: JsonNode
) =
  let text = node.getImmStr
  when value is ImmStr:
    value = text
  elif value is FlexStr:
    value = toFlexStr(text)
  elif value is local.ImmStr:
    value = local.toImmStr($text)
  else:
    value = local.toFlexStr($text)

proc toJsonHook*[T](value: JsonSequence[T], opt = initToJsonOptions()): JsonNode =
  result = newJArray()
  for item in items(value):
    result.add(toJson(item, opt))

proc fromJsonHook*[T](value: var JsonSequence[T], node: JsonNode, opt = Joptions()) =
  var decoded: typeof(value)
  for item in node.items:
    let element = jsonTo(item, T, opt)
    when value is TrieSet[T] | local.TrieSet[T] | HashSet[T] | OrderedSet[T]:
      decoded.incl(element)
    else:
      decoded.add(element)
  value = decoded

proc toJsonHook*[K, V](value: JsonMap[K, V], opt = initToJsonOptions()): JsonNode =
  when K is JsonStringKey:
    result = newJObject()
    for key, item in pairs(value):
      result[$key] = toJson(item, opt)
  else:
    result = newJArray()
    for key, item in pairs(value):
      result.add(toJson((key, item), opt))

proc fromJsonHook*[K, V](value: var JsonMap[K, V], node: JsonNode, opt = Joptions()) =
  var decoded: typeof(value)
  when K is JsonStringKey:
    for key, item in node.pairs:
      decoded[jsonTo(JsonNode(tag: JString, text: key), K, opt)] = jsonTo(item, V, opt)
  else:
    for pair in node.items:
      let (key, item) = jsonTo(pair, (K, V), opt)
      decoded[key] = item
  value = decoded

proc toJsonHook*[K, V](
    value: TrieMultiMap[K, V] | local.TrieMultiMap[K, V], opt = initToJsonOptions()
): JsonNode =
  result = newJArray()
  for key, item in pairs(value):
    result.add(toJson((key, item), opt))

proc fromJsonHook*[K, V](
    value: var (TrieMultiMap[K, V] | local.TrieMultiMap[K, V]),
    node: JsonNode,
    opt = Joptions(),
) =
  var decoded: typeof(value)
  for pair in node.items:
    let (key, item) = jsonTo(pair, (K, V), opt)
    decoded.add(key, item)
  value = decoded

proc toJsonHook*[T](value: Option[T], opt = initToJsonOptions()): JsonNode =
  if value.isSome:
    toJson(value.get, opt)
  else:
    newJNull()

proc fromJsonHook*[T](value: var Option[T], node: JsonNode, opt = Joptions()) =
  value =
    if node.kind == JNull:
      none(T)
    else:
      some(jsonTo(node, T, opt))

proc toJsonHook*[T](value: Box[T] | local.Box[T], opt = initToJsonOptions()): JsonNode =
  result = newJArray()
  if not value.isEmpty:
    result.add(toJson(value[], opt))

proc fromJsonHook*[T](
    value: var (Box[T] | local.Box[T]), node: JsonNode, opt = Joptions()
) =
  requireKind(node.kind, JArray)
  case node.len
  of 0:
    reset(value)
  of 1:
    let item = jsonTo(node[0], T, opt)
    when value is Box[T]:
      value = box(item)
    else:
      value = local.box(item)
  else:
    raise newException(ValueError, "Expected zero or one boxed value")

proc fieldKey(name: static string): lent ImmStr =
  # A reflected field name is fixed at compile time and can share its bytes and hash.
  let key {.global.} = toImmStr(name)
  key

proc caseFields(typ: NimNode): seq[NimNode] {.compileTime.} =
  let impl = typ.getTypeImpl
  if impl.kind == nnkObjectTy:
    if impl[1].kind == nnkOfInherit:
      result = caseFields(impl[1][0])
    for field in impl[2]:
      if field.kind == nnkRecCase:
        result.add(field[0])

macro discriminants(T: typedesc): untyped =
  var names: seq[string]
  for field in caseFields(T.getTypeInst[1]):
    names.add(field[0].strVal)
  result = newLit(names)

macro initVariant(T: typedesc, previous, node, opt: typed): untyped =
  result = nnkObjConstr.newTree(T)
  for field in caseFields(T.getTypeInst[1]):
    let key = newLit(field[0].strVal)
    let oldTag = newDotExpr(previous, field[0])
    let tag = quote:
      (
        if `node`.hasKey(`key`): jsonTo(`node`[`key`], typeof(`oldTag`), `opt`)
        else: `oldTag`
      )
    result.add(nnkExprColonExpr.newTree(field[0], tag))

proc toJson*[T](value: T, opt = initToJsonOptions()): JsonValue =
  ## Prefers an options-aware hook, followed by a single-argument hook.
  mixin toJsonHook
  when T is JsonValue:
    if opt.jsonNodeMode == joptJsonNodeAsObject:
      raise newException(
        ValueError, "Persistent node internals cannot be serialized as fields"
      )
    result = value
  elif compiles(toJsonHook(value, opt)):
    result = toJsonHook(value, opt)
  elif compiles(toJsonHook(value)):
    result = toJsonHook(value)
  elif T is json.JsonNode:
    result = toJson(toJsonValue(value), opt)
  elif T is distinct:
    result = toJson(value.distinctBase, opt)
  elif T is bool:
    result = newJBool(value)
  elif T is enum:
    case opt.enumMode
    of joptEnumOrd:
      result = newJInt(ord(value))
    of joptEnumSymbol:
      result = newJString(symbolName(value))
    of joptEnumString:
      result = newJString($value)
  elif T is SomeUnsignedInt:
    if uint64(value) <= uint64(high(BiggestInt)):
      result = newJInt(BiggestInt(value))
    else:
      result = JsonNode(tag: JString, text: toImmStr($value), rawNumber: true)
  elif T is SomeInteger or T is char:
    result = newJInt(BiggestInt(value))
  elif T is SomeFloat:
    case classify(value)
    of fcNan:
      result = newJString("nan")
    of fcInf:
      result = newJString("inf")
    of fcNegInf:
      result = newJString("-inf")
    else:
      result = newJFloat(value)
  elif T is string:
    result = newJString(value)
  elif T is typeof(nil):
    result = newJNull()
  elif T is cstring:
    if value != nil:
      result = newJString($value)
  elif T is ref:
    if not value.isNil:
      result = toJson(value[], opt)
  elif T is seq | array | set:
    result = newJArray()
    for item in value:
      result.add(toJson(item, opt))
  elif T is object or (T is tuple and isNamedTuple(T)):
    result = newJObject()
    for name, field in fieldPairs(value):
      result[fieldKey(name)] = toJson(field, opt)
  elif T is tuple:
    result = newJArray()
    for field in fields(value):
      result.add(toJson(field, opt))
  else:
    {.error: "Provide a persistent toJsonHook for this type".}

proc fromJson*[T](value: var T, node: JsonValue, opt = Joptions()) =
  ## Decodes directly from persistent storage. Missing fields can retain their values.
  mixin fromJsonHook
  when T is JsonValue:
    value = node
  elif compiles(fromJsonHook(value, node, opt)):
    fromJsonHook(value, node, opt)
  elif compiles(fromJsonHook(value, node)):
    fromJsonHook(value, node)
  elif T is json.JsonNode:
    value = toJsonNode(node)
  elif T is distinct:
    fromJson(value.distinctBase, node, opt)
  elif T is bool:
    value = node.getBool
  elif T is enum:
    template candidates(): untyped =
      when T is HoleyEnum:
        enumutils.items(T)
      else:
        system.items(T)

    for candidate in candidates:
      if (node.kind == JInt and node.getInt == ord(candidate)) or (
        node.kind == JString and
        (node.text == $candidate or node.text == symbolName(candidate))
      ):
        value = candidate
        return
    raise newException(ValueError, "Invalid " & $T & " value")
  elif T is SomeUnsignedInt:
    var n: uint64
    if node.isRawNumber:
      n = parseBiggestUInt($node.text)
    else:
      let signed = node.getInt
      if signed < 0:
        raise newException(ValueError, "Negative unsigned integer")
      n = uint64(signed)
    if n < uint64(low(T)) or n > uint64(high(T)):
      raise newException(ValueError, "Integer out of range")
    value = T(n)
  elif T is SomeInteger or T is char:
    let n = node.getInt
    if n < BiggestInt(low(T)) or n > BiggestInt(high(T)):
      raise newException(ValueError, "Integer out of range")
    value = T(n)
  elif T is SomeFloat:
    if node.kind == JString:
      case $node.text
      of "nan":
        value = T(NaN)
      of "inf":
        value = T(Inf)
      of "-inf":
        value = T(-Inf)
      else:
        raise newException(ValueError, "Invalid floating point value")
    else:
      value = T(node.getFloat)
  elif T is string:
    value = node.getStr
  elif T is ref:
    if node.kind == JNull:
      value = nil
    else:
      var decoded: T
      new(decoded)
      fromJson(decoded[], node, opt)
      value = decoded
  elif T is seq:
    requireKind(node.kind, JArray)
    var decoded = newSeqOfCap[typeof(value[0])](node.len)
    for item in node.items:
      decoded.add(jsonTo(item, typeof(value[0]), opt))
    value = decoded
  elif T is set:
    var decoded: T
    for item in node.items:
      decoded.incl(jsonTo(item, elementType(value), opt))
    value = decoded
  elif T is array:
    requireKind(node.kind, JArray)
    if value.len != node.len:
      raise newException(ValueError, "Wrong array length")
    var index = 0
    for field in value.mitems:
      fromJson(field, node[index], opt)
      inc index
  elif T is object or (T is tuple and isNamedTuple(T)):
    requireKind(node.kind, JObject)
    const tags = discriminants(T)
    template readFields(dest: untyped) =
      var matched = 0
      for name, field in fieldPairs(dest):
        let member = node.members.get(fieldKey(name))
        if member.isSome:
          inc matched
          when name notin tags:
            fromJson(field, member.get, opt)
        elif not opt.allowMissingKeys:
          raise newException(ValueError, "Missing JSON field " & name)
      if not opt.allowExtraKeys and matched != node.len:
        raise newException(ValueError, "Unexpected JSON field")

    when tags.len == 0:
      readFields(value)
    else:
      var decoded = initVariant(T, value, node, opt)
      if opt.allowMissingKeys:
        for name, field in fieldPairs(decoded):
          when name notin tags:
            for oldName, oldField in fieldPairs(value):
              when name == oldName:
                field = oldField
      readFields(decoded)
      value = decoded
  elif T is tuple:
    requireKind(node.kind, JArray)
    if node.len != tupleLen(T):
      raise newException(ValueError, "Wrong tuple length")
    var i = 0
    for field in fields(value):
      fromJson(field, node[i], opt)
      inc i
  else:
    {.error: "Provide a persistent fromJsonHook for this type".}

proc `%`*[T](value: T): JsonNode =
  toJson(value)

proc `%`*(value: typeof(nil)): JsonNode =
  newJNull()

macro `%*`*(value: untyped): untyped =
  ## Builds persistent JSON from nested object and array literals.
  proc literal(expr: NimNode): NimNode =
    case expr.kind
    of nnkTableConstr:
      let fields = newNimNode(nnkBracket)
      for pair in expr:
        fields.add(nnkTupleConstr.newTree(pair[0], literal(pair[1])))
      result = newCall(bindSym"initJsonObject", fields)
    of nnkCurly:
      expr.expectLen(0)
      result = newCall(bindSym"newJObject")
    of nnkBracket:
      let elements = newNimNode(nnkBracket)
      for item in expr:
        elements.add(literal(item))
      result = newCall(bindSym"initJsonArray", elements)
    of nnkNilLit:
      result = newCall(bindSym"newJNull")
    of nnkPar:
      if expr.len == 1:
        result = literal(expr[0])
      else:
        result = newCall(bindSym"%", expr)
    else:
      result = newCall(bindSym"%", expr)

  result = literal(value)

proc toJsonHook*(value: StringTableRef, opt = initToJsonOptions()): JsonNode =
  if value.isNil:
    return newJNull()
  var entries = newJObject()
  for key, item in value:
    entries[key] = newJString(item)
  result = initJsonObject([("mode", newJString($value.mode)), ("table", entries)])

proc fromJsonHook*(value: var StringTableRef, node: JsonNode, opt = Joptions()) =
  if node.kind == JNull:
    value = nil
    return
  var decoded = newStringTable(jsonTo(node["mode"], StringTableMode, opt))
  for key, item in node["table"].pairs:
    decoded[$key] = item.getStr
  value = decoded
