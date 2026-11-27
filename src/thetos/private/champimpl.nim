## CHAMP (Compressed Hash-Array Mapped Prefix-tree) core shared by `TrieMap` and
## `TrieSet`. Included, not imported: see the note below.
##
## Each node is one shared-heap block laid out as:
##
## .. code-block::
##   header | children: array[nchildren, ptr node] | entries: array[nentries, E]
##
## `datamap` marks hash fragments stored inline as entries, `nodemap` marks
## fragments that continue in a child node. Below the last hash level
## (shift >= 64) nodes are collision nodes: unordered entry lists.
##
## Entries `E` must have a `key` field. All mutation goes through a `slot`
## (a `var` reference owned by the caller). A slot whose node is uniquely
## owned is edited in place; a shared node is path-copied first. This makes
## transient-style batch updates free while keeping every shared snapshot
## immutable, and is safe across threads because a refcount of 1 proves no
## other owner exists.

# Included by the container modules and by `thetos/local`; not a module.
# The including module imports `std/[bitops, hashes, options]` and
# `private/core`, and declares `RcCount`, the type of each node's `rc`.

const
  champBits = 5
  champMask = 31'u64
  hashBits = 64
  maxChampDepth = hashBits div champBits + 2

type
  ChampNode[E] = object
    rc*: RcCount # exported for the generic refcount helpers in core
    datamap: uint32
    nodemap: uint32
    nentries: uint32
    nchildren: uint32

  ChampPtr[E] = ptr ChampNode[E]

template entryOffset(E: typedesc, nchildren: int): int =
  alignUp(sizeof(ChampNode[E]) + nchildren * sizeof(pointer), alignof(E))

template childArr[E](n: ChampPtr[E]): ptr UncheckedArray[ChampPtr[E]] =
  cast[ptr UncheckedArray[ChampPtr[E]]](cast[uint](n) + uint(sizeof(ChampNode[E])))

template entryArr[E](n: ChampPtr[E]): ptr UncheckedArray[E] =
  cast[ptr UncheckedArray[E]](cast[uint](n) + uint(entryOffset(E, int(n.nchildren))))

template fragment(h: uint64, shift: int): uint32 =
  uint32((h shr shift) and champMask)

template bitpos(h: uint64, shift: int): uint32 =
  1'u32 shl fragment(h, shift)

template index(map, bit: uint32): int =
  countSetBits(map and (bit - 1))

proc allocChamp[E](nentries, nchildren: int): ChampPtr[E] =
  static:
    doAssert alignof(E) <= 16, "entry alignment above 16 is unsupported"
  let size = entryOffset(E, nchildren) + nentries * sizeof(E)
  result = cast[ChampPtr[E]](allocRaw(size))
  initRc(result)
  result.nentries = uint32(nentries)
  result.nchildren = uint32(nchildren)

template destroyEntry(e: untyped) =
  # Destructors never raise; the cast covers effects that the compiler
  # cannot infer through recursive generic instantiations.
  {.cast(raises: []), cast(gcsafe).}:
    `=destroy`(e)

proc release[E](n: ChampPtr[E]) {.raises: [], gcsafe.} =
  ## Drops one reference, freeing the node and its subtree when it was the
  ## last one.
  if n != nil and dropRef(n):
    let es = n.entryArr
    for i in 0 ..< int(n.nentries):
      destroyEntry(es[i])
    let cs = n.childArr
    for i in 0 ..< int(n.nchildren):
      release(cs[i])
    freeRaw(n)

proc clone[E](n: ChampPtr[E]): ChampPtr[E] =
  var fresh = allocChamp[E](int(n.nentries), int(n.nchildren))
  defer:
    release(fresh)
  fresh.datamap = n.datamap
  fresh.nodemap = n.nodemap
  let src = n.entryArr
  let dst = fresh.entryArr
  fresh.nentries = 0
  for i in 0 ..< int(n.nentries):
    # Include the current slot in cleanup if a field copy fails partway.
    inc fresh.nentries
    dst[i] = src[i]
  let sc = n.childArr
  let dc = fresh.childArr
  for i in 0 ..< int(n.nchildren):
    dc[i] = sc[i]
    retain(sc[i])
  result = move(fresh)

proc ensureOwned[E](slot: var ChampPtr[E]) =
  if not isUnique(slot):
    let c = clone(slot)
    release(slot)
    slot = c

template takeEntry(dst, src: untyped, steal: bool) =
  if steal:
    dst = move(src)
  else:
    dst = src

