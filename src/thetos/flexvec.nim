## Persistent (immutable) vector with fast concatenation and slicing, after
## `immer::flex_vector`.
##
## `FlexVec[T]` is a relaxed radix balanced (RRB) tree: a 32-way trie whose
## inner nodes may carry a size table, plus a tail buffer like `TrieVec`.
## Nodes built by appends stay regular and are indexed by radix, so indexing,
## `[]=` and `add` cost about the same as on `TrieVec`. Concatenation,
## `drop`, `take`, slicing, `insert`, `erase` and `pushFront` are
## O(log n) and share structure with their inputs.
##
## Reference counts are atomic, so vectors can be passed between threads
## without locks. Uniquely owned nodes are edited in place.

runnableExamples:
  let a = toFlexVec([1, 2, 3])
  let b = a & toFlexVec([4, 5])
  assert b.len == 5 and a.len == 3
  assert b[1 .. 3] == toFlexVec([2, 3, 4])
  assert b.insert(0, 0)[0] == 0
  assert b.erase(4) == toFlexVec([1, 2, 3, 4])

import std/[atomics, hashes]
import ./private/core
import ./trievec

const
  flexBits = 5
  flexWidth = 1 shl flexBits
  extraSteps = 2 ## extra nodes a concatenation may leave per level (RRB e_max)

type
  FlexNode[T] = object
    rc*: Atomic[int] # exported for the generic refcount helpers in core
    count: int
    leaf: bool
    relaxed: bool ## inner node indexed through its size table

  FlexPtr[T] = ptr FlexNode[T]

  FlexVec*[T] = object
    ## Immutable, structurally shared vector with O(log n) concatenation
    ## and slicing.
    size: int
    shift: int ## level of `root`: 0 when `root` is a leaf
    root: FlexPtr[T] ## tree holding all but the tail, or nil
    tail: FlexPtr[T] ## leaf holding the last 1..32 elements, nil when empty

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

proc allocLeaf[T](): FlexPtr[T] =
  static:
    doAssert alignof(T) <= 16, "element alignment above 16 is unsupported"
  result = cast[FlexPtr[T]](allocRaw(
    alignUp(sizeof(FlexNode[T]), alignof(T)) + flexWidth * sizeof(T)
  ))
  result.rc.store(1, moRelaxed)
  result.leaf = true

proc allocInner[T](): FlexPtr[T] =
  result = cast[FlexPtr[T]](allocRaw(
    sizeof(FlexNode[T]) + flexWidth * (sizeof(pointer) + sizeof(int))
  ))
  result.rc.store(1, moRelaxed)

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
    result += (n.count - 1) shl s
    n = n.childArr[n.count - 1]
    s -= flexBits
  result + n.count

proc childStart[T](n: FlexPtr[T], s, j: int): int {.inline.} =
  if n.relaxed:
    (if j == 0: 0 else: n.sizeArr[j - 1])
  else:
    j shl s

proc childSize[T](n: FlexPtr[T], s, j: int): int =
  if n.relaxed:
    n.sizeArr[j] - childStart(n, s, j)
  elif j < n.count - 1:
    1 shl s
  else:
    subtreeSize(n.childArr[j], s - flexBits)

proc findChild[T](n: FlexPtr[T], s, idx: int): (int, int) {.inline.} =
  ## Child of the inner node `n` (level `s`) holding element `idx`, and the
  ## element's index inside that child.
  if n.relaxed:
    let sizes = n.sizeArr
    # Children hold at most `1 shl s` elements, so this guess is a lower bound.
    var j = idx shr s
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
    (idx shr s, idx and ((1 shl s) - 1))

proc finishInner[T](n: FlexPtr[T], s: int) =
  ## Fills the size table of a freshly built inner node and marks it regular
  ## when every child but the last is full.
  var total = 0
  var regular = true
  for k in 0 ..< n.count:
    let size = subtreeSize(n.childArr[k], s - flexBits)
    if k < n.count - 1 and size != 1 shl s:
      regular = false
    total += size
    n.sizeArr[k] = total
  n.relaxed = not regular

