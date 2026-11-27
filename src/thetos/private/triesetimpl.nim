# Included by the container modules and by `thetos/local`; not a module.
# The including module imports `std/[bitops, hashes, options]` and
# `private/core`, and declares `RcCount`, the type of each node's `rc`.

type
  SetEntry[T] = object
    key: T

  SetDiff*[T] = object ## One difference between two sets, from `diff`.
    kind*: DiffKind ## `dkAdded` or `dkRemoved`
    item*: T

  TrieSet*[T] = object ## Immutable, structurally shared hash set with value semantics.
    root: ChampPtr[SetEntry[T]]
    size: int

proc `=destroy`*[T](s: TrieSet[T]) =
  release(s.root)

proc `=wasMoved`*[T](s: var TrieSet[T]) =
  s.root = nil
  s.size = 0

proc `=dup`*[T](s: TrieSet[T]): TrieSet[T] =
  if s.root != nil:
    retain(s.root)
  result.root = s.root
  result.size = s.size

proc `=copy`*[T](dst: var TrieSet[T], src: TrieSet[T]) =
  if src.root != nil:
    retain(src.root)
  `=destroy`(dst)
  dst.root = src.root
  dst.size = src.size

proc initTrieSet*[T](): TrieSet[T] =
  ## Returns an empty set. `default(TrieSet[T])` is also empty.
  discard

proc len*[T](s: TrieSet[T]): int {.inline.} =
  s.size

proc contains*[T](s: TrieSet[T], x: T): bool =
  champFind(s.root, x, keyHash(x)) != nil

proc incl*[T](s: var TrieSet[T], x: sink T) =
  ## Adds `x` to this set value only; other copies are not affected.
  let h = keyHash(x)
  if champInsert(s.root, 0, h, SetEntry[T](key: x)):
    inc s.size

proc excl*[T](s: var TrieSet[T], x: T) =
  ## Removes `x` from this set value if present.
  let h = keyHash(x)
  if champFind(s.root, x, h) != nil:
    champErase(s.root, 0, h, x)
    dec s.size

proc insert*[T](s: sink TrieSet[T], x: sink T): TrieSet[T] =
  ## Returns a set that also contains `x`.
  result = s
  result.incl(x)

proc erase*[T](s: sink TrieSet[T], x: T): TrieSet[T] =
  ## Returns a set without `x`.
  result = s
  result.excl(x)

proc toTrieSet*[T](items: openArray[T]): TrieSet[T] =
  for x in items:
    result.incl(x)

iterator items*[T](s: TrieSet[T]): lent T =
  let keep = `=dup`(s) # iterate a snapshot even if `s` is reassigned
  for e in champEntries(keep.root):
    yield e.key

proc `<=`*[T](a, b: TrieSet[T]): bool =
  ## Subset test.
  if a.root == b.root:
    return true
  if a.size > b.size:
    return false
  for e in champEntries(a.root):
    if e.key notin b:
      return false
  true

iterator diff*[T](a, b: TrieSet[T]): SetDiff[T] =
  ## Yields every item added in `b` or removed from `a`. Parts of the two
  ## sets that are still shared are skipped without being visited. Matching
  ## two full-hash collision buckets can require comparing every pair of
  ## items across the buckets. The order is unspecified.
  runnableExamples:
    let a = toTrieSet([1, 2, 3])
    let b = a.erase(1).insert(4)
    var changes: seq[(DiffKind, int)]
    for d in diff(a, b):
      changes.add (d.kind, d.item)
    assert changes.len == 2
    assert (dkRemoved, 1) in changes and (dkAdded, 4) in changes

  let ka = `=dup`(a) # walk snapshots even if `a` or `b` is reassigned
  let kb = `=dup`(b)
  for (old, new) in champDiff(ka.root, kb.root):
    if old == nil:
      yield SetDiff[T](kind: dkAdded, item: new.key)
    elif new == nil:
      yield SetDiff[T](kind: dkRemoved, item: old.key)

proc `==`*[T](a, b: TrieSet[T]): bool =
  a.size == b.size and a <= b

proc `+`*[T](a, b: TrieSet[T]): TrieSet[T] =
  ## Union. Inserts the smaller set into the larger one.
  if a.size >= b.size:
    result = a
    for x in b:
      result.incl(x)
  else:
    result = b
    for x in a:
      result.incl(x)

proc `*`*[T](a, b: TrieSet[T]): TrieSet[T] =
  ## Intersection.
  let (small, large) =
    if a.size <= b.size:
      (a, b)
    else:
      (b, a)
  for x in small:
    if x in large:
      result.incl(x)

proc `-`*[T](a, b: TrieSet[T]): TrieSet[T] =
  ## Difference: elements of `a` not in `b`.
  result = a
  if b.size < a.size:
    for x in b:
      result.excl(x)
  else:
    for x in a:
      if x in b:
        result.excl(x)

proc hash*[T](s: TrieSet[T]): Hash =
  ## Order-independent hash of all elements.
  var acc: uint = 0
  for e in champEntries(s.root):
    acc = acc + cast[uint](!$hash(e.key))
  cast[Hash](acc)

proc `$`*[T](s: TrieSet[T]): string =
  result = "{"
  var first = true
  for e in champEntries(s.root):
    if not first:
      result.add ", "
    first = false
    result.addQuoted e.key
  result.add "}"
