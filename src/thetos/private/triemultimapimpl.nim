# Included by thetos/triemultimap and thetos/local with their respective RRB nodes.
include ./multileafimpl

type
  MultiTree[K, V] = object
    entries: FlexVec[MultiEntry[K, V]]
    distinctKeys: int

  TrieMultiMap*[K, V] = object
    ## Persistent multimap. Values for each key retain their insertion order.
    small: MultiLeaf[K, V]
    tree: Box[MultiTree[K, V]]

proc initTrieMultiMap*[K, V](): TrieMultiMap[K, V] =
  ## Returns an empty multimap. The default value is also empty.
  discard

proc len*[K, V](m: TrieMultiMap[K, V]): int {.inline.} =
  ## Total number of key/value associations, including repetitions.
  if m.small.node != nil:
    int(m.small.node.count)
  elif m.tree.isEmpty:
    0
  else:
    m.tree[].entries.len

proc keyCount*[K, V](m: TrieMultiMap[K, V]): int {.inline.} =
  ## Number of distinct keys.
  if m.small.node != nil:
    int(m.small.node.keyCount)
  elif m.tree.isEmpty:
    0
  else:
    m.tree[].distinctKeys

proc treeRun[K, V](entries: FlexVec[MultiEntry[K, V]], key: K, code: uint64): MultiRun =
  # Equal hashes can belong to distinct keys. Skip a whole run at a time,
  # including runs that span many leaves. A miss gives the insertion position.
  var first = entries.nextKeyStart(0, code)
  while first < entries.len and entries[first].head[].code == code:
    let past = entries.nextKeyStart(first + 1, code)
    if entries[first].head[].key == key:
      return (first, past, 0)
    first = past
  (first, first, 0)

proc readRun[K, V](m: TrieMultiMap[K, V], key: K): MultiRun {.inline.} =
  if m.small.node != nil:
    m.small.node.readLeafRun(key)
  elif not m.tree.isEmpty:
    m.tree[].entries.treeRun(key, keyHash(key))
  else:
    (0, 0, 0)

proc count*[K, V](m: TrieMultiMap[K, V], key: K): int =
  ## Number of values associated with `key`.
  let run = m.readRun(key)
  run.past - run.first

proc contains*[K, V](m: TrieMultiMap[K, V], key: K): bool {.inline.} =
  m.count(key) != 0

proc hasKey*[K, V](m: TrieMultiMap[K, V], key: K): bool {.inline.} =
  key in m

iterator runValues[K, V](m: TrieMultiMap[K, V], run: MultiRun): lent V =
  if run.first < run.past:
    if m.small.node != nil:
      let keep = `=dup`(m.small)
      let values = keep.node.valueArray
      for i in run.first ..< run.past:
        yield values[i]
    else:
      for e in m.tree[].entries.entriesBetween(run.first, run.past):
        yield e.value

iterator values*[K, V](m: TrieMultiMap[K, V], key: K): lent V =
  ## Yields values for `key` in insertion order. A missing key yields nothing.
  let run = m.readRun(key)
  for v in m.runValues(run):
    yield v

proc `[]`*[K, V](m: TrieMultiMap[K, V], key: K): seq[V] =
  ## Copies the values for `key` into a sequence. Raises `KeyError` on a miss.
  let run = m.readRun(key)
  if run.first == run.past:
    raiseKeyError(key)
  result = newSeqOfCap[V](run.past - run.first)
  resetOnError(result):
    for v in m.runValues(run):
      result.add(ownedCopy(v))