proc relax[T](n: FlexPtr[T], s: int) =
  finishInner(n, s)
  n.relaxed = true

proc clone[T](n: FlexPtr[T], count: int): FlexPtr[T] =
  ## Copies the first `count` slots of `n`.
  if n.leaf:
    var leaf = allocLeaf[T]()
    defer:
      release(leaf)
    let src = n.elemArr
    let dst = leaf.elemArr
    for i in 0 ..< count:
      # Count the slot first so cleanup covers a copy that fails partway.
      inc leaf.count
      dst[i] = src[i]
    return move(leaf)
  result = allocInner[T]()
  let src = n.childArr
  let dst = result.childArr
  for i in 0 ..< count:
    dst[i] = src[i]
    retain(src[i])
    result.sizeArr[i] = n.sizeArr[i]
  result.count = count
  result.relaxed = n.relaxed

proc ensureOwned[T](slot: var FlexPtr[T]) =
  if not isUnique(slot):
    let c = clone(slot, slot.count)
    release(slot)
    slot = c

proc `=destroy`*[T](v: FlexVec[T]) =
  release(v.root)
  release(v.tail)

proc `=wasMoved`*[T](v: var FlexVec[T]) =
  v.size = 0
  v.shift = 0
  v.root = nil
  v.tail = nil

proc `=dup`*[T](v: FlexVec[T]): FlexVec[T] =
  if v.root != nil:
    retain(v.root)
  if v.tail != nil:
    retain(v.tail)
  result.size = v.size
  result.shift = v.shift
  result.root = v.root
  result.tail = v.tail

proc `=copy`*[T](dst: var FlexVec[T], src: FlexVec[T]) =
  if src.root != nil:
    retain(src.root)
  if src.tail != nil:
    retain(src.tail)
  `=destroy`(dst)
  dst.size = src.size
  dst.shift = src.shift
  dst.root = src.root
  dst.tail = src.tail

proc initFlexVec*[T](): FlexVec[T] =
  ## Returns an empty vector. `default(FlexVec[T])` is also empty.
  discard

proc len*[T](v: FlexVec[T]): int {.inline.} =
  v.size

proc high*[T](v: FlexVec[T]): int {.inline.} =
  v.size - 1

proc low*[T](v: FlexVec[T]): int {.inline.} =
  0

template treeSize[T](v: FlexVec[T]): int =
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

proc raiseIndex(i, size: int) {.noinline, noreturn.} =
  raise newException(IndexDefect, "index " & $i & " not in 0 .. " & $(size - 1))

template checkIndex(v, i: untyped) =
  if i < 0 or i >= v.size:
    raiseIndex(i, v.size)

proc `[]`*[T](v: FlexVec[T], i: Natural): lent T =
  checkIndex(v, i)
  let off = v.treeSize
  if i >= off:
    return v.tail.elemArr[i - off]
  var n = v.root
  var s = v.shift
  var idx = int(i)
  while s > 0:
    let (j, local) = findChild(n, s, idx)
    idx = local
    n = n.childArr[j]
    s -= flexBits
  n.elemArr[idx]

proc `[]`*[T](v: FlexVec[T], i: BackwardsIndex): lent T =
  v[v.size - int(i)]

proc first*[T](v: FlexVec[T]): lent T =
  v[0]

proc last*[T](v: FlexVec[T]): lent T =
  v[v.size - 1]

proc newPath[T](level: int, node: FlexPtr[T]): FlexPtr[T] =
  if level == 0:
    return node
  result = allocInner[T]()
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
    if not n.relaxed and childSize(n, s, last) != 1 shl s:
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
    let top = allocInner[T]()
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

proc add*[T](v: var FlexVec[T], x: sink T) =
  ## Appends `x` to this vector value only; other copies are not affected.
  # Keep the incoming value owned locally while a shared leaf is copied.
  var value = x
  defer:
    reset(value)
  if v.tail == nil:
    v.tail = allocLeaf[T]()
  elif v.tail.count < flexWidth:
    ensureOwned(v.tail)
  else:
    pushLeaf(v.root, v.shift, v.tail)
    v.tail = nil
    v.tail = allocLeaf[T]()
  v.tail.elemArr[v.tail.count] = move(value)
  inc v.tail.count
  inc v.size

