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

proc get*[T](b: Box[T]): Option[T] =
  ## The boxed value, or `none` for an empty box.
  if b.isEmpty:
    none(T)
  else:
    some(b[])

proc getOrDefault*[T](b: Box[T], def: T = default(T)): T =
  ## The boxed value, or `def` for an empty box.
  if b.isEmpty: def else: b[]

proc update*[T, F](b: sink Box[T], f: F): Box[T] =
  ## Returns a box holding `f(b[])`. Reuses the allocation when `b` is
  ## uniquely owned.
  if b.node != nil and isUnique(b.node):
    result = b
    result.node.value = f(move(result.node.value))
  else:
    result = box(f(b[]))

template updateIt*[T](b: Box[T], op: untyped): Box[T] =
  ## Like `update`, with the new value given as an expression of `it`, the
  ## boxed value: `numbers.updateIt(it & 4)`. Raises `ValueError` for an
  ## empty box.
  block:
    let it {.inject.} = b[]
    box(op)

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
