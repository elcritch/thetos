# Packed root leaf for small multimaps. The allocation contains a header,
# one boxed-key handle per distinct key, then a contiguous array of values.
const multiLeafWidth = 32

type
  MultiLeafNode[K, V] = object
    rc*: RcCount
    starts: uint32 # bit i marks the first value of a run
    count, keyCount, capacity, keyCapacity: uint8

  MultiLeafPtr[K, V] = ptr MultiLeafNode[K, V]
  MultiLeaf[K, V] = object
    node: MultiLeafPtr[K, V]

  MultiRun = tuple[first, past, rank: int]

template headArray[K, V](n: MultiLeafPtr[K, V]): ptr UncheckedArray[Box[MultiKey[K]]] =
  cast[ptr UncheckedArray[Box[MultiKey[K]]]](cast[uint](n) +
    uint(sizeof(MultiLeafNode[K, V])))

template valueOffset(K, V: typedesc, keys: int): int =
  alignUp(sizeof(MultiLeafNode[K, V]) + keys * sizeof(Box[MultiKey[K]]), alignof(V))

template valueArray[K, V](n: MultiLeafPtr[K, V]): ptr UncheckedArray[V] =
  cast[ptr UncheckedArray[V]](cast[uint](n) + uint(
    valueOffset(K, V, int(n.keyCapacity))
  ))

proc `=destroy`[K, V](leaf: MultiLeaf[K, V]) =
  let n = leaf.node
  if n != nil and dropRef(n):
    {.cast(raises: []), cast(gcsafe).}:
      for i in 0 ..< int(n.count):
        `=destroy`(n.valueArray[i])
      for i in 0 ..< int(n.keyCount):
        `=destroy`(n.headArray[i])
    freeAlignedRaw(n, max(alignof(MultiLeafNode[K, V]), alignof(V)))

proc `=wasMoved`[K, V](leaf: var MultiLeaf[K, V]) =
  leaf.node = nil

proc `=dup`[K, V](leaf: MultiLeaf[K, V]): MultiLeaf[K, V] =
  if leaf.node != nil:
    retain(leaf.node)
  result.node = leaf.node

proc `=copy`[K, V](dst: var MultiLeaf[K, V], src: MultiLeaf[K, V]) =
  if src.node != nil:
    retain(src.node)
  `=destroy`(dst)
  dst.node = src.node

proc leafCapacity(needed: int): int {.inline.} =
  result = 1
  while result < needed:
    result = result shl 1

proc newMultiLeaf[K, V](values, keys: int): MultiLeaf[K, V] =
  let
    capacity = leafCapacity(values)
    keyCapacity = leafCapacity(keys)
    size = valueOffset(K, V, keyCapacity) + capacity * sizeof(V)
  let n = cast[MultiLeafPtr[K, V]](allocAlignedRaw(
    size, max(alignof(MultiLeafNode[K, V]), alignof(V))
  ))
  initRc(n)
  n.capacity = uint8(capacity)
  n.keyCapacity = uint8(keyCapacity)
  result.node = n

proc rebuildLeaf[K, V](
    leaf: var MultiLeaf[K, V],
    values, keys: int,
    starts: uint32,
    skipFirst = 0,
    skipPast = 0,
    skipKey = -1,
) =
  # Move a unique leaf or copy the surviving slots of a shared snapshot.
  let old = leaf.node
  var fresh = newMultiLeaf[K, V](values, keys)
  resetOnError(fresh):
    let n = fresh.node
    n.starts = starts
    if old != nil:
      let unique = isUnique(old)
      for i in 0 ..< int(old.keyCount):
        if i != skipKey:
          n.headArray[int(n.keyCount)] = old.headArray[i]
          inc n.keyCount
      for i in 0 ..< int(old.count):
        if i >= skipFirst and i < skipPast:
          continue
        let dest = int(n.count)
        if unique:
          n.valueArray[dest] = move(old.valueArray[i])
        else:
          n.valueArray[dest] = ownedCopy(old.valueArray[i])
        inc n.count
    leaf = move(fresh)

