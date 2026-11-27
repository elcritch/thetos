## Persistent (immutable) hash set, after `immer::set`.
##
## `Set[T]` shares the CHAMP trie of `Map` and has the same properties:
## O(1) copies, O(log32 n) updates by path copying, in-place updates when
## uniquely owned, and atomic reference counts so sets can be shared across
## threads without locks.
##
## If you also import `std/sets`, qualify `toSet`/`initSet` calls with the
## module name, since `std/sets` keeps deprecated procs with those names.

runnableExamples:
  let a = toSet([1, 2, 3])
  let b = a.insert(4)
  assert 4 notin a and 4 in b
  assert (a + toSet([9])).len == 4

import std/hashes
import ./private/[core, champ]

type
  SetEntry[T] = object
    key: T

  Set*[T] = object ## Immutable, structurally shared hash set with value semantics.
    root: ChampPtr[SetEntry[T]]
    size: int

proc `=destroy`*[T](s: Set[T]) =
  release(s.root)

proc `=wasMoved`*[T](s: var Set[T]) =
  s.root = nil
  s.size = 0

proc `=dup`*[T](s: Set[T]): Set[T] =
  if s.root != nil:
    retain(s.root)
  result.root = s.root
  result.size = s.size

proc `=copy`*[T](dst: var Set[T], src: Set[T]) =
  if src.root != nil:
    retain(src.root)
  `=destroy`(dst)
  dst.root = src.root
  dst.size = src.size

proc initSet*[T](): Set[T] =
  ## Returns an empty set. `default(Set[T])` is also empty.
  discard

proc len*[T](s: Set[T]): int {.inline.} =
  s.size

proc contains*[T](s: Set[T], x: T): bool =
  champFind(s.root, x, keyHash(x)) != nil

proc incl*[T](s: var Set[T], x: sink T) =
  ## Adds `x` to this set value only; other copies are not affected.
  let h = keyHash(x)
  if champInsert(s.root, 0, h, SetEntry[T](key: x)):
    inc s.size

proc excl*[T](s: var Set[T], x: T) =
  ## Removes `x` from this set value if present.
  let h = keyHash(x)
  if champFind(s.root, x, h) != nil:
    champErase(s.root, 0, h, x)
    dec s.size

proc insert*[T](s: sink Set[T], x: sink T): Set[T] =
  ## Returns a set that also contains `x`.
  result = s
  result.incl(x)

proc erase*[T](s: sink Set[T], x: T): Set[T] =
  ## Returns a set without `x`.
  result = s
  result.excl(x)

proc toSet*[T](items: openArray[T]): Set[T] =
  for x in items:
    result.incl(x)

iterator items*[T](s: Set[T]): lent T =
  let keep = `=dup`(s) # iterate a snapshot even if `s` is reassigned
  for e in champEntries(keep.root):
    yield e.key

proc `<=`*[T](a, b: Set[T]): bool =
  ## Subset test.
  if a.root == b.root:
    return true
  if a.size > b.size:
    return false
  for e in champEntries(a.root):
    if e.key notin b:
      return false
  true

proc `==`*[T](a, b: Set[T]): bool =
  a.size == b.size and a <= b

proc `+`*[T](a, b: Set[T]): Set[T] =
  ## Union. Inserts the smaller set into the larger one.
  if a.size >= b.size:
    result = a
    for x in b:
      result.incl(x)
  else:
    result = b
    for x in a:
      result.incl(x)

proc `*`*[T](a, b: Set[T]): Set[T] =
  ## Intersection.
  let (small, large) =
    if a.size <= b.size:
      (a, b)
    else:
      (b, a)
  for x in small:
    if x in large:
      result.incl(x)

proc `-`*[T](a, b: Set[T]): Set[T] =
  ## Difference: elements of `a` not in `b`.
  result = a
  if b.size < a.size:
    for x in b:
      result.excl(x)
  else:
    for x in a:
      if x in b:
        result.excl(x)

proc hash*[T](s: Set[T]): Hash =
  ## Order-independent hash of all elements.
  var acc: uint = 0
  for e in champEntries(s.root):
    acc = acc + cast[uint](!$hash(e.key))
  cast[Hash](acc)

proc `$`*[T](s: Set[T]): string =
  result = "{"
  var first = true
  for e in champEntries(s.root):
    if not first:
      result.add ", "
    first = false
    result.addQuoted e.key
  result.add "}"
