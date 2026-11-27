# Included by the container modules and by `thetos/local`; not a module.
# The including module imports `std/[hashes, macros, options, typetraits]` and
# `private/core`, and declares `RcCount`, the type of each node's `rc`.

const
  flexBits = 5
  flexWidth = 1 shl flexBits
  extraSteps = 2 ## extra nodes a concatenation may leave per level (RRB e_max)

template leafBits(T: typedesc): int =
  when sizeof(T) == 1 and supportsCopyMem(T): 7 else: flexBits

template leafWidth(T: typedesc): int =
  1 shl leafBits(T)

template childShift(T: typedesc, level: int): int =
  ## Inner levels advance by flexBits. The lowest level indexes full leaves.
  level + (leafBits(T) - flexBits)

type
  FlexNode[T] = object
    rc*: RcCount # exported for the generic refcount helpers in core
    count: int
    leaf: bool
    relaxed: bool ## inner node indexed through its size table

  FlexPtr[T] = ptr FlexNode[T]

  FlexNoHead* = object ## Marks `FlexVec`; see `FlexImpl`.
  FlexWithHead* = object ## Marks `FlexDeque`; see `FlexImpl`.

  FlexImpl*[T, H] = object
    ## The shared implementation of `FlexVec` and `FlexDeque`. With `H` set
    ## to `FlexWithHead`, the first elements are kept in a head leaf outside
    ## the tree. (A marker type rather than a `static bool`: Nim 2.2 crashes
    ## generating code for aliases of a type with a static parameter.)
    size: int
    shift: int ## level of `root` in steps of flexBits, 0 for a leaf
    root: FlexPtr[T] ## tree holding all but the head and tail, or nil
    tail: FlexPtr[T] ## leaf holding the final elements, nil when empty
    when H is FlexWithHead:
      head: FlexPtr[T] ## leaf holding the first elements, or nil

  FlexVec*[T] = FlexImpl[T, FlexNoHead]
    ## Immutable, structurally shared vector with O(log n) concatenation
    ## and slicing.

  FlexDeque*[T] = FlexImpl[T, FlexWithHead]
    ## A `FlexVec` that also keeps its first elements in a head leaf, so
    ## `pushFront` and repeated small `drop`s are amortized O(1). Indexing
    ## and concatenation cost slightly more, and values are one word larger.

template hasHead(H: typedesc): bool =
  H is FlexWithHead

# Public operations default to the vector layout for calls with explicit
# element types. The layout is inferred from the operands in ordinary calls.

# Inner nodes: header | children: array[32, ptr] | sizes: array[32, int].
# `sizes[k]` is the number of elements in children 0..k; it is only
# meaningful while `relaxed` is set. Leaves: header | elements.

template childArr[T](n: FlexPtr[T]): ptr UncheckedArray[FlexPtr[T]] =
  cast[ptr UncheckedArray[FlexPtr[T]]](cast[uint](n) + uint(sizeof(FlexNode[T])))

template sizeArr[T](n: FlexPtr[T]): ptr UncheckedArray[int] =
  cast[ptr UncheckedArray[int]](cast[uint](n) +
    uint(sizeof(FlexNode[T]) + flexWidth * sizeof(pointer)))

template elemArr[T](n: FlexPtr[T]): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](cast[uint](n) +
    uint(alignUp(sizeof(FlexNode[T]), alignof(T))))

proc allocFlexLeaf[T](): FlexPtr[T] =
  static:
    doAssert alignof(T) <= 16, "element alignment above 16 is unsupported"
  result = cast[FlexPtr[T]](allocRaw(
    alignUp(sizeof(FlexNode[T]), alignof(T)) + leafWidth(T) * sizeof(T)
  ))
  initRc(result)
  result.leaf = true

proc allocFlexInner[T](): FlexPtr[T] =
  # Slots at or past `count`, and sizes of a regular node, are never read,
  # so only the header is initialized.
  result = cast[FlexPtr[T]](allocRawUninit(
    sizeof(FlexNode[T]) + flexWidth * (sizeof(pointer) + sizeof(int))
  ))
  zeroMem(result, sizeof(FlexNode[T]))
  initRc(result)

proc release[T](n: FlexPtr[T]) {.raises: [], gcsafe.} =
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

proc subtreeSize[T](n: FlexPtr[T], shift: int): int =
  ## Number of elements below `n`, a node at level `shift`.
  var n = n
  var s = shift
  while s > 0:
    if n.relaxed:
      return result + n.sizeArr[n.count - 1]
    result += (n.count - 1) shl childShift(T, s)
    n = n.childArr[n.count - 1]
    s -= flexBits
  result + n.count

proc childStart[T](n: FlexPtr[T], s, j: int): int {.inline.} =
  if n.relaxed:
    (if j == 0: 0 else: n.sizeArr[j - 1])
  else:
    j shl childShift(T, s)

proc childSize[T](n: FlexPtr[T], s, j: int): int =
  if n.relaxed:
    n.sizeArr[j] - childStart(n, s, j)
  elif j < n.count - 1:
    1 shl childShift(T, s)
  else:
    subtreeSize(n.childArr[j], s - flexBits)

proc findChild[T](n: FlexPtr[T], s, idx: int): (int, int) {.inline.} =
  ## Child of the inner node `n` (level `s`) holding element `idx`, and the
  ## element's index inside that child.
  let bits = childShift(T, s)
  if n.relaxed:
    let sizes = n.sizeArr
    # Children hold at most `1 shl bits` elements, so this guess is a lower bound.
    var j = idx shr bits
    while sizes[j] <= idx:
      inc j
    (
      j,
      if j == 0:
        idx
      else:
        idx - sizes[j - 1],
    )
  else:
    (idx shr bits, idx and ((1 shl bits) - 1))

