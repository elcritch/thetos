## Persistent (immutable) hash map, after `immer::map`.
##
## `Map[K, V]` is a value type backed by a CHAMP hash trie with atomic
## reference counts. Copying a map is O(1) and shares all structure; an
## update copies only the path to the changed entry (O(log32 n)) and leaves
## every other copy untouched. Maps can be shared freely between threads:
## nodes are never mutated while shared, and reference counts are atomic.
##
## When a map's nodes are uniquely owned (for example the only copy, or a
## `sink` argument at its last use) updates happen in place, so building a
## map in a loop with `[]=` is about as cheap as a mutable table.
##
## Keys need `hash` and `==`. Keys and values must be safe to copy from
## several threads at once: plain values, strings, seqs and thetos
## containers are; Nim `ref`s are only when compiled with `--mm:atomicArc`.

runnableExamples:
  var a = initMap[string, int]()
  a["one"] = 1
  let b = a.put("two", 2) # `a` is unchanged
  assert a.len == 1 and b.len == 2
  assert b["two"] == 2
  assert "two" notin a

import std/[hashes, options]
import ./private/[core, champ]

type
  MapEntry[K, V] = object
    key: K
    value: V

  Map*[K, V] = object ## Immutable, structurally shared hash map with value semantics.
    root: ChampPtr[MapEntry[K, V]]
    size: int

proc `=destroy`*[K, V](m: Map[K, V]) =
  release(m.root)

proc `=wasMoved`*[K, V](m: var Map[K, V]) =
  m.root = nil
  m.size = 0

proc `=dup`*[K, V](m: Map[K, V]): Map[K, V] =
  if m.root != nil:
    retain(m.root)
  result.root = m.root
  result.size = m.size

proc `=copy`*[K, V](dst: var Map[K, V], src: Map[K, V]) =
  if src.root != nil:
    retain(src.root)
  `=destroy`(dst)
  dst.root = src.root
  dst.size = src.size

proc initMap*[K, V](): Map[K, V] =
  ## Returns an empty map. `default(Map[K, V])` is also empty.
  discard

proc len*[K, V](m: Map[K, V]): int {.inline.} =
  m.size

proc findEntry[K, V](m: Map[K, V], key: K): ptr MapEntry[K, V] {.inline.} =
  champFind(m.root, key, keyHash(key))

proc contains*[K, V](m: Map[K, V], key: K): bool =
  m.findEntry(key) != nil

proc hasKey*[K, V](m: Map[K, V], key: K): bool =
  m.findEntry(key) != nil

proc raiseKeyError[K](key: K) {.noinline, noreturn.} =
  when compiles($key):
    raise newException(KeyError, "key not found: " & $key)
  else:
    raise newException(KeyError, "key not found")

proc `[]`*[K, V](m: Map[K, V], key: K): lent V =
  ## Returns the value for `key`. Raises `KeyError` if it is missing.
  let e = m.findEntry(key)
  if e == nil:
    raiseKeyError(key)
  e.value

proc getOrDefault*[K, V](m: Map[K, V], key: K, def: V = default(V)): V =
  let e = m.findEntry(key)
  if e == nil: def else: e.value

proc get*[K, V](m: Map[K, V], key: K): Option[V] =
  let e = m.findEntry(key)
  if e == nil:
    none(V)
  else:
    some(e.value)

proc `[]=`*[K, V](m: var Map[K, V], key: K, value: sink V) =
  ## Sets `key` in this map value only; other copies are not affected.
  let h = keyHash(key)
  if champInsert(m.root, 0, h, MapEntry[K, V](key: key, value: value)):
    inc m.size

proc del*[K, V](m: var Map[K, V], key: K) =
  ## Removes `key` from this map value if present.
  let h = keyHash(key)
  if champFind(m.root, key, h) != nil:
    champErase(m.root, 0, h, key)
    dec m.size

proc put*[K, V](m: sink Map[K, V], key: K, value: sink V): Map[K, V] =
  ## Returns a map with `key` set to `value`.
  result = m
  result[key] = value

proc erase*[K, V](m: sink Map[K, V], key: K): Map[K, V] =
  ## Returns a map without `key`.
  result = m
  result.del(key)

proc update*[K, V, F](m: sink Map[K, V], key: K, f: F): Map[K, V] =
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

proc toMap*[K, V](pairs: openArray[(K, V)]): Map[K, V] =
  for (k, v) in pairs:
    result[k] = v

iterator pairs*[K, V](m: Map[K, V]): (K, V) =
  let keep = `=dup`(m) # iterate a snapshot even if `m` is reassigned
  for e in champEntries(keep.root):
    yield (e.key, e.value)

iterator keys*[K, V](m: Map[K, V]): lent K =
  let keep = `=dup`(m)
  for e in champEntries(keep.root):
    yield e.key

iterator values*[K, V](m: Map[K, V]): lent V =
  let keep = `=dup`(m)
  for e in champEntries(keep.root):
    yield e.value

proc `==`*[K, V](a, b: Map[K, V]): bool =
  if a.root == b.root:
    return true
  if a.size != b.size:
    return false
  for e in champEntries(a.root):
    let o = b.findEntry(e.key)
    if o == nil or not (o.value == e.value):
      return false
  true

proc hash*[K, V](m: Map[K, V]): Hash =
  ## Order-independent hash of all entries.
  var acc: uint = 0
  for e in champEntries(m.root):
    acc = acc + cast[uint](!$(hash(e.key) !& hash(e.value)))
  cast[Hash](acc)

proc `$`*[K, V](m: Map[K, V]): string =
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

proc depth*[K, V](m: Map[K, V]): int =
  ## Trie depth; useful for diagnostics.
  champDepth(m.root)