proc runAt[K, V](n: MultiLeafPtr[K, V], rank: int): MultiRun {.inline.} =
  let count = int(n.count)
  if rank == int(n.keyCount):
    return (count, count, rank)
  if n.count == n.keyCount: # one value for every key
    return (rank, rank + 1, rank)
  var starts = n.starts
  for i in 0 ..< rank:
    starts = starts and (starts - 1)
  let first = countTrailingZeroBits(starts)
  starts = starts and (starts - 1)
  let past =
    if starts == 0:
      count
    else:
      countTrailingZeroBits(starts)
  (first, past, rank)

proc hashedLeafRun[K, V](n: MultiLeafPtr[K, V], key: K, code: uint64): MultiRun =
  # A miss returns the position after the existing runs with the same hash.
  var lo = 0
  var hi = int(n.keyCount)
  let heads = n.headArray
  while lo < hi:
    let mid = (lo + hi) shr 1
    if heads[mid][].code < code:
      lo = mid + 1
    else:
      hi = mid
  while lo < int(n.keyCount) and heads[lo][].code == code:
    if heads[lo][].key == key:
      return n.runAt(lo)
    inc lo
  let first = n.runAt(lo).first
  (first, first, lo)

proc readLeafRun[K, V](n: MultiLeafPtr[K, V], key: K): MultiRun {.inline.} =
  if n.keyCount == 1:
    if n.headArray[0][].key == key:
      return (0, int(n.count), 0)
  elif n.keyCount <= 4:
    for rank in 0 ..< int(n.keyCount):
      if n.headArray[rank][].key == key:
        return n.runAt(rank)
  else:
    return n.hashedLeafRun(key, keyHash(key))
  (0, 0, 0)

proc insertSlot[K, V](
    leaf: var MultiLeaf[K, V], run: MultiRun, entry: var MultiEntry[K, V]
) =
  let old = leaf.node
  let size =
    if old == nil:
      0
    else:
      int(old.count)
  let keys =
    if old == nil:
      0
    else:
      int(old.keyCount)
  let newKey = not entry.head.isEmpty
  let neededKeys = keys + ord(newKey)
  if old == nil:
    leaf = newMultiLeaf[K, V](1, 1)
  elif size == int(old.capacity) or neededKeys > int(old.keyCapacity) or
      not isUnique(old):
    leaf.rebuildLeaf(size + 1, neededKeys, old.starts)
  let n = leaf.node
  if newKey:
    for i in countdown(keys - 1, run.rank):
      n.headArray[i + 1] = move(n.headArray[i])
    n.headArray[run.rank] = move(entry.head)
    inc n.keyCount
  let pos = run.past
  for i in countdown(size - 1, pos):
    n.valueArray[i + 1] = move(n.valueArray[i])
  n.valueArray[pos] = move(entry.value)
  let low = (1'u32 shl pos) - 1
  n.starts =
    (n.starts and low) or ((n.starts and not low) shl 1) or (uint32(newKey) shl pos)
  inc n.count

proc removeSlots[K, V](leaf: var MultiLeaf[K, V], run: MultiRun, first, past: int) =
  let size = int(leaf.node.count)
  let removed = past - first
  if removed == size:
    reset(leaf)
    return
  let n = leaf.node
  let keys = int(n.keyCount)
  let dropKey = removed == run.past - run.first
  # Widen so past == 32 also shifts the high part completely out.
  let low = (1'u64 shl first) - 1
  var starts =
    uint32((uint64(n.starts) and low) or ((uint64(n.starts) shr past) shl first))
  if not dropKey and first == run.first:
    starts = starts or (1'u32 shl first)
  let valuesLeft = size - removed
  let keysLeft = keys - ord(dropKey)
  if not isUnique(n) or valuesLeft * 4 <= int(n.capacity) or
      keysLeft * 4 <= int(n.keyCapacity):
    let skipKey = if dropKey: run.rank else: -1
    leaf.rebuildLeaf(valuesLeft, keysLeft, starts, first, past, skipKey)
    return
  if dropKey:
    for i in run.rank + 1 ..< keys:
      n.headArray[i - 1] = move(n.headArray[i])
    reset(n.headArray[keys - 1])
    dec n.keyCount
  for i in past ..< size:
    n.valueArray[i - removed] = move(n.valueArray[i])
  for i in size - removed ..< size:
    reset(n.valueArray[i])
  n.count = uint8(valuesLeft)
  n.starts = starts