proc add*[T](v: var FlexVec[T], xs: openArray[T]) =
  for x in xs:
    appendCopy(v, x)

proc assocRec[T](slot: var FlexPtr[T], s, idx: int, value: var T) =
  ensureOwned(slot)
  if s == 0:
    slot.elemArr[idx] = move(value)
  else:
    let (j, local) = findChild(slot, s, idx)
    assocRec(slot.childArr[j], s - flexBits, local, value)

proc `[]=`*[T](v: var FlexVec[T], i: Natural, x: sink T) =
  ## Replaces element `i` in this vector value only.
  var value = x
  defer:
    reset(value)
  checkIndex(v, i)
  let off = v.treeSize
  if i >= off:
    ensureOwned(v.tail)
    v.tail.elemArr[i - off] = move(value)
  else:
    assocRec(v.root, v.shift, i, value)

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

proc truncate[T](v: var FlexVec[T], n: int) =
  ## Keeps the first `n` elements.
  if n >= v.size:
    return
  if n <= 0:
    `=destroy`(v)
    `=wasMoved`(v)
    return
  let off = v.treeSize
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
    # The leaf holding the new last element becomes the tail.
    let (leaf, start) = leafAt(v.root, v.shift, n - 1)
    var newTail: FlexPtr[T]
    if n - start == leaf.count:
      retain(leaf)
      newTail = leaf
    else:
      newTail = clone(leaf, n - start)
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
    var leaf = allocLeaf[T]()
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
  result = allocInner[T]()
  result.childArr[0] = first
  for k in j + 1 ..< node.count:
    result.childArr[k - j] = node.childArr[k]
    retain(node.childArr[k])
  result.count = node.count - j
  finishInner(result, s)

proc dropFront[T](v: var FlexVec[T], n: int) =
  ## Removes the first `n` elements.
  if n <= 0:
    return
  if n >= v.size:
    `=destroy`(v)
    `=wasMoved`(v)
    return
  let off = v.treeSize
  if n >= off:
    let newTail =
      (if n == off: (retain(v.tail); v.tail) else: treeDrop(v.tail, 0, n - off))
    release(v.root)
    v.root = nil
    v.shift = 0
    release(v.tail)
    v.tail = newTail
  else:
    var root = treeDrop(v.root, v.shift, n)
    var shift = v.shift
    normalize(root, shift)
    release(v.root)
    v.root = root
    v.shift = shift
  v.size -= n

# Concatenation ----------------------------------------------------------
#
# Follows the RRB concatenation of Bagwell and Rompf with the rebalancing
# plan of L'orange's thesis, as in immer's `rbts/operations.hpp`: the right
# edge of the left tree and the left edge of the right tree are merged level
# by level, redistributing slots only when a level would otherwise exceed
# the optimal node count by more than `extraSteps`.

proc executePlan[T](all: seq[FlexPtr[T]], level: int): seq[FlexPtr[T]] =
  ## Redistributes the slots of the nodes in `all` (borrowed, at `level`)
  ## into new owned nodes, reusing nodes that need no change.
  var plan = newSeq[int](all.len)
  var total = 0
  for i, n in all:
    plan[i] = n.count
    total += n.count
  var n = all.len
  let optimal = (total + flexWidth - 1) div flexWidth
  var i = 0
  while n > optimal + extraSteps:
    while i + 1 < n and plan[i] > flexWidth - extraSteps div 2:
      inc i
    if i + 1 >= n:
      break
    var remaining = plan[i]
    while remaining > 0:
      let size = min(remaining + plan[i + 1], flexWidth)
      plan[i] = size
      remaining = remaining + plan[i + 1] - size
      inc i
    for j in i ..< n - 1:
      plan[j] = plan[j + 1]
    dec n
    dec i
  plan.setLen(n)

  var nodes: seq[FlexPtr[T]]
  defer:
    for node in nodes:
      release(node)
  var idx = 0
  var offset = 0
  for target in plan:
    if offset == 0 and all[idx].count == target:
      retain(all[idx])
      nodes.add all[idx]
      inc idx
      continue
    let node = (if level == 0: allocLeaf[T]() else: allocInner[T]())
    nodes.add node
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
    if level > 0:
      finishInner(node, level)
  result = move(nodes)

