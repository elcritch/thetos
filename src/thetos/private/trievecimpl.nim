# Included by the container modules and by `thetos/local`; not a module.
# The including module imports `std/[bitops, hashes, options]` and
# `private/core`, and declares `RcCount`, the type of each node's `rc`.

const
  vecBits = 5
  vecWidth = 1 shl vecBits
  vecMask = vecWidth - 1

type
  VecNode[T] = object
    rc*: RcCount # exported for the generic refcount helpers in core
    count: int
    leaf: bool

  VecPtr[T] = ptr VecNode[T]

  TrieVec*[T] = object ## Immutable, structurally shared vector with value semantics.
    size: int
    shift: int ## level of `root`; meaningful only when `root != nil`
    root: VecPtr[T] ## inner node, nil while everything fits in `tail`
    tail: VecPtr[T] ## leaf holding the last 1..32 elements

template childArr[T](n: VecPtr[T]): ptr UncheckedArray[VecPtr[T]] =
  cast[ptr UncheckedArray[VecPtr[T]]](cast[uint](n) + uint(sizeof(VecNode[T])))

template elemArr[T](n: VecPtr[T]): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](cast[uint](n) +
    uint(alignUp(sizeof(VecNode[T]), alignof(T))))

proc allocLeaf[T](): VecPtr[T] =
  static:
    doAssert alignof(T) <= 16, "element alignment above 16 is unsupported"
  result = cast[VecPtr[T]](allocRaw(
    alignUp(sizeof(VecNode[T]), alignof(T)) + vecWidth * sizeof(T)
  ))
  initRc(result)
  result.leaf = true

proc allocInner[T](): VecPtr[T] =
  result = cast[VecPtr[T]](allocRaw(sizeof(VecNode[T]) + vecWidth * sizeof(pointer)))
  initRc(result)

proc release[T](n: VecPtr[T]) {.raises: [], gcsafe.} =
  if n != nil and dropRef(n):
    if n.leaf:
      let es = n.elemArr
      for i in 0 ..< n.count:
        {.cast(raises: []), cast(gcsafe).}:
          `=destroy`(es[i])
    else:
      let cs = n.childArr
      for i in 0 ..< n.count:
        release(cs[i])
    freeRaw(n)

proc clone[T](n: VecPtr[T], count: int): VecPtr[T] =
  ## Copies the first `count` slots of `n`.
  if n.leaf:
    var leaf = allocLeaf[T]()
    defer:
      release(leaf)
    let src = n.elemArr
    let dst = leaf.elemArr
    for i in 0 ..< count:
      inc leaf.count
      dst[i] = src[i]
    return move(leaf)
  result = allocInner[T]()
  let src = n.childArr
  let dst = result.childArr
  for i in 0 ..< count:
    dst[i] = src[i]
    retain(src[i])
  result.count = count

proc ensureOwned[T](slot: var VecPtr[T]) =
  if not isUnique(slot):
    let c = clone(slot, slot.count)
    release(slot)
    slot = c

proc `=destroy`*[T](v: TrieVec[T]) =
  release(v.root)
  release(v.tail)

proc `=wasMoved`*[T](v: var TrieVec[T]) =
  v.size = 0
  v.shift = 0
  v.root = nil
  v.tail = nil

proc `=dup`*[T](v: TrieVec[T]): TrieVec[T] =
  if v.root != nil:
    retain(v.root)
  if v.tail != nil:
    retain(v.tail)
  result.size = v.size
  result.shift = v.shift
  result.root = v.root
  result.tail = v.tail

proc `=copy`*[T](dst: var TrieVec[T], src: TrieVec[T]) =
  if src.root != nil:
    retain(src.root)
  if src.tail != nil:
    retain(src.tail)
  `=destroy`(dst)
  dst.size = src.size
  dst.shift = src.shift
  dst.root = src.root
  dst.tail = src.tail

proc initTrieVec*[T](): TrieVec[T] =
  ## Returns an empty vector. `default(TrieVec[T])` is also empty.
  discard

proc len*[T](v: TrieVec[T]): int {.inline.} =
  v.size

proc high*[T](v: TrieVec[T]): int {.inline.} =
  v.size - 1