proc promoteLeaf[K, V](
    m: var TrieMultiMap[K, V], pos, keyCount: int, entry: var MultiEntry[K, V]
) =
  # Stage the tree so a raising value copy leaves the packed leaf intact.
  var tree: FlexVec[MultiEntry[K, V]]
  resetOnError(tree):
    let n = m.small.node
    var rank = 0
    for i in 0 ..< int(n.count):
      if i == pos:
        tree.add(move(entry))
      var e: MultiEntry[K, V]
      resetOnError(e):
        e.value = n.valueArray[i]
        if (n.starts and (1'u32 shl i)) != 0:
          e.head = n.headArray[rank]
          inc rank
        tree.add(move(e))
    if pos == int(n.count):
      tree.add(move(entry))
    m.tree = box(MultiTree[K, V](entries: move(tree), distinctKeys: keyCount))
    reset(m.small)

proc add*[K, V](m: var TrieMultiMap[K, V], key: K, value: sink V) =
  ## Appends one value, even when the same association already exists.
  var entry = MultiEntry[K, V](value: value)
  defer:
    reset(entry)
  let code = keyHash(key)
  let n = m.small.node
  var run: MultiRun
  if n != nil:
    run = n.hashedLeafRun(key, code)
  elif not m.tree.isEmpty:
    run = m.tree[].entries.treeRun(key, code)
  let newKey = run.first == run.past
  if newKey:
    var header = MultiKey[K](code: code)
    resetOnError(header):
      header.key = key
    entry.head = box(header)
  if m.tree.isEmpty:
    if n == nil or int(n.count) < multiLeafWidth:
      m.small.insertSlot(run, entry)
    else:
      m.promoteLeaf(run.past, int(n.keyCount) + ord(newKey), entry)
  else:
    let t = addr writableBox(m.tree)
    if run.past == t.entries.len:
      t.entries.add(move(entry))
    else:
      t.entries = insert(`=dup`(t.entries), run.past, move(entry))
    if newKey:
      inc t.distinctKeys

proc insert*[K, V](
    m: sink TrieMultiMap[K, V], key: K, value: sink V
): TrieMultiMap[K, V] =
  ## Returns a multimap with one more association.
  result = m
  resetOnError(result):
    result.add(key, value)

proc toTrieMultiMap*[K, V](pairs: openArray[(K, V)]): TrieMultiMap[K, V] =
  ## Builds a multimap from pairs, retaining repeated keys and values.
  resetOnError(result):
    for pair in pairs:
      result.add(pair[0], ownedCopy(pair[1]))

proc appendPacked[K, V](n: MultiLeafPtr[K, V], head: Box[MultiKey[K]], value: V) =
  if not head.isEmpty:
    n.headArray[int(n.keyCount)] = head
    inc n.keyCount
    n.starts = n.starts or (1'u32 shl int(n.count))
  n.valueArray[int(n.count)] = ownedCopy(value)
  inc n.count

proc deleteRange[K, V](m: var TrieMultiMap[K, V], run: MultiRun, first, past: int) =
  let dropKey = past - first == run.past - run.first
  let promote = not dropKey and first == run.first
  let remaining = m.len - (past - first)
  if m.small.node != nil:
    m.small.removeSlots(run, first, past)
  elif remaining == 0:
    reset(m.tree)
  elif remaining <= multiLeafWidth div 2:
    # A lower return threshold avoids converting back and forth at 32/33.
    var fresh = newMultiLeaf[K, V](remaining, m.keyCount - ord(dropKey))
    resetOnError(fresh):
      for e in m.tree[].entries.entriesBetween(0, first):
        fresh.node.appendPacked(e.head, e.value)
      var after = past
      if promote:
        fresh.node.appendPacked(
          m.tree[].entries[first].head, m.tree[].entries[past].value
        )
        inc after
      for e in m.tree[].entries.entriesBetween(after, m.tree[].entries.len):
        fresh.node.appendPacked(e.head, e.value)
      m.small = move(fresh)
      reset(m.tree)
  else:
    var left = m.tree[].entries.take(first)
    resetOnError(left):
      var after = past
      if promote:
        var entry = MultiEntry[K, V](head: m.tree[].entries[first].head)
        resetOnError(entry):
          entry.value = m.tree[].entries[past].value
          left.add(move(entry))
        inc after
      let right = m.tree[].entries.drop(after)
      left.add(right)
      let t = addr writableBox(m.tree)
      t.entries = move(left)
      if dropKey:
        dec t.distinctKeys

proc del*[K, V](m: var TrieMultiMap[K, V], key: K) =
  ## Removes every value for `key`. A missing key is a no-op.
  let run = m.readRun(key)
  if run.first < run.past:
    m.deleteRange(run, run.first, run.past)

proc del*[K, V](m: var TrieMultiMap[K, V], key: K, value: V) =
  ## Removes the first equal value for `key`, if present.
  let run = m.readRun(key)
  var i = run.first
  for v in m.runValues(run):
    if v == value:
      break
    inc i
  if i < run.past:
    m.deleteRange(run, i, i + 1)

proc erase*[K, V](m: sink TrieMultiMap[K, V], key: K): TrieMultiMap[K, V] =
  ## Returns a multimap without `key`.
  result = m
  resetOnError(result):
    result.del(key)

proc erase*[K, V](m: sink TrieMultiMap[K, V], key: K, value: V): TrieMultiMap[K, V] =
  ## Returns a multimap with the first matching association removed.
  result = m
  resetOnError(result):
    result.del(key, value)

iterator multiSlots[K, V](
    m: TrieMultiMap[K, V]
): tuple[head: ptr MultiKey[K], value: ptr V] =
  # Both pointers borrow from the single snapshot held throughout this walk.
  if m.small.node != nil:
    let keep = `=dup`(m.small)
    let n = keep.node
    var rank = 0
    for i in 0 ..< int(n.count):
      var head: ptr MultiKey[K]
      if (n.starts and (1'u32 shl i)) != 0:
        head = addr n.headArray[rank][]
        inc rank
      yield (head, addr n.valueArray[i])
  elif not m.tree.isEmpty:
    for e in m.tree[].entries.items:
      let head =
        if e.head.isEmpty:
          nil
        else:
          addr e.head[]
      yield (head, addr e.value)

iterator keys*[K, V](m: TrieMultiMap[K, V]): lent K =
  ## Yields each distinct key once, in unspecified order.
  for head, value in m.multiSlots:
    if head != nil:
      yield head.key

iterator values*[K, V](m: TrieMultiMap[K, V]): lent V =
  ## Yields all values, grouped by key.
  for head, value in m.multiSlots:
    yield value[]

iterator pairs*[K, V](m: TrieMultiMap[K, V]): (K, V) =
  ## Yields each association, including duplicates.
  var current: ptr MultiKey[K]
  for head, value in m.multiSlots:
    if head != nil:
      current = head
    yield (current.key, value[])

proc `==`*[K, V](a, b: TrieMultiMap[K, V]): bool =
  ## Equal maps have the same ordered values for every key.
  if a.len != b.len or a.keyCount != b.keyCount:
    return false
  let right = `=dup`(b) # a user comparator can reassign either input
  var next, past: int
  for head, value in a.multiSlots:
    if head != nil:
      if next != past:
        return false
      let run =
        if right.small.node != nil:
          right.small.node.readLeafRun(head.key)
        else:
          right.tree[].entries.treeRun(head.key, head.code)
      next = run.first
      past = run.past
    if next == past:
      return false
    if right.small.node != nil:
      if value[] != right.small.node.valueArray[next]:
        return false
    elif value[] != right.tree[].entries[next].value:
      return false
    inc next
  next == past

proc hash*[K, V](m: TrieMultiMap[K, V]): Hash =
  ## Combines ordered values within each key and distinct keys in any order.
  mixin hash
  var total: uint
  var run: Hash
  for head, value in m.multiSlots:
    if head != nil:
      total += cast[uint](!$run)
      run = hash(head.key)
    run = run !& hash(value[])
  cast[Hash](total + cast[uint](!$run))