proc finishInner[T](n: FlexPtr[T], s: int, sizes: openArray[int]): int {.discardable.} =
  ## Fills the size table of a freshly built inner node from the sizes of
  ## its children, marks it regular when every child but the last is full,
  ## and returns its size.
  var regular = true
  for k in 0 ..< n.count:
    if k < n.count - 1 and sizes[k] != 1 shl childShift(T, s):
      regular = false
    result += sizes[k]
    n.sizeArr[k] = result
  n.relaxed = not regular

proc finishInner[T](n: FlexPtr[T], s: int): int {.discardable.} =
  var sizes {.noinit.}: array[flexWidth, int]
  for k in 0 ..< n.count:
    sizes[k] = subtreeSize(n.childArr[k], s - flexBits)
  finishInner(n, s, toOpenArray(sizes, 0, n.count - 1))

proc relax[T](n: FlexPtr[T], s: int) =
  finishInner(n, s)
  n.relaxed = true

proc clone[T](n: FlexPtr[T], count: int): FlexPtr[T] {.noinline.} =
  ## Copies the first `count` slots of `n`. Kept out of line: inlined into
  ## `ensureOwned` it slowed in-place `[]=` by about a third on amd64.
  if n.leaf:
    var leaf = allocFlexLeaf[T]()
    defer:
      release(leaf)
    let src = n.elemArr
    let dst = leaf.elemArr
    for i in 0 ..< count:
      # Count the slot first so cleanup covers a copy that fails partway.
      inc leaf.count
      dst[i] = src[i]
    return move(leaf)
  result = allocFlexInner[T]()
  let src = n.childArr
  let dst = result.childArr
  for i in 0 ..< count:
    dst[i] = src[i]
    retain(src[i])
  if n.relaxed:
    copyMem(result.sizeArr, n.sizeArr, count * sizeof(int))
  result.count = count
  result.relaxed = n.relaxed

proc ensureOwned[T](slot: var FlexPtr[T]) =
  if not isUnique(slot):
    let c = clone(slot, slot.count)
    release(slot)
    slot = c

proc `=destroy`*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]) =
  release(v.root)
  release(v.tail)
  when hasHead(H):
    release(v.head)

proc `=wasMoved`*[T; H: auto = FlexNoHead](v: var FlexImpl[T, H]) =
  v.size = 0
  v.shift = 0
  v.root = nil
  v.tail = nil
  when hasHead(H):
    v.head = nil

proc `=dup`*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): FlexImpl[T, H] =
  if v.root != nil:
    retain(v.root)
  if v.tail != nil:
    retain(v.tail)
  result.size = v.size
  result.shift = v.shift
  result.root = v.root
  result.tail = v.tail
  when hasHead(H):
    if v.head != nil:
      retain(v.head)
    result.head = v.head

proc `=copy`*[T; H: auto = FlexNoHead](dst: var FlexImpl[T, H], src: FlexImpl[T, H]) =
  if src.root != nil:
    retain(src.root)
  if src.tail != nil:
    retain(src.tail)
  when hasHead(H):
    if src.head != nil:
      retain(src.head)
  `=destroy`(dst)
  dst.size = src.size
  dst.shift = src.shift
  dst.root = src.root
  dst.tail = src.tail
  when hasHead(H):
    dst.head = src.head

proc initFlexVec*[T](): FlexVec[T] =
  ## Returns an empty vector. `default(FlexVec[T])` is also empty.
  discard

proc initFlexDeque*[T](): FlexDeque[T] =
  ## Returns an empty deque. `default(FlexDeque[T])` is also empty.
  discard

proc len*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): int {.inline.} =
  v.size

proc high*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): int {.inline.} =
  v.size - 1

proc low*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): int {.inline.} =
  0

proc headLen[T, H](v: FlexImpl[T, H]): int {.inline.} =
  when hasHead(H):
    (if v.head == nil: 0 else: v.head.count)
  else:
    0

template tailStart(v: FlexImpl): int =
  ## Index of the first element in the tail.
  (if v.tail == nil: 0 else: v.size - v.tail.count)

proc leafAt[T](root: FlexPtr[T], shift, idx: int): (FlexPtr[T], int) =
  ## The leaf holding element `idx` of the tree and the index of its first
  ## element.
  var n = root
  var s = shift
  var i = idx
  while s > 0:
    let (j, local) = findChild(n, s, i)
    i = local
    n = n.childArr[j]
    s -= flexBits
  (n, idx - i)

template checkFlexIndex(v, i: untyped) =
  if i < 0 or i >= v.size:
    raiseIndex(i, v.size)

proc `[]`*[T; H: auto = FlexNoHead](v: FlexImpl[T, H], i: Natural): lent T =
  checkFlexIndex(v, i)
  let off = v.size - v.tail.count # the tail exists once the index is valid
  if i >= off:
    return v.tail.elemArr[i - off]
  var idx = int(i)
  when hasHead(H):
    let head = v.head
    if head != nil:
      if idx < head.count:
        return head.elemArr[idx]
      idx -= head.count
  var n = v.root
  var s = v.shift
  while s > 0:
    let (j, local) = findChild(n, s, idx)
    idx = local
    n = n.childArr[j]
    s -= flexBits
  n.elemArr[idx]

proc `[]`*[T; H: auto = FlexNoHead](v: FlexImpl[T, H], i: BackwardsIndex): lent T =
  v[v.size - int(i)]

proc first*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): lent T =
  v[0]

proc last*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): lent T =
  v[v.size - 1]

proc get*[T; H: auto = FlexNoHead](v: FlexImpl[T, H], i: int): Option[T] =
  ## Element `i`, or `none` when `i` is out of range (including negative).
  if i >= 0 and i < v.len:
    option(ownedCopy(v[i]))
  else:
    none(T)

proc getOrDefault*[T; H: auto = FlexNoHead](
    v: FlexImpl[T, H], i: int, def: T = default(T)
): T =
  ## Element `i`, or `def` when `i` is out of range (including negative).
  if i >= 0 and i < v.len:
    v[i]
  else:
    def