proc low*[T](v: TrieVec[T]): int {.inline.} =
  0

template tailOffset(size: int): int =
  (if size < vecWidth: 0 else: ((size - 1) shr vecBits) shl vecBits)

proc leafFor[T](v: TrieVec[T], i: int): VecPtr[T] {.inline.} =
  if i >= tailOffset(v.size):
    return v.tail
  var n = v.root
  var level = v.shift
  while level > 0:
    n = n.childArr[(i shr level) and vecMask]
    level -= vecBits
  n

template checkIndex(v, i: untyped) =
  if i < 0 or i >= v.size:
    raiseIndex(i, v.size)

proc `[]`*[T](v: TrieVec[T], i: Natural): lent T =
  checkIndex(v, i)
  v.leafFor(i).elemArr[i and vecMask]

proc `[]`*[T](v: TrieVec[T], i: BackwardsIndex): lent T =
  v[v.size - int(i)]

proc first*[T](v: TrieVec[T]): lent T =
  v[0]

proc last*[T](v: TrieVec[T]): lent T =
  v[v.size - 1]

proc newPath[T](level: int, node: VecPtr[T]): VecPtr[T] =
  if level == 0:
    return node
  result = allocInner[T]()
  result.childArr[0] = newPath(level - vecBits, node)
  result.count = 1

proc pushTail[T](slot: var VecPtr[T], level, size: int, tailNode: VecPtr[T]) =
  ## Appends the full `tailNode` as the last leaf below `slot`.
  ensureOwned(slot)
  let sub = ((size - 1) shr level) and vecMask
  if level == vecBits:
    slot.childArr[sub] = tailNode
    slot.count = sub + 1
  elif sub < slot.count:
    pushTail(slot.childArr[sub], level - vecBits, size, tailNode)
  else:
    slot.childArr[sub] = newPath(level - vecBits, tailNode)
    slot.count = sub + 1

proc add*[T](v: var TrieVec[T], x: sink T) =
  ## Appends `x` to this vector value only; other copies are not affected.
  # Keep the incoming value owned locally while a shared leaf is copied.
  var value = x
  defer:
    reset(value)
  if v.tail == nil:
    v.tail = allocLeaf[T]()
  elif v.size - tailOffset(v.size) < vecWidth:
    ensureOwned(v.tail)
  else:
    # Tail is full: move it into the tree.
    if v.root == nil:
      v.root = allocInner[T]()
      v.shift = vecBits
    if (v.size shr vecBits) > (1 shl v.shift):
      let top = allocInner[T]()
      top.childArr[0] = v.root
      top.childArr[1] = newPath(v.shift, v.tail)
      top.count = 2
      v.root = top
      v.shift += vecBits
    else:
      pushTail(v.root, v.shift, v.size, v.tail)
    v.tail = allocLeaf[T]()
  v.tail.elemArr[v.tail.count] = move(value)
  inc v.tail.count
  inc v.size

proc add*[T](v: var TrieVec[T], xs: openArray[T]) =
  for x in xs:
    appendCopy(v, x)

proc assocRec[T](slot: var VecPtr[T], level, i: int, value: var T) =
  ensureOwned(slot)
  if level == 0:
    slot.elemArr[i and vecMask] = move(value)
  else:
    assocRec(slot.childArr[(i shr level) and vecMask], level - vecBits, i, value)

proc `[]=`*[T](v: var TrieVec[T], i: Natural, x: sink T) =
  ## Replaces element `i` in this vector value only.
  var value = x
  defer:
    reset(value)
  checkIndex(v, i)
  let off = tailOffset(v.size)
  if i >= off:
    ensureOwned(v.tail)
    v.tail.elemArr[i - off] = move(value)
  else:
    assocRec(v.root, v.shift, i, value)

proc popTail[T](slot: var VecPtr[T], level, size: int) =
  ## Removes the last leaf below `slot`; sets `slot` to nil if emptied.
  let sub = ((size - 2) shr level) and vecMask
  if level > vecBits:
    ensureOwned(slot)
    popTail(slot.childArr[sub], level - vecBits, size)
    if slot.childArr[sub] == nil:
      slot.count = sub
      if sub == 0:
        release(slot)
        slot = nil
  elif sub == 0:
    release(slot)
    slot = nil
  else:
    ensureOwned(slot)
    release(slot.childArr[sub])
    slot.childArr[sub] = nil
    slot.count = sub