proc rebalance[T](left, center, right: FlexPtr[T], s: int): FlexPtr[T] =
  ## Merges the children of `left` (all but its last), of `center` (owned,
  ## at level `s`) and of `right` (all but its first) into a new node at
  ## level `s + flexBits` holding one or two nodes at level `s`.
  defer:
    release(center)
  var all: seq[FlexPtr[T]]
  if left != nil:
    for k in 0 ..< left.count - 1:
      all.add left.childArr[k]
  for k in 0 ..< center.count:
    all.add center.childArr[k]
  if right != nil:
    for k in 1 ..< right.count:
      all.add right.childArr[k]
  let nodes = executePlan(all, s - flexBits)
  result = allocInner[T]()
  var k = 0
  while k < nodes.len:
    let n = allocInner[T]()
    while k < nodes.len and n.count < flexWidth:
      n.childArr[n.count] = nodes[k]
      inc n.count
      inc k
    finishInner(n, s)
    result.childArr[result.count] = n
    inc result.count
  finishInner(result, s + flexBits)

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
    if left.count + right.count <= flexWidth:
      merged = clone(left, left.count)
      defer:
        release(merged)
      for k in 0 ..< right.count:
        inc merged.count
        merged.elemArr[merged.count - 1] = right.elemArr[k]
      result = allocInner[T]()
      result.childArr[0] = move(merged)
      result.count = 1
    else:
      result = allocInner[T]()
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

proc add*[T](v: var FlexVec[T], w: FlexVec[T]) =
  ## Appends every element of `w` to this vector value only, in O(log n).
  if w.size == 0:
    return
  if v.size == 0:
    v = w
    return
  let keep = `=dup`(w) # `w` may alias `v`
  if keep.root == nil:
    # Few elements: append them through a copy so a failing element copy
    # leaves `v` unchanged.
    var res = v
    for k in 0 ..< keep.tail.count:
      appendCopy(res, keep.tail.elemArr[k])
    v = move(res)
    return
  # Build the left tree (`v` with its tail pushed in) without touching `v`.
  var left: FlexVec[T]
  left.root = v.root
  left.shift = v.shift
  if left.root != nil:
    retain(left.root)
  retain(v.tail)
  pushLeaf(left.root, left.shift, v.tail)
  let (root, shift) = concatTrees(left.root, left.shift, keep.root, keep.shift)
  release(v.root)
  release(v.tail)
  v.root = root
  v.shift = shift
  retain(keep.tail)
  v.tail = keep.tail
  v.size += keep.size

proc `&`*[T](a: sink FlexVec[T], b: FlexVec[T]): FlexVec[T] =
  ## Concatenation in O(log n).
  result = a
  resetOnError(result):
    result.add(b)

proc pop*[T](v: var FlexVec[T]): T =
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

proc pushBack*[T](v: sink FlexVec[T], x: sink T): FlexVec[T] =
  ## Returns a vector with `x` appended.
  result = v
  resetOnCopyError(T, result):
    result.add(x)

proc pushFront*[T](v: sink FlexVec[T], x: sink T): FlexVec[T] =
  ## Returns a vector with `x` prepended, in O(log n).
  resetOnError(result):
    result.add(x)
    result.add(v)

proc popBack*[T](v: sink FlexVec[T]): FlexVec[T] =
  ## Returns a vector without its last element.
  if v.size == 0:
    raiseIndex(0, 0)
  result = v
  resetOnCopyError(T, result):
    truncate(result, result.size - 1)

proc put*[T](v: sink FlexVec[T], i: Natural, x: sink T): FlexVec[T] =
  ## Returns a vector with element `i` replaced by `x`.
  result = v
  resetOnError(result):
    result[i] = x

proc update*[T, F](v: sink FlexVec[T], i: Natural, f: F): FlexVec[T] =
  ## Returns a vector with element `i` replaced by `f(v[i])`.
  result = v
  resetOnError(result):
    let next = f(result[i])
    result[i] = next