proc newPath[T](level: int, node: FlexPtr[T]): FlexPtr[T] =
  if level == 0:
    return node
  result = allocFlexInner[T]()
  result.childArr[0] = newPath(level - flexBits, node)
  result.count = 1

proc roomOnRight[T](n: FlexPtr[T], shift: int): bool =
  ## True when a leaf can be appended below the inner node `n` without
  ## growing it.
  var n = n
  var s = shift
  while true:
    if n.count < flexWidth:
      return true
    if s == flexBits:
      return false
    n = n.childArr[n.count - 1]
    s -= flexBits

proc pushLeafRec[T](slot: var FlexPtr[T], s: int, leaf: FlexPtr[T], leafSize: int) =
  ensureOwned(slot)
  let n = slot
  let last = n.count - 1
  if s > flexBits and roomOnRight(n.childArr[last], s - flexBits):
    pushLeafRec(n.childArr[last], s - flexBits, leaf, leafSize)
    if n.relaxed:
      n.sizeArr[last] += leafSize
  else:
    # Radix indexing needs every child but the last to be full.
    if not n.relaxed and childSize(n, s, last) != 1 shl childShift(T, s):
      relax(n, s)
    n.childArr[n.count] = newPath(s - flexBits, leaf)
    if n.relaxed:
      n.sizeArr[n.count] = n.sizeArr[last] + leafSize
    inc n.count

proc pushLeaf[T](root: var FlexPtr[T], shift: var int, leaf: FlexPtr[T]) =
  ## Appends `leaf` (ownership transferred) as the last leaf of the tree.
  if root == nil:
    root = leaf
    shift = 0
  elif shift > 0 and roomOnRight(root, shift):
    pushLeafRec(root, shift, leaf, leaf.count)
  else:
    let top = allocFlexInner[T]()
    top.childArr[0] = root
    top.childArr[1] = newPath(shift, leaf)
    top.count = 2
    finishInner(top, shift + flexBits)
    root = top
    shift += flexBits

proc normalize[T](root: var FlexPtr[T], shift: var int) =
  ## Drops roots with a single child.
  while shift > 0 and root.count == 1:
    let child = root.childArr[0]
    retain(child)
    release(root)
    root = child
    shift -= flexBits

proc raiseFlexOverflow() {.noinline, noreturn.} =
  raise newException(OverflowDefect, "FlexVec length exceeds high(int)")

proc add*[T; H: auto = FlexNoHead](v: var FlexImpl[T, H], x: sink T) =
  ## Appends `x` to this vector value only; other copies are not affected.
  # Keep the incoming value owned locally while a shared leaf is copied.
  var value = x
  defer:
    reset(value)
  if v.size == high(int):
    raiseFlexOverflow()
  if v.tail == nil:
    v.tail = allocFlexLeaf[T]()
  elif v.tail.count < leafWidth(T):
    ensureOwned(v.tail)
  else:
    pushLeaf(v.root, v.shift, v.tail)
    v.tail = nil
    v.tail = allocFlexLeaf[T]()
  v.tail.elemArr[v.tail.count] = move(value)
  inc v.tail.count
  inc v.size

proc add*[T; H: auto = FlexNoHead](v: var FlexImpl[T, H], xs: openArray[T]) =
  ## Appends every element of `xs` to this vector value only.
  if xs.len > high(int) - v.size:
    raiseFlexOverflow()
  when supportsCopyMem(T):
    # Plain data: fill the tail a leaf at a time.
    var i = 0
    while i < xs.len:
      if v.tail != nil and v.tail.count < leafWidth(T) and isUnique(v.tail):
        let k = min(leafWidth(T) - v.tail.count, xs.len - i)
        copyMem(addr v.tail.elemArr[v.tail.count], unsafeAddr xs[i], k * sizeof(T))
        v.tail.count += k
        v.size += k
        i += k
      else:
        v.add(xs[i]) # allocates, pushes or unshares the tail
        inc i
  else:
    for x in xs:
      appendCopy(v, x)

proc assocRec[T](slot: var FlexPtr[T], s, idx: int, value: var T) =
  ensureOwned(slot)
  if s == 0:
    slot.elemArr[idx] = move(value)
  else:
    let (j, local) = findChild(slot, s, idx)
    assocRec(slot.childArr[j], s - flexBits, local, value)

proc `[]=`*[T; H: auto = FlexNoHead](v: var FlexImpl[T, H], i: Natural, x: sink T) =
  ## Replaces element `i` in this vector value only.
  var value = x
  defer:
    reset(value)
  checkFlexIndex(v, i)
  let off = v.size - v.tail.count # the tail exists once the index is valid
  if i >= off:
    ensureOwned(v.tail)
    v.tail.elemArr[i - off] = move(value)
    return
  var idx = int(i)
  when hasHead(H):
    if v.head != nil:
      if idx < v.head.count:
        ensureOwned(v.head)
        v.head.elemArr[idx] = move(value)
        return
      idx -= v.head.count
  assocRec(v.root, v.shift, idx, value)

proc treeTake[T](slot: var FlexPtr[T], s, n: int) =
  ## Keeps the first `n` elements below `slot`, where `0 < n < size` and `n`
  ## falls on a leaf boundary.
  assert s > 0
  let (j, local) = findChild(slot, s, n - 1)
  let m = local + 1
  if isUnique(slot):
    for k in j + 1 ..< slot.count:
      release(slot.childArr[k])
    slot.count = j + 1
  else:
    let c = clone(slot, j + 1)
    release(slot)
    slot = c
  if m < childSize(slot, s, j):
    treeTake(slot.childArr[j], s - flexBits, m)
  if slot.relaxed:
    slot.sizeArr[j] = n