proc pop*[T](v: var TrieVec[T]): T =
  ## Removes and returns the last element.
  if v.size == 0:
    raiseIndex(0, 0)
  resetOnError(result):
    let tcount = v.size - tailOffset(v.size)
    if tcount > 1 or v.size == 1:
      if isUnique(v.tail):
        result = move(v.tail.elemArr[tcount - 1])
        dec v.tail.count
      else:
        result = v.tail.elemArr[tcount - 1]
        let t = clone(v.tail, tcount - 1)
        release(v.tail)
        v.tail = t
      if v.size == 1:
        release(v.tail)
        v.tail = nil
      dec v.size
      return
    # The tail holds one element: the last tree leaf becomes the new tail.
    if isUnique(v.tail):
      result = move(v.tail.elemArr[0])
    else:
      result = v.tail.elemArr[0]
    release(v.tail)
    let newTail = v.leafFor(v.size - 2)
    retain(newTail)
    popTail(v.root, v.shift, v.size)
    if v.root == nil:
      v.shift = 0
    elif v.shift > vecBits and v.root.count == 1:
      let child = v.root.childArr[0]
      retain(child)
      release(v.root)
      v.root = child
      v.shift -= vecBits
    v.tail = newTail
    dec v.size

proc pushBack*[T](v: sink TrieVec[T], x: sink T): TrieVec[T] =
  ## Returns a vector with `x` appended.
  result = v
  resetOnCopyError(T, result):
    result.add(x)

proc popBack*[T](v: sink TrieVec[T]): TrieVec[T] =
  ## Returns a vector without its last element.
  result = v
  resetOnCopyError(T, result):
    discard result.pop()

proc put*[T](v: sink TrieVec[T], i: Natural, x: sink T): TrieVec[T] =
  ## Returns a vector with element `i` replaced by `x`.
  result = v
  resetOnError(result):
    result[i] = x

proc update*[T, F](v: sink TrieVec[T], i: Natural, f: F): TrieVec[T] =
  ## Returns a vector with element `i` replaced by `f(v[i])`.
  result = v
  resetOnError(result):
    let next = f(result[i])
    result[i] = next

proc take*[T](v: sink TrieVec[T], n: Natural): TrieVec[T] =
  ## Returns the first `n` elements.
  result = v
  resetOnError(result):
    while result.size > n:
      discard result.pop()

proc toTrieVec*[T](xs: openArray[T]): TrieVec[T] =
  resetOnError(result):
    result.add(xs)

iterator items*[T](v: TrieVec[T]): lent T =
  let keep = `=dup`(v) # iterate a snapshot even if `v` is reassigned
  let off = tailOffset(keep.size)
  var i = 0
  while i < off:
    let leaf = keep.leafFor(i)
    for j in 0 ..< vecWidth:
      yield leaf.elemArr[j]
    i += vecWidth
  for j in 0 ..< keep.size - off:
    yield keep.tail.elemArr[j]

iterator pairs*[T](v: TrieVec[T]): (int, T) =
  var i = 0
  for x in v:
    yield (i, x)
    inc i

proc `&`*[T](a: sink TrieVec[T], b: TrieVec[T]): TrieVec[T] =
  result = a
  resetOnError(result):
    for x in b:
      appendCopy(result, x)

proc `==`*[T](a, b: TrieVec[T]): bool =
  if a.size != b.size:
    return false
  if a.root == b.root and a.tail == b.tail:
    return true
  var i = 0
  for x in a:
    if not (x == b[i]):
      return false
    inc i
  true

proc hash*[T](v: TrieVec[T]): Hash =
  var h: Hash = 0
  for x in v:
    h = h !& hash(x)
  !$h

proc `$`*[T](v: TrieVec[T]): string =
  result = "["
  var first = true
  for x in v:
    if not first:
      result.add ", "
    first = false
    result.addQuoted x
  result.add "]"