template takeChild(dst, src: untyped, steal: bool) =
  dst = src
  if not steal:
    retain(src)

proc replaceSlot[E](slot: var ChampPtr[E], fresh: ChampPtr[E], stolen: bool) =
  ## Installs `fresh`. When `stolen`, every entry and child of the old node
  ## was moved into `fresh`, so only the shell is freed.
  if stolen:
    freeRaw(slot)
  else:
    release(slot)
  slot = fresh

proc champFind[E, K](root: ChampPtr[E], key: K, h: uint64): ptr E =
  mixin `==`
  var n = root
  var shift = 0
  while n != nil:
    if shift >= hashBits:
      let es = n.entryArr
      for i in 0 ..< int(n.nentries):
        if es[i].key == key:
          return addr es[i]
      return nil
    let bit = bitpos(h, shift)
    if (n.datamap and bit) != 0:
      let e = addr n.entryArr[index(n.datamap, bit)]
      return (if e.key == key: e else: nil)
    elif (n.nodemap and bit) != 0:
      n = n.childArr[index(n.nodemap, bit)]
      shift += champBits
    else:
      return nil
  nil

proc mergeTwo[E](
    a: sink E, ha: uint64, b: sink E, hb: uint64, shift: int
): ChampPtr[E] =
  if shift >= hashBits:
    result = allocChamp[E](2, 0)
    result.entryArr[0] = a
    result.entryArr[1] = b
    return
  let fa = fragment(ha, shift)
  let fb = fragment(hb, shift)
  if fa != fb:
    result = allocChamp[E](2, 0)
    result.datamap = (1'u32 shl fa) or (1'u32 shl fb)
    if fa < fb:
      result.entryArr[0] = a
      result.entryArr[1] = b
    else:
      result.entryArr[0] = b
      result.entryArr[1] = a
  else:
    result = allocChamp[E](0, 1)
    result.nodemap = 1'u32 shl fa
    result.childArr[0] = mergeTwo(a, ha, b, hb, shift + champBits)

proc champInsert[E](slot: var ChampPtr[E], shift: int, h: uint64, e: sink E): bool =
  ## Inserts `e`, replacing an entry with an equal key. Returns true when
  ## the key was not present before.
  mixin `==`
  if slot == nil:
    slot = allocChamp[E](1, 0)
    slot.datamap = bitpos(h, shift)
    slot.entryArr[0] = e
    return true
  let n = slot
  let ne = int(n.nentries)
  let nc = int(n.nchildren)

  if shift >= hashBits:
    let es = n.entryArr
    for i in 0 ..< ne:
      if es[i].key == e.key:
        ensureOwned(slot)
        slot.entryArr[i] = e
        return false
    let steal = isUnique(n)
    var fresh = allocChamp[E](ne + 1, 0)
    defer:
      release(fresh)
    let dst = fresh.entryArr
    for i in 0 ..< ne:
      takeEntry(dst[i], es[i], steal)
    dst[ne] = e
    replaceSlot(slot, move(fresh), steal)
    return true

  let bit = bitpos(h, shift)
  if (n.datamap and bit) != 0:
    let idx = index(n.datamap, bit)
    if n.entryArr[idx].key == e.key:
      ensureOwned(slot)
      slot.entryArr[idx] = e
      return false
    # Hash fragments collide at this level: push both entries down.
    let steal = isUnique(n)
    let src = n.entryArr
    # Hash before moving: a raising user `hash` must leave the node intact.
    let eh = keyHash(src[idx].key)
    var existing: E
    takeEntry(existing, src[idx], steal)
    var fresh = allocChamp[E](ne - 1, nc + 1)
    defer:
      release(fresh)
    fresh.datamap = n.datamap xor bit
    fresh.nodemap = n.nodemap or bit
    let cidx = index(fresh.nodemap, bit)
    let dc = fresh.childArr
    dc[cidx] = mergeTwo(existing, eh, e, h, shift + champBits)
    let dst = fresh.entryArr
    var j = 0
    for i in 0 ..< ne:
      if i != idx:
        takeEntry(dst[j], src[i], steal)
        inc j
    let sc = n.childArr
    for i in 0 ..< cidx:
      takeChild(dc[i], sc[i], steal)
    for i in cidx ..< nc:
      takeChild(dc[i + 1], sc[i], steal)
    replaceSlot(slot, move(fresh), steal)
    return true
  elif (n.nodemap and bit) != 0:
    ensureOwned(slot)
    return champInsert(slot.childArr[index(slot.nodemap, bit)], shift + champBits, h, e)
  else:
    let steal = isUnique(n)
    var fresh = allocChamp[E](ne + 1, nc)
    defer:
      release(fresh)
    fresh.datamap = n.datamap or bit
    fresh.nodemap = n.nodemap
    let idx = index(fresh.datamap, bit)
    let src = n.entryArr
    let dst = fresh.entryArr
    for i in 0 ..< idx:
      takeEntry(dst[i], src[i], steal)
    dst[idx] = e
    for i in idx ..< ne:
      takeEntry(dst[i + 1], src[i], steal)
    let sc = n.childArr
    let dc = fresh.childArr
    for i in 0 ..< nc:
      takeChild(dc[i], sc[i], steal)
    replaceSlot(slot, move(fresh), steal)
    return true