proc truncate[T, H](v: var FlexImpl[T, H], n: int) =
  ## Keeps the first `n` elements.
  if n >= v.size:
    return
  if n <= 0:
    `=destroy`(v)
    `=wasMoved`(v)
    return
  let off = v.tailStart
  let hc = v.headLen
  if n > off:
    let keep = n - off
    if isUnique(v.tail):
      for k in keep ..< v.tail.count:
        reset(v.tail.elemArr[k])
      v.tail.count = keep
    else:
      let c = clone(v.tail, keep)
      release(v.tail)
      v.tail = c
  else:
    when hasHead(H):
      if n <= hc:
        # What is left of the head becomes the tail.
        let newTail = (if n == hc: (retain(v.head); v.head) else: clone(v.head, n))
        release(v.root)
        release(v.tail)
        release(v.head)
        v.root = nil
        v.shift = 0
        v.head = nil
        v.tail = newTail
        v.size = n
        return
    # The leaf holding the new last element becomes the tail.
    let m = n - hc # elements kept in the tree
    let (leaf, start) = leafAt(v.root, v.shift, m - 1)
    var newTail: FlexPtr[T]
    if m - start == leaf.count:
      retain(leaf)
      newTail = leaf
    else:
      newTail = clone(leaf, m - start)
    release(v.tail)
    v.tail = newTail
    if start == 0:
      release(v.root)
      v.root = nil
      v.shift = 0
    else:
      treeTake(v.root, v.shift, start)
      normalize(v.root, v.shift)
  v.size = n

proc treeDrop[T](node: FlexPtr[T], s, n: int): FlexPtr[T] =
  ## A new node holding all but the first `n` elements below `node`, where
  ## `0 < n < size`.
  if s == 0:
    var leaf = allocFlexLeaf[T]()
    defer:
      release(leaf)
    for k in n ..< node.count:
      inc leaf.count
      leaf.elemArr[leaf.count - 1] = node.elemArr[k]
    return move(leaf)
  let (j, local) = findChild(node, s, n)
  var first: FlexPtr[T]
  if local == 0:
    first = node.childArr[j]
    retain(first)
  else:
    first = treeDrop(node.childArr[j], s - flexBits, local)
  result = allocFlexInner[T]()
  result.childArr[0] = first
  for k in j + 1 ..< node.count:
    result.childArr[k - j] = node.childArr[k]
    retain(node.childArr[k])
  result.count = node.count - j
  finishInner(result, s)

proc dropFront[T, H](v: var FlexImpl[T, H], n: int, toHead = true) =
  ## Removes the first `n` elements. With `toHead`, what is left of a
  ## partly dropped tree leaf becomes the head, so further small drops do
  ## not touch the tree; callers that concatenate right away pass false.
  if n <= 0:
    return
  if n >= v.size:
    `=destroy`(v)
    `=wasMoved`(v)
    return
  let hc = v.headLen
  when hasHead(H):
    if n <= hc:
      let head = (if n == hc: nil else: treeDrop(v.head, 0, n))
      release(v.head)
      v.head = head
      v.size -= n
      return
  let off = v.tailStart
  if n >= off:
    let newTail =
      (if n == off: (retain(v.tail); v.tail) else: treeDrop(v.tail, 0, n - off))
    release(v.root)
    release(v.tail)
    v.root = nil
    v.shift = 0
    v.tail = newTail
    when hasHead(H):
      release(v.head)
      v.head = nil
    v.size -= n
    return
  when hasHead(H):
    if toHead:
      let m = n - hc # elements dropped from the tree
      let (leaf, start) = leafAt(v.root, v.shift, m)
      let next = start + leaf.count
      var head =
        (if m == start: (retain(leaf); leaf) else: treeDrop(leaf, 0, m - start))
      var root: FlexPtr[T]
      var shift = 0
      if next < off - hc:
        root = treeDrop(v.root, v.shift, next)
        shift = v.shift
        normalize(root, shift)
      release(v.root)
      release(v.head)
      v.root = root
      v.shift = shift
      v.head = head
      v.size -= n
      return
  var root = treeDrop(v.root, v.shift, n - hc)
  var shift = v.shift
  normalize(root, shift)
  release(v.root)
  v.root = root
  v.shift = shift
  when hasHead(H):
    release(v.head)
    v.head = nil
  v.size -= n

# Concatenation ----------------------------------------------------------
#
# Follows the RRB concatenation of Bagwell and Rompf with the rebalancing
# plan of L'orange's thesis, as in immer's `rbts/operations.hpp`: the right
# edge of the left tree and the left edge of the right tree are merged level
# by level, redistributing slots only when a level would otherwise exceed
# the optimal node count by more than `extraSteps`.

const maxMerge = 2 * flexWidth
  ## Nodes merged at one level: all but one slot each of `left` and `right`,
  ## and the one or two of `center`.

type MergeBuf[T] = object
  ## Owned nodes made by `executePlan`, released unless handed on.
  nodes: array[maxMerge, FlexPtr[T]]
  sizes: array[maxMerge, int] ## elements below each node
  len: int

proc `=destroy`[T](b: MergeBuf[T]) =
  for i in 0 ..< b.len:
    release(b.nodes[i])

proc `=copy`[T](dst: var MergeBuf[T], src: MergeBuf[T]) {.error.}