proc take*[T](v: sink FlexVec[T], n: Natural): FlexVec[T] =
  ## Returns the first `n` elements, in O(log n).
  result = v
  resetOnError(result):
    truncate(result, n)

proc drop*[T](v: sink FlexVec[T], n: Natural): FlexVec[T] =
  ## Returns all but the first `n` elements, in O(log n).
  result = v
  resetOnError(result):
    dropFront(result, n)

proc `[]`*[T; U, V: Ordinal](v: FlexVec[T], s: HSlice[U, V]): FlexVec[T] =
  ## Returns elements `s.a .. s.b` (`^i` indices allowed), in O(log n).
  let a = (when U is BackwardsIndex: v.size - int(s.a) else: int(s.a))
  let b = (when V is BackwardsIndex: v.size - int(s.b) else: int(s.b))
  let count = b - a + 1
  if count <= 0:
    return
  if a < 0 or a >= v.size:
    raiseIndex(a, v.size)
  if b >= v.size:
    raiseIndex(b, v.size)
  result = v
  resetOnError(result):
    dropFront(result, a)
    truncate(result, count)

proc insert*[T](v: sink FlexVec[T], i: Natural, x: sink T): FlexVec[T] =
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
        dropFront(right, i)
        truncate(result, i)
        result.add(move(value))
        result.add(right)

proc erase*[T](v: sink FlexVec[T], i: Natural): FlexVec[T] =
  ## Returns a vector without element `i`, in O(log n).
  result = v
  resetOnError(result):
    checkIndex(result, i)
    var right = result
    resetOnError(right):
      dropFront(right, i + 1)
      truncate(result, i)
      result.add(right)

proc toFlexVec*[T](xs: openArray[T]): FlexVec[T] =
  resetOnError(result):
    result.add(xs)

iterator items*[T](v: FlexVec[T]): lent T =
  let keep = `=dup`(v) # iterate a snapshot even if `v` is reassigned
  if keep.size > 0:
    let off = keep.treeSize
    var i = 0
    while i < off:
      let (leaf, start) = leafAt(keep.root, keep.shift, i)
      for k in 0 ..< leaf.count:
        yield leaf.elemArr[k]
      i = start + leaf.count
    for k in 0 ..< keep.tail.count:
      yield keep.tail.elemArr[k]

iterator pairs*[T](v: FlexVec[T]): (int, T) =
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

proc `==`*[T](a, b: FlexVec[T]): bool =
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

proc hash*[T](v: FlexVec[T]): Hash =
  var h: Hash = 0
  for x in v:
    h = h !& hash(x)
  !$h

proc `$`*[T](v: FlexVec[T]): string =
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
    doAssert n.rc.load(moRelaxed) >= 1, "dead node"
    doAssert n.count in 1 .. flexWidth, "bad slot count " & $n.count
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
      doAssert size <= 1 shl s, "child larger than its level allows"
      if n.relaxed:
        doAssert n.sizeArr[k] == result + size, "stale size table"
      elif k < n.count - 1:
        doAssert size == 1 shl s, "regular node with a non-full child"
      result += size

  proc checkInvariants*[T](v: FlexVec[T]): FlexStats =
    ## Verifies the tree structure and returns its shape. Raises
    ## `AssertionDefect` on a violation. Only with `-d:thetosDebug`.
    if v.size == 0:
      doAssert v.root == nil and v.tail == nil, "empty vector holds nodes"
      return
    doAssert v.tail != nil and v.tail.leaf, "missing tail"
    doAssert v.tail.count in 1 .. flexWidth, "bad tail count"
    let off = v.size - v.tail.count
    if v.root == nil:
      doAssert off == 0 and v.shift == 0, "tree size without a tree"
      return
    doAssert v.shift mod flexBits == 0, "bad shift"
    if v.shift > 0:
      doAssert v.root.count >= 2, "root with a single child"
    doAssert checkNode(v.root, v.shift, result) == off, "tree size mismatch"
    result.depth = v.shift div flexBits + 1
