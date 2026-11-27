# Included by the container modules and by `thetos/local`; not a module.
# The including module imports `std/[bitops, hashes, options]` and
# `private/core`, and declares `RcCount`, the type of each node's `rc`.

type
  MapEntry[K, V] = object
    key: K
    value: V

  MapDiff*[K, V] = object ## One difference between two maps, from `diff`.
    kind*: DiffKind
    key*: K
    oldValue*: V ## value in the first map; `default(V)` when `dkAdded`
    newValue*: V ## value in the second map; `default(V)` when `dkRemoved`

  TrieMap*[K, V] = object
    ## Immutable, structurally shared hash map with value semantics.
    root: ChampPtr[MapEntry[K, V]]
    size: int

proc `=destroy`*[K, V](m: TrieMap[K, V]) =
  release(m.root)

proc `=wasMoved`*[K, V](m: var TrieMap[K, V]) =
  m.root = nil
  m.size = 0

proc `=dup`*[K, V](m: TrieMap[K, V]): TrieMap[K, V] =
  if m.root != nil:
    retain(m.root)
  result.root = m.root
  result.size = m.size

proc `=copy`*[K, V](dst: var TrieMap[K, V], src: TrieMap[K, V]) =
  if src.root != nil:
    retain(src.root)
  `=destroy`(dst)
  dst.root = src.root
  dst.size = src.size

proc initTrieMap*[K, V](): TrieMap[K, V] =
  ## Returns an empty map. `default(TrieMap[K, V])` is also empty.
  discard

proc len*[K, V](m: TrieMap[K, V]): int {.inline.} =
  m.size

proc findEntry[K, V](m: TrieMap[K, V], key: K): ptr MapEntry[K, V] {.inline.} =
  champFind(m.root, key, keyHash(key))

proc contains*[K, V](m: TrieMap[K, V], key: K): bool =
  m.findEntry(key) != nil

proc hasKey*[K, V](m: TrieMap[K, V], key: K): bool =
  m.findEntry(key) != nil

proc raiseKeyError[K](key: K) {.noinline, noreturn.} =
  when compiles($key):
    raise newException(KeyError, "key not found: " & $key)
  else:
    raise newException(KeyError, "key not found")

proc `[]`*[K, V](m: TrieMap[K, V], key: K): lent V =
  ## Returns the value for `key`. Raises `KeyError` if it is missing.
  let e = m.findEntry(key)
  if e == nil:
    raiseKeyError(key)
  e.value

proc getOrDefault*[K, V](m: TrieMap[K, V], key: K, def: V = default(V)): V =
  let e = m.findEntry(key)
  if e == nil: def else: e.value

proc get*[K, V](m: TrieMap[K, V], key: K): Option[V] =
  let e = m.findEntry(key)
  if e == nil:
    none(V)
  else:
    some(e.value)

proc `[]=`*[K, V](m: var TrieMap[K, V], key: K, value: sink V) =
  ## Sets `key` in this map value only; other copies are not affected.
  let h = keyHash(key)
  if champInsert(m.root, 0, h, MapEntry[K, V](key: key, value: value)):
    inc m.size

proc del*[K, V](m: var TrieMap[K, V], key: K) =
  ## Removes `key` from this map value if present.
  let h = keyHash(key)
  if champFind(m.root, key, h) != nil:
    champErase(m.root, 0, h, key)
    dec m.size

proc put*[K, V](m: sink TrieMap[K, V], key: K, value: sink V): TrieMap[K, V] =
  ## Returns a map with `key` set to `value`.
  result = m
  result[key] = value

proc erase*[K, V](m: sink TrieMap[K, V], key: K): TrieMap[K, V] =
  ## Returns a map without `key`.
  result = m
  result.del(key)

proc update*[K, V, F](m: sink TrieMap[K, V], key: K, f: F): TrieMap[K, V] =
  ## Returns a map where `key` maps to `f(old)`; `old` is `default(V)` when
  ## the key is missing.
  result = m
  let e = result.findEntry(key)
  let next =
    if e == nil:
      f(default(V))
    else:
      f(e.value)
  result[key] = next

proc toTrieMap*[K, V](pairs: openArray[(K, V)]): TrieMap[K, V] =
  for (k, v) in pairs:
    result[k] = v

iterator pairs*[K, V](m: TrieMap[K, V]): (K, V) =
  let keep = `=dup`(m) # iterate a snapshot even if `m` is reassigned
  for e in champEntries(keep.root):
    yield (e.key, e.value)

iterator keys*[K, V](m: TrieMap[K, V]): lent K =
  let keep = `=dup`(m)
  for e in champEntries(keep.root):
    yield e.key

iterator values*[K, V](m: TrieMap[K, V]): lent V =
  let keep = `=dup`(m)
  for e in champEntries(keep.root):
    yield e.value

proc mapChange[K, V](
    kind: DiffKind, key: K, old, new: ptr MapEntry[K, V]
): MapDiff[K, V] =
  resetOnError(result):
    result.kind = kind
    result.key = key
    if old != nil:
      result.oldValue = old.value
    if new != nil:
      result.newValue = new.value

iterator diff*[K, V](a, b: TrieMap[K, V]): MapDiff[K, V] =
  ## Yields every key that differs between `a` and `b`: added in `b`,
  ## removed from `a`, or present in both with values that are not `==`.
  ## Parts of the two maps that are still shared (for example when `b` was
  ## derived from `a`) are skipped without being visited. Matching two
  ## full-hash collision buckets can require comparing every pair of keys
  ## across the buckets. The order is unspecified.
  runnableExamples:
    let a = toTrieMap({1: "one", 2: "two"})
    let b = a.put(2, "deux").put(3, "trois")
    var changes: seq[(DiffKind, int)]
    for d in diff(a, b):
      changes.add (d.kind, d.key)
    assert changes.len == 2
    assert (dkChanged, 2) in changes and (dkAdded, 3) in changes

  mixin `==`
  let ka = `=dup`(a) # walk snapshots even if `a` or `b` is reassigned
  let kb = `=dup`(b)
  for (old, new) in champDiff(ka.root, kb.root):
    if old == nil:
      yield mapChange(dkAdded, new.key, old, new)
    elif new == nil:
      yield mapChange(dkRemoved, old.key, old, new)
    elif not (old.value == new.value):
      yield mapChange(dkChanged, old.key, old, new)

proc `==`*[K, V](a, b: TrieMap[K, V]): bool =
  if a.root == b.root:
    return true
  if a.size != b.size:
    return false
  for e in champEntries(a.root):
    let o = b.findEntry(e.key)
    if o == nil or not (o.value == e.value):
      return false
  true

proc hash*[K, V](m: TrieMap[K, V]): Hash =
  ## Order-independent hash of all entries.
  var acc: uint = 0
  for e in champEntries(m.root):
    acc = acc + cast[uint](!$(hash(e.key) !& hash(e.value)))
  cast[Hash](acc)

proc `$`*[K, V](m: TrieMap[K, V]): string =
  if m.len == 0:
    return "{:}"
  result = "{"
  var first = true
  for e in champEntries(m.root):
    if not first:
      result.add ", "
    first = false
    result.addQuoted e.key
    result.add ": "
    result.addQuoted e.value
  result.add "}"

proc depth*[K, V](m: TrieMap[K, V]): int =
  ## Trie depth; useful for diagnostics.
  champDepth(m.root)