proc executePlan[T](all: openArray[FlexPtr[T]], level: int, res: var MergeBuf[T]) =
  ## Redistributes the slots of the nodes in `all` (borrowed, at `level`)
  ## into owned nodes in `res`, reusing nodes that need no change.
  var plan {.noinit.}: array[maxMerge, int]
  var total = 0
  for i, n in all:
    plan[i] = n.count
    total += n.count
  var n = all.len
  let width =
    if level == 0:
      leafWidth(T)
    else:
      flexWidth
  let optimal = (total + width - 1) div width
  var i = 0
  while n > optimal + extraSteps:
    while i + 1 < n and plan[i] > width - extraSteps div 2:
      inc i
    if i + 1 >= n:
      break
    var remaining = plan[i]
    while remaining > 0:
      let size = min(remaining + plan[i + 1], width)
      plan[i] = size
      remaining = remaining + plan[i + 1] - size
      inc i
    for j in i ..< n - 1:
      plan[j] = plan[j + 1]
    dec n
    dec i

  var idx = 0
  var offset = 0
  for p in 0 ..< n:
    let target = plan[p]
    if offset == 0 and all[idx].count == target:
      retain(all[idx])
      res.nodes[res.len] = all[idx]
      res.sizes[res.len] = subtreeSize(all[idx], level)
      inc res.len
      inc idx
      continue
    let node = (if level == 0: allocFlexLeaf[T]() else: allocFlexInner[T]())
    res.nodes[res.len] = node
    inc res.len
    var filled = 0
    while filled < target:
      let src = all[idx]
      let take = min(target - filled, src.count - offset)
      if level == 0:
        for k in 0 ..< take:
          inc node.count
          node.elemArr[node.count - 1] = src.elemArr[offset + k]
      else:
        for k in 0 ..< take:
          let child = src.childArr[offset + k]
          retain(child)
          node.childArr[node.count] = child
          inc node.count
      filled += take
      offset += take
      if offset == src.count:
        inc idx
        offset = 0
    res.sizes[res.len - 1] =
      if level > 0:
        finishInner(node, level)
      else:
        node.count

proc rebalance[T](left, center, right: FlexPtr[T], s: int): FlexPtr[T] =
  ## Merges the children of `left` (all but its last), of `center` (owned,
  ## at level `s`) and of `right` (all but its first) into a new node at
  ## level `s + flexBits` holding one or two nodes at level `s`.
  defer:
    release(center)
  assert center.count <= 2
  var all {.noinit.}: array[maxMerge, FlexPtr[T]]
  var count = 0
  if left != nil:
    for k in 0 ..< left.count - 1:
      all[count] = left.childArr[k]
      inc count
  for k in 0 ..< center.count:
    all[count] = center.childArr[k]
    inc count
  if right != nil:
    for k in 1 ..< right.count:
      all[count] = right.childArr[k]
      inc count
  var nodes: MergeBuf[T]
  executePlan(toOpenArray(all, 0, count - 1), s - flexBits, nodes)
  result = allocFlexInner[T]()
  var sizes: array[2, int]
  var k = 0
  while k < nodes.len:
    let n = allocFlexInner[T]()
    let first = k
    while k < nodes.len and n.count < flexWidth:
      n.childArr[n.count] = nodes.nodes[k]
      inc n.count
      inc k
    sizes[result.count] = finishInner(n, s, toOpenArray(nodes.sizes, first, k - 1))
    result.childArr[result.count] = n
    inc result.count
  nodes.len = 0 # handed to the new nodes
  finishInner(result, s + flexBits, toOpenArray(sizes, 0, result.count - 1))

proc concatSub[T](left: FlexPtr[T], ls: int, right: FlexPtr[T], rs: int): FlexPtr[T] =
  ## Concatenates `left` (level `ls`) and `right` (level `rs`) into a new
  ## node at level `max(ls, rs) + flexBits` with one or two children.
  if ls > rs:
    let c = concatSub(left.childArr[left.count - 1], ls - flexBits, right, rs)
    result = rebalance[T](left, c, nil, ls)
  elif ls < rs:
    let c = concatSub(left, ls, right.childArr[0], rs - flexBits)
    result = rebalance[T](nil, c, right, rs)
  elif ls == 0:
    var merged: FlexPtr[T]
    if left.count + right.count <= leafWidth(T):
      merged = clone(left, left.count)
      defer:
        release(merged)
      for k in 0 ..< right.count:
        inc merged.count
        merged.elemArr[merged.count - 1] = right.elemArr[k]
      result = allocFlexInner[T]()
      result.childArr[0] = move(merged)
      result.count = 1
    else:
      result = allocFlexInner[T]()
      retain(left)
      retain(right)
      result.childArr[0] = left
      result.childArr[1] = right
      result.count = 2
    finishInner(result, flexBits)
  else:
    let c = concatSub(
      left.childArr[left.count - 1], ls - flexBits, right.childArr[0], rs - flexBits
    )
    result = rebalance[T](left, c, right, ls)

proc concatTrees[T](
    left: FlexPtr[T], ls: int, right: FlexPtr[T], rs: int
): (FlexPtr[T], int) =
  ## A new tree holding `left` followed by `right` (both borrowed).
  var root = concatSub(left, ls, right, rs)
  var shift = max(ls, rs) + flexBits
  normalize(root, shift)
  (root, shift)