proc champErase[E, K](slot: var ChampPtr[E], shift: int, h: uint64, key: K) =
  ## Removes `key`. Precondition: `key` is present.
  mixin `==`
  let n = slot
  let ne = int(n.nentries)
  let nc = int(n.nchildren)

  if shift >= hashBits:
    let src = n.entryArr
    var idx = 0
    while not (src[idx].key == key):
      inc idx
    let steal = isUnique(n)
    var fresh = allocChamp[E](ne - 1, 0)
    defer:
      release(fresh)
    let dst = fresh.entryArr
    var j = 0
    for i in 0 ..< ne:
      if i != idx:
        takeEntry(dst[j], src[i], steal)
        inc j
    if steal:
      destroyEntry(src[idx])
    replaceSlot(slot, move(fresh), steal)
    return

  let bit = bitpos(h, shift)
  if (n.datamap and bit) != 0:
    if ne == 1 and nc == 0:
      # Only the root can hold a lone entry; the map becomes empty.
      release(slot)
      slot = nil
      return
    let idx = index(n.datamap, bit)
    let steal = isUnique(n)
    var fresh = allocChamp[E](ne - 1, nc)
    defer:
      release(fresh)
    fresh.datamap = n.datamap xor bit
    fresh.nodemap = n.nodemap
    let src = n.entryArr
    let dst = fresh.entryArr
    var j = 0
    for i in 0 ..< ne:
      if i != idx:
        takeEntry(dst[j], src[i], steal)
        inc j
    if steal:
      destroyEntry(src[idx])
    let sc = n.childArr
    let dc = fresh.childArr
    for i in 0 ..< nc:
      takeChild(dc[i], sc[i], steal)
    replaceSlot(slot, move(fresh), steal)
    return

  ensureOwned(slot)
  let owned = slot
  let cidx = index(owned.nodemap, bit)
  champErase(owned.childArr[cidx], shift + champBits, h, key)
  let child = owned.childArr[cidx]
  if child.nchildren != 0 or child.nentries != 1:
    return
  # The child shrank to a single entry: inline it into this node.
  let fresh = allocChamp[E](ne + 1, nc - 1)
  fresh.datamap = owned.datamap or bit
  fresh.nodemap = owned.nodemap xor bit
  let eidx = index(fresh.datamap, bit)
  let src = owned.entryArr
  let dst = fresh.entryArr
  for i in 0 ..< eidx:
    dst[i] = move(src[i])
  takeEntry(dst[eidx], child.entryArr[0], isUnique(child))
  for i in eidx ..< ne:
    dst[i + 1] = move(src[i])
  let sc = owned.childArr
  let dc = fresh.childArr
  var j = 0
  for i in 0 ..< nc:
    if i != cidx:
      dc[j] = sc[i]
      inc j
  release(child)
  freeRaw(owned)
  slot = fresh

iterator champEntries[E](root: ChampPtr[E]): ptr E =
  ## Pre-order walk over every entry. The caller must keep `root` alive.
  if root != nil:
    var stack: array[maxChampDepth + 1, tuple[node: ChampPtr[E], next: int]]
    var sp = 0
    stack[0] = (root, 0)
    for i in 0 ..< int(root.nentries):
      yield addr root.entryArr[i]
    while sp >= 0:
      let node = stack[sp].node
      let next = stack[sp].next
      if next < int(node.nchildren):
        stack[sp].next = next + 1
        let child = node.childArr[next]
        for i in 0 ..< int(child.nentries):
          yield addr child.entryArr[i]
        inc sp
        stack[sp] = (child, 0)
      else:
        dec sp

