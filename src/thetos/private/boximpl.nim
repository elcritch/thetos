# Included by the container modules and by `thetos/local`; not a module.
# The including module imports `std/[bitops, hashes, options]` and
# `private/core`, and declares `RcCount`, the type of each node's `rc`.

type
  BoxNode[T] = object
    rc*: RcCount # exported for the generic refcount helpers in core
    value: T

  Box*[T] = object ## Shared immutable value. `default(Box[T])` is an empty box.
    node: ptr BoxNode[T]

proc `=destroy`*[T](b: Box[T]) =
  if b.node != nil and dropRef(b.node):
    # Destructors never raise; the cast covers effects that the compiler
    # cannot infer through generic instantiations.
    {.cast(raises: []), cast(gcsafe).}:
      `=destroy`(b.node.value)
    freeAlignedRaw(b.node, alignof(BoxNode[T]))

proc `=wasMoved`*[T](b: var Box[T]) =
  b.node = nil

proc `=dup`*[T](b: Box[T]): Box[T] =
  if b.node != nil:
    retain(b.node)
  result.node = b.node

proc `=copy`*[T](dst: var Box[T], src: Box[T]) =
  if src.node != nil:
    retain(src.node)
  `=destroy`(dst)
  dst.node = src.node

proc box*[T](value: sink T): Box[T] =
  ## Boxes `value`.
  result.node =
    cast[ptr BoxNode[T]](allocAlignedRaw(sizeof(BoxNode[T]), alignof(BoxNode[T])))
  initRc(result.node)
  result.node.value = value

proc isEmpty*[T](b: Box[T]): bool {.inline.} =
  ## True for a default-initialized or moved-from box.
  b.node == nil

proc `[]`*[T](b: Box[T]): lent T =
  ## The boxed value. Raises `ValueError` for an empty box.
  if b.node == nil:
    raise newException(ValueError, "empty Box")
  b.node.value

proc update*[T, F](b: sink Box[T], f: F): Box[T] =
  ## Returns a box holding `f(b[])`. Reuses the allocation when `b` is
  ## uniquely owned.
  if b.node != nil and isUnique(b.node):
    result = b
    result.node.value = f(move(result.node.value))
  else:
    result = box(f(b[]))

proc unbox*[T](b: sink Box[T]): T =
  ## Returns the boxed value, moving it out when `b` is its only owner and
  ## copying it otherwise. An empty box gives `default(T)`.
  if b.node == nil:
    result = default(T)
  elif isUnique(b.node):
    result = move(b.node.value)
  else:
    result = b.node.value

proc `==`*[T](a, b: Box[T]): bool =
  if a.node == b.node:
    return true
  if a.node == nil or b.node == nil:
    return false
  a.node.value == b.node.value

proc hash*[T](b: Box[T]): Hash =
  if b.node == nil:
    0
  else:
    hash(b.node.value)

proc `$`*[T](b: Box[T]): string =
  if b.node == nil:
    "box()"
  else:
    var s = "box("
    s.addQuoted b.node.value
    s.add ")"
    s

macro copyWith*(b: Box, args: varargs[untyped]): untyped =
  ## Returns a box holding `b[]` with the named fields replaced, as in
  ## `config.copyWith(name = "prod", retries = 5)`. `b` is unchanged. The value
  ## is moved out rather than copied when `b` is not used afterwards and is
  ## the only owner. Field names and visibility are checked like ordinary
  ## field assignments. An empty box starts from `default(T)`.
  runnableExamples:
    type Config = object
      name: string
      retries: int = 3

    let a = box(Config(name: "default"))
    let b = a.copyWith(name = "prod", retries = 5)
    assert a[].name == "default" and b[].name == "prod" and b[].retries == 5

  let value = genSym(nskVar, "value")
  var body = newStmtList(newVarStmt(value, newCall(bindSym"unbox", b)))
  for arg in args:
    if arg.kind != nnkExprEqExpr:
      error("`copyWith` takes `field = value` arguments", arg)
    body.add newAssignment(newDotExpr(value, arg[0]), arg[1])
  body.add newCall(bindSym"box", newCall(bindSym"move", value))
  result = newBlockStmt(body)

type BoxField = object
  name: NimNode
  exported: bool
  typ: NimNode
  variant: bool ## a case discriminator or branch field: not addressable

proc boxFields(typ: NimNode, fields: var seq[BoxField]) =
  ## Collects every field of the object type `typ`, including inherited and
  ## case-object fields.
  let impl = typ.getImpl()
  if impl.kind != nnkTypeDef or impl[2].kind != nnkObjectTy:
    error("`boxAccessors` needs a non-generic object type", typ)
  let obj = impl[2]
  if obj[1].kind == nnkOfInherit and not obj[1][0].eqIdent("RootObj"):
    boxFields(obj[1][0], fields)
  proc walk(n: NimNode, variant: bool, fields: var seq[BoxField]) =
    case n.kind
    of nnkRecList:
      for child in n:
        walk(child, variant, fields)
    of nnkRecCase, nnkOfBranch, nnkElse:
      for child in n:
        walk(child, true, fields)
    of nnkIdentDefs:
      for i in 0 ..< n.len - 2:
        let name = n[i]
        let plain =
          if name.kind == nnkPostfix:
            name[1]
          else:
            name
        fields.add BoxField(
          name: ident($plain),
          exported: name.kind == nnkPostfix,
          typ: n[^2],
          variant: variant,
        )
    else:
      discard

  walk(obj[2], false, fields)

macro boxAccessors*(T: typedesc): untyped =
  ## Generates a getter on `Box[T]` for each field of the object type `T`,
  ## so `b.name` reads `b[].name`. A getter is exported when its field is,
  ## and fields that are not visible where this is called are skipped.
  runnableExamples:
    type Config = object
      name: string

    boxAccessors(Config)
    let b = box(Config(name: "x"))
    assert b.name == "x"

  let typ = T.getTypeInst()[1]
  if typ.kind != nnkSym:
    error("`boxAccessors` needs a non-generic object type", T)
  var fields: seq[BoxField]
  boxFields(typ, fields)
  result = newStmtList()
  let boxType = nnkBracketExpr.newTree(bindSym"Box", typ)
  let deref = bindSym"[]"
  for field in fields:
    let name = field.name
    let getter =
      if field.exported:
        postfix(name, "*")
      else:
        name
    # Case-object fields cannot be returned by reference, so copy them.
    let returnType =
      if field.variant:
        field.typ
      else:
        nnkCommand.newTree(ident"lent", field.typ)
    let b = ident"b"
    let getterProc = newProc(
      getter,
      [returnType, newIdentDefs(b, boxType)],
      newDotExpr(newCall(deref, b), name),
      pragmas = nnkPragma.newTree(ident"inline"),
    )
    # Skip fields that are private to another module. `default(T)` must use
    # the macro's typedesc argument: with the resolved symbol, `compiles`
    # evaluates false even for visible fields.
    let visible = newCall(ident"compiles", newDotExpr(newCall(ident"default", T), name))
    result.add nnkWhenStmt.newTree(
      nnkElifBranch.newTree(visible, newStmtList(getterProc))
    )