proc add*[T; H, G: auto = FlexNoHead](v: var FlexImpl[T, H], w: FlexImpl[T, G]) =
  ## Appends every element of `w` to this vector value only, in O(log n).
  if w.size > high(int) - v.size:
    raiseFlexOverflow()
  if w.size == 0:
    return
  if v.size == 0:
    when H is G:
      v = w
    elif hasHead(H):
      v = toFlexDeque(w)
    else:
      v = toFlexVec(w)
    return
  let keep = `=dup`(w) # `w` may alias `v`
  if keep.root == nil:
    # Few elements, all in the head and tail of `w`.
    when supportsCopyMem(T):
      when hasHead(G):
        if keep.head != nil:
          v.add(toOpenArray(keep.head.elemArr, 0, keep.head.count - 1))
      v.add(toOpenArray(keep.tail.elemArr, 0, keep.tail.count - 1))
    else:
      # Append them through a copy so a failing element copy leaves `v`
      # unchanged.
      var res = v
      when hasHead(G):
        if keep.head != nil:
          for k in 0 ..< keep.head.count:
            appendCopy(res, keep.head.elemArr[k])
      for k in 0 ..< keep.tail.count:
        appendCopy(res, keep.tail.elemArr[k])
      v = move(res)
    return
  # The left tree is the tree of `v` followed by its tail and the head of
  # `w`; the head of `v` stays in place.
  var left: FlexVec[T]
  left.root = v.root
  left.shift = v.shift
  when supportsCopyMem(T):
    # Concatenation cannot fail part way, so hand `v`'s references to the
    # left tree; nodes only `v` owns are then edited in place.
    v.root = nil
    pushLeaf(left.root, left.shift, v.tail)
    v.tail = nil
  else:
    # An element copy may fail, so leave `v` untouched until the end.
    if left.root != nil:
      retain(left.root)
    retain(v.tail)
    pushLeaf(left.root, left.shift, v.tail)
  when hasHead(G):
    if keep.head != nil:
      retain(keep.head)
      pushLeaf(left.root, left.shift, keep.head)
  let (root, shift) = concatTrees(left.root, left.shift, keep.root, keep.shift)
  release(v.root)
  release(v.tail)
  v.root = root
  v.shift = shift
  retain(keep.tail)
  v.tail = keep.tail
  v.size += keep.size

proc absorbHead[T](v: var FlexDeque[T]) =
  ## Moves the head leaf into the tree.
  if v.root == nil:
    v.root = v.head
    v.shift = 0
  else:
    let (root, shift) = concatTrees(v.head, 0, v.root, v.shift)
    release(v.root)
    release(v.head)
    v.root = root
    v.shift = shift
  v.head = nil

proc prepend[T](v: var FlexDeque[T], x: sink T) =
  var value = x
  defer:
    reset(value)
  if v.size == high(int):
    raiseFlexOverflow()
  if v.size == 0:
    v.add(move(value))
    return
  if v.head == nil:
    v.head = allocFlexLeaf[T]()
  elif v.head.count == leafWidth(T):
    absorbHead(v)
    v.head = allocFlexLeaf[T]()
  else:
    ensureOwned(v.head)
  let es = v.head.elemArr
  when supportsCopyMem(T):
    moveMem(addr es[1], addr es[0], v.head.count * sizeof(T))
  else:
    for k in countdown(v.head.count, 1):
      es[k] = move(es[k - 1])
  es[0] = move(value)
  inc v.head.count
  inc v.size

proc `&`*[T; H, G: auto = FlexNoHead](
    a: sink FlexImpl[T, H], b: FlexImpl[T, G]
): FlexImpl[T, H] =
  ## Concatenation in O(log n). The result has the type of `a`.
  result = a
  resetOnError(result):
    result.add(b)

proc pop*[T; H: auto = FlexNoHead](v: var FlexImpl[T, H]): T =
  ## Removes and returns the last element.
  if v.size == 0:
    raiseIndex(0, 0)
  let c = v.tail.count
  resetOnError(result):
    if isUnique(v.tail):
      result = move(v.tail.elemArr[c - 1])
    else:
      result = v.tail.elemArr[c - 1]
    truncate(v, v.size - 1)

proc pushBackImpl[T, H](v: sink FlexImpl[T, H], x: sink T): FlexImpl[T, H] =
  result = v
  resetOnError(result):
    result.add(x)

proc pushBack*[T](v: sink FlexVec[T], x: sink T): FlexVec[T] {.inline.} =
  ## Returns a vector with `x` appended.
  # Keep pushBack[T] usable as a concrete proc value for FlexVec callers.
  pushBackImpl(v, x)

proc pushBack*[T](v: sink FlexImpl[T, auto], x: sink T): auto {.inline.} =
  ## Returns a vector or deque with `x` appended.
  pushBackImpl(v, x)

proc pushFront*[T; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], x: sink T
): FlexImpl[T, H] =
  ## Returns a vector with `x` prepended: O(log n) for a `FlexVec`, amortized
  ## O(1) for a `FlexDeque`.
  when hasHead(H):
    result = v
    resetOnError(result):
      result.prepend(x)
  else:
    resetOnError(result):
      result.add(x)
      result.add(v)

proc popBack*[T; H: auto = FlexNoHead](v: sink FlexImpl[T, H]): FlexImpl[T, H] =
  ## Returns a vector without its last element.
  if v.size == 0:
    raiseIndex(0, 0)
  result = v
  resetOnCopyError(T, result):
    truncate(result, result.size - 1)

proc put*[T; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], i: Natural, x: sink T
): FlexImpl[T, H] =
  ## Returns a vector with element `i` replaced by `x`.
  result = v
  resetOnError(result):
    result[i] = x

proc update*[T, F; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], i: Natural, f: F
): FlexImpl[T, H] =
  ## Returns a vector with element `i` replaced by `f(v[i])`.
  result = v
  resetOnError(result):
    let next = f(result[i])
    result[i] = next

template updateIt*[T; H: auto = FlexNoHead](
    v: FlexImpl[T, H], i: Natural, op: untyped
): FlexImpl[T, H] =
  ## Like `update`, with the new element given as an expression of `it`,
  ## the current element: `v.updateIt(2, it * 10)`.
  block:
    var updated = v
    let index = i
    resetOnError(updated):
      let it {.inject.} = ownedCopy(updated[index])
      var next: typeof(it)
      resetOnError(next):
        next = op
      updated[index] = move(next)
    updated

proc take*[T; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], n: Natural
): FlexImpl[T, H] =
  ## Returns the first `n` elements, in O(log n).
  result = v
  resetOnError(result):
    truncate(result, n)

proc drop*[T; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], n: Natural
): FlexImpl[T, H] =
  ## Returns all but the first `n` elements, in O(log n).
  result = v
  resetOnError(result):
    dropFront(result, n)