type DiffFrame[E] = object
  a, b: ChampPtr[E]
  shift: int
  pos: int ## next hash fragment to compare

iterator champDiff[E](a, b: ChampPtr[E]): tuple[old, new: ptr E] =
  ## Walks two tries in step and yields entries that may differ:
  ## `(old, nil)` for keys only in `a`, `(nil, new)` for keys only in `b`,
  ## and `(old, new)` for keys in both (the caller compares the rest of the
  ## entry). Subtrees shared by both tries are skipped. Matching two
  ## full-hash collision nodes can require comparing every pair of keys.
  ## The caller must keep both roots alive.
  mixin `==`
  if a == b:
    discard
  elif a == nil:
    for e in champEntries(b):
      yield (nil, e)
  elif b == nil:
    for e in champEntries(a):
      yield (e, nil)
  else:
    var stack: array[maxChampDepth + 1, DiffFrame[E]]
    var sp = 0
    stack[0] = DiffFrame[E](a: a, b: b)
    while sp >= 0:
      let x = stack[sp].a
      let y = stack[sp].b
      let shift = stack[sp].shift
      if shift >= hashBits:
        # Collision nodes: unordered entry lists with equal full hashes.
        let xs = x.entryArr
        let ys = y.entryArr
        for i in 0 ..< int(x.nentries):
          var match: ptr E = nil
          for j in 0 ..< int(y.nentries):
            if ys[j].key == xs[i].key:
              match = addr ys[j]
              break
          yield (addr xs[i], match)
        for j in 0 ..< int(y.nentries):
          var found = false
          for i in 0 ..< int(x.nentries):
            if xs[i].key == ys[j].key:
              found = true
              break
          if not found:
            yield (nil, addr ys[j])
        dec sp
        continue
      # Jump to the next hash fragment used by either node.
      let used = x.datamap or x.nodemap or y.datamap or y.nodemap
      let rest =
        if stack[sp].pos >= 32:
          0'u32
        else:
          used shr stack[sp].pos
      if rest == 0:
        dec sp
        continue
      let pos = stack[sp].pos + countTrailingZeroBits(rest)
      stack[sp].pos = pos + 1
      let bit = 1'u32 shl pos
      let dataA = (x.datamap and bit) != 0
      let dataB = (y.datamap and bit) != 0
      let nodeA = (x.nodemap and bit) != 0
      let nodeB = (y.nodemap and bit) != 0
      if dataA and dataB:
        let ea = addr x.entryArr[index(x.datamap, bit)]
        let eb = addr y.entryArr[index(y.datamap, bit)]
        if ea.key == eb.key:
          yield (ea, eb)
        else:
          yield (ea, nil)
          yield (nil, eb)
      elif nodeA and nodeB:
        let ca = x.childArr[index(x.nodemap, bit)]
        let cb = y.childArr[index(y.nodemap, bit)]
        if ca != cb:
          inc sp
          stack[sp] = DiffFrame[E](a: ca, b: cb, shift: shift + champBits)
      elif dataA and nodeB:
        let ea = addr x.entryArr[index(x.datamap, bit)]
        var found = false
        for eb in champEntries(y.childArr[index(y.nodemap, bit)]):
          if not found and eb.key == ea.key:
            found = true
            yield (ea, eb)
          else:
            yield (nil, eb)
        if not found:
          yield (ea, nil)
      elif nodeA and dataB:
        let eb = addr y.entryArr[index(y.datamap, bit)]
        var found = false
        for ea in champEntries(x.childArr[index(x.nodemap, bit)]):
          if not found and ea.key == eb.key:
            found = true
            yield (ea, eb)
          else:
            yield (ea, nil)
        if not found:
          yield (nil, eb)
      elif dataA:
        yield (addr x.entryArr[index(x.datamap, bit)], nil)
      elif dataB:
        yield (nil, addr y.entryArr[index(y.datamap, bit)])
      elif nodeA:
        for e in champEntries(x.childArr[index(x.nodemap, bit)]):
          yield (e, nil)
      elif nodeB:
        for e in champEntries(y.childArr[index(y.nodemap, bit)]):
          yield (nil, e)

proc champDepth[E](root: ChampPtr[E]): int =
  ## Maximum node depth; for tests and diagnostics.
  if root == nil:
    return 0
  result = 1
  for i in 0 ..< int(root.nchildren):
    result = max(result, 1 + champDepth(root.childArr[i]))