proc `[]`*[T; U, V: Ordinal, H: auto = FlexNoHead](
    v: FlexImpl[T, H], s: HSlice[U, V]
): FlexImpl[T, H] =
  ## Returns elements `s.a .. s.b` (`^i` indices allowed), in O(log n).
  let a = (when U is BackwardsIndex: v.size - int(s.a) else: int(s.a))
  let b = (when V is BackwardsIndex: v.size - int(s.b) else: int(s.b))
  if b < a:
    return
  if a < 0 or a >= v.size:
    raiseIndex(a, v.size)
  if b >= v.size:
    raiseIndex(b, v.size)
  result = v
  resetOnError(result):
    dropFront(result, a)
    truncate(result, b - a + 1)

proc insert*[T; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], i: Natural, x: sink T
): FlexImpl[T, H] =
  ## Returns a vector with `x` inserted before element `i` (`i == len`
  ## appends), in O(log n).
  result = v
  resetOnError(result):
    var value = x
    resetOnError(value):
      if i > result.size:
        raiseIndex(i, result.size + 1)
      var right = result
      resetOnError(right):
        dropFront(right, i, toHead = false)
        truncate(result, i)
        result.add(move(value))
        result.add(right)

proc erase*[T; H: auto = FlexNoHead](
    v: sink FlexImpl[T, H], i: Natural
): FlexImpl[T, H] =
  ## Returns a vector without element `i`, in O(log n).
  result = v
  resetOnError(result):
    checkFlexIndex(result, i)
    var right = result
    resetOnError(right):
      dropFront(right, i + 1, toHead = false)
      truncate(result, i)
      result.add(right)

proc toFlexVec*[T](xs: openArray[T]): FlexVec[T] =
  resetOnError(result):
    result.add(xs)

proc toFlexDeque*[T](xs: openArray[T]): FlexDeque[T] =
  resetOnError(result):
    result.add(xs)

proc toFlexDeque*[T](v: FlexVec[T]): FlexDeque[T] =
  ## The same elements as a `FlexDeque`, sharing every node, in O(1).
  if v.root != nil:
    retain(v.root)
  if v.tail != nil:
    retain(v.tail)
  result.size = v.size
  result.shift = v.shift
  result.root = v.root
  result.tail = v.tail

proc toFlexVec*[T](v: FlexDeque[T]): FlexVec[T] =
  ## The same elements as a `FlexVec`, in O(log n): the head leaf is pushed
  ## into the tree, and every other node is shared.
  var d = v
  if d.head != nil:
    absorbHead(d)
  result.size = d.size
  result.shift = d.shift
  result.root = d.root
  result.tail = d.tail
  d.root = nil
  d.tail = nil

type LeafCursor[T, H] = object
  stack: array[16, tuple[node: FlexPtr[T], next: int]]
  depth: int
  tail: FlexPtr[T]
  when H is FlexWithHead:
    root: FlexPtr[T] ## tree still to walk after the head

proc descendLeft[T, H](
    c: var LeafCursor[T, H], subtree: FlexPtr[T]
): FlexPtr[T] {.inline.} =
  var node = subtree
  while not node.leaf:
    c.stack[c.depth] = (node, 1)
    inc c.depth
    node = node.childArr[0]
  node

proc firstLeaf[T, H](
    c: var LeafCursor[T, H], v: FlexImpl[T, H]
): FlexPtr[T] {.inline.} =
  # The caller owns the vector throughout the walk.
  when hasHead(H):
    if not v.head.isNil:
      c.tail = v.tail
      c.root = v.root
      return v.head
  if v.root.isNil:
    return v.tail
  c.tail = v.tail
  c.descendLeft(v.root)

proc nextLeaf[T, H](c: var LeafCursor[T, H]): FlexPtr[T] {.inline.} =
  while c.depth > 0:
    let top = c.depth - 1
    let (parent, next) = c.stack[top]
    if next < parent.count:
      inc c.stack[top].next
      return c.descendLeft(parent.childArr[next])
    dec c.depth
  when hasHead(H):
    if not c.root.isNil:
      let root = c.root
      c.root = nil
      return c.descendLeft(root)
  result = c.tail
  c.tail = nil

iterator chunks*[T; H: auto = FlexNoHead](
    v: FlexImpl[T, H]
): (ptr UncheckedArray[T], int) =
  ## Low-level: the elements in order, as contiguous runs of up to 128 for
  ## trivially copyable one-byte elements and up to 32 otherwise. Each run
  ## is one leaf, given as a read-only pointer and a length. Retain the
  ## iterated version if a pointer is used after iteration.
  let keep = `=dup`(v)
  var c: LeafCursor[T, H]
  var leaf = c.firstLeaf(keep)
  while leaf != nil:
    yield (leaf.elemArr, leaf.count)
    leaf = c.nextLeaf()

iterator items*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): lent T =
  let keep = `=dup`(v) # iterate a snapshot even if `v` is reassigned
  var c: LeafCursor[T, H]
  var leaf = c.firstLeaf(keep)
  while leaf != nil:
    for k in 0 ..< leaf.count:
      yield leaf.elemArr[k]
    leaf = c.nextLeaf()

iterator pairs*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): (int, T) =
  var i = 0
  for x in v:
    yield (i, x)
    inc i

proc toFlexVec*[T](v: TrieVec[T]): FlexVec[T] =
  ## Copies the elements of a `TrieVec` in O(n). The two types use
  ## different node layouts, so no structure is shared.
  resetOnError(result):
    for x in v:
      appendCopy(result, x)

proc toFlexDeque*[T](v: TrieVec[T]): FlexDeque[T] =
  ## Copies the elements of a `TrieVec` in O(n).
  resetOnError(result):
    for x in v:
      appendCopy(result, x)

func sameSnapshot*[T](a: FlexImpl[T, auto], b: FlexImpl[T, auto]): bool {.inline.} =
  ## Checks in O(1) whether both values share all their nodes in the same
  ## positions. Two empty values also match. Accepts mixed `FlexVec` and
  ## `FlexDeque` operands of the same element type.
  if not (
    system.`==`(a.size, b.size) and system.`==`(a.root, b.root) and
    system.`==`(a.tail, b.tail)
  ):
    return false
  when a is FlexDeque[T] and b is FlexDeque[T]:
    result = system.`==`(a.head, b.head)
  elif a is FlexDeque[T]:
    result = a.head.isNil
  elif b is FlexDeque[T]:
    result = b.head.isNil
  else:
    result = true

template elementsEqual(a, b: untyped): bool =
  mixin `==`
  a == b

macro sameEqualityCall(actual, builtin: typed): untyped =
  # A user template can expand to a call to system.== with different operands.
  newLit(
    actual.kind in nnkCallKinds and actual.len == 3 and actual[0] == builtin[0] and
      actual[1] == builtin[1] and actual[2] == builtin[2]
  )

template usesSystemEquality(a, b: untyped): bool =
  mixin `==`
  sameEqualityCall(a == b, system.`==`(a, b))

proc `==`*[T; H, G: auto = FlexNoHead](a: FlexImpl[T, H], b: FlexImpl[T, G]): bool =
  ## Compares elements in order. A `FlexVec` and a `FlexDeque` may be compared.
  ## Elements such as NaN compare unequal even when they share a leaf.
  if not system.`==`(a.size, b.size):
    return false
  # These built-in comparisons are reflexive and do not call element code.
  # Aggregate equality can recurse into floats or a user-defined comparator.
  const canSkipShared =
    when T is (Ordinal | enum | set | string | cstring | pointer | ptr | ref) and
        T isnot distinct:
      block:
        var left, right: T
        usesSystemEquality(left, right)
    else:
      false
  when canSkipShared:
    if sameSnapshot(a, b):
      return true
  # Walk both trees leaf by leaf; their leaf boundaries may differ.
  var left: LeafCursor[T, H]
  var right: LeafCursor[T, G]
  when canSkipShared:
    var x = left.firstLeaf(a)
    var y = right.firstLeaf(b)
  else:
    # An element comparator can reassign either operand during the walk.
    let keepA = `=dup`(a)
    let keepB = `=dup`(b)
    var x = left.firstLeaf(keepA)
    var y = right.firstLeaf(keepB)
  var i, j: int
  while not x.isNil:
    let n = min(x.count - i, y.count - j)
    let xs = cast[ptr UncheckedArray[T]](addr x.elemArr[i])
    let ys = cast[ptr UncheckedArray[T]](addr y.elemArr[j])
    if not canSkipShared or not system.`==`(xs, ys):
      when canSkipShared and sizeof(T) == 1:
        if not equalMem(xs, ys, n):
          return false
      else:
        for k in 0 ..< n:
          if not elementsEqual(xs[k], ys[k]):
            return false
    i += n
    j += n
    if system.`==`(i, x.count):
      x = left.nextLeaf()
      i = 0
    if system.`==`(j, y.count):
      y = right.nextLeaf()
      j = 0
  true

proc hash*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): Hash =
  var h: Hash = 0
  for x in v:
    h = h !& hash(x)
  !$h

proc `$`*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): string =
  result = "["
  var first = true
  for x in v:
    if not first:
      result.add ", "
    first = false
    result.addQuoted x
  result.add "]"

when defined(thetosDebug):
  type FlexStats* = object ## Tree shape reported by `checkInvariants`.
    depth*: int ## levels in the tree, 0 when everything is in the tail
    nodes*: int ## tree nodes, excluding the tail
    leaves*: int
    relaxed*: int ## inner nodes indexed through a size table

  proc checkNode[T](n: FlexPtr[T], s: int, stats: var FlexStats): int =
    doAssert n != nil, "nil node"
    doAssert refCount(n) >= 1, "dead node"
    let width =
      if s == 0:
        leafWidth(T)
      else:
        flexWidth
    doAssert n.count in 1 .. width, "bad slot count " & $n.count
    inc stats.nodes
    if s == 0:
      doAssert n.leaf, "inner node at leaf level"
      inc stats.leaves
      return n.count
    doAssert not n.leaf, "leaf above leaf level"
    if n.relaxed:
      inc stats.relaxed
    for k in 0 ..< n.count:
      let size = checkNode(n.childArr[k], s - flexBits, stats)
      doAssert size <= 1 shl childShift(T, s), "child larger than its level allows"
      if n.relaxed:
        doAssert n.sizeArr[k] == result + size, "stale size table"
      elif k < n.count - 1:
        doAssert size == 1 shl childShift(T, s), "regular node with a non-full child"
      result += size

  proc checkInvariants*[T; H: auto = FlexNoHead](v: FlexImpl[T, H]): FlexStats =
    ## Verifies the tree structure and returns its shape. Raises
    ## `AssertionDefect` on a violation. Only with `-d:thetosDebug`.
    if v.size == 0:
      doAssert v.root == nil and v.tail == nil, "empty vector holds nodes"
      when hasHead(H):
        doAssert v.head == nil, "empty vector holds a head"
      return
    doAssert v.tail != nil and v.tail.leaf, "missing tail"
    doAssert v.tail.count in 1 .. leafWidth(T), "bad tail count"
    var off = v.size - v.tail.count
    when hasHead(H):
      if v.head != nil:
        doAssert v.head.leaf, "head is not a leaf"
        doAssert v.head.count in 1 .. leafWidth(T), "bad head count"
        off -= v.head.count
    if v.root == nil:
      doAssert off == 0 and v.shift == 0, "tree size without a tree"
      return
    doAssert v.shift mod flexBits == 0, "bad shift"
    if v.shift > 0:
      doAssert v.root.count >= 2, "root with a single child"
    doAssert checkNode(v.root, v.shift, result) == off, "tree size mismatch"
    result.depth = v.shift div flexBits + 1
