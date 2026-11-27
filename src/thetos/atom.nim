## Lock-free mutable cell holding an immutable value, after `immer::atom`.
##
## An `Atom[T]` is the one place shared state changes: threads `load`
## snapshots, compute new versions with the persistent containers, and
## publish them with `store`, `exchange` or a compare-and-swap `update`.
## None of these operations take a lock.
##
## `T` must be safe to copy from several threads at once. All thetos
## containers qualify (copying one is an atomic increment), as do plain
## values, strings and seqs. Nim refs and closures only qualify under
## `--mm:atomicArc`. Under `--mm:arc` or `--mm:orc` with threads on, an
## `Atom[T]` whose `T` holds them fails to compile; define
## `thetosUnsafeRefAtom` to turn that check off.
##
## Implementation: each stored value lives in a refcounted cell. The atom
## word packs the cell pointer with a 16-bit (32-bit on 32-bit targets)
## count of in-flight loads ("split reference counting"). A loader
## reserves the cell by bumping that count in the same CAS that reads the
## pointer, so the cell cannot be freed before the loader takes its own
## reference. An installed cell carries a reference-count bias that keeps
## it alive until the writer accounts for outstanding reservations. The
## writer replaces the bias with those reservations and its own reference
## in one atomic operation. Cells are never reinstalled, so
## pointer equality identifies one installation and avoids ABA.
##
## An `Atom` is a location, not a value: it cannot be copied. Keep it in a
## global, an object shared by pointer, or `createShared` memory, or use
## `AtomRef[T]`: a reference-counted handle whose copies share one atom, with
## a version counter so holders can cheaply check for new stores.

runnableExamples:
  import thetos/triemap
  var counts: Atom[TrieMap[string, int]]
  counts.update(
    proc(m: TrieMap[string, int]): TrieMap[string, int] =
      m.put("hits", m.getOrDefault("hits") + 1)
  )
  assert counts.load()["hits"] == 1

import std/[atomics, hashes, typetraits]
import ./private/[core, reftraits]

type
  AtomCell[T] = object
    rc*: Atomic[int64] # exported for the generic refcount helpers in core
    value: T

  CellPtr[T] = ptr AtomCell[T]

  Atom*[T] = object ## Lock-free shared cell. `default(Atom[T])` holds `default(T)`.
    word: Atomic[uint64]

when sizeof(pointer) == 8:
  const
    countShift = 48
    ptrMask = (1'u64 shl countShift) - 1
else:
  const
    countShift = 32
    ptrMask = (1'u64 shl countShift) - 1

const
  countOne = 1'u64 shl countShift
  countMax = not ptrMask
  installedBias = 1'i64 shl (64 - countShift)

template cellOf[T](w: uint64): CellPtr[T] =
  cast[CellPtr[T]](cast[uint](w and ptrMask))

template packCell(p: pointer): uint64 =
  uint64(cast[uint](p))

template checkShareable(T: typedesc) =
  # arc/orc count refs and closures non-atomically, and every `load`
  # copies the value from whichever thread calls it.
  when compileOption("threads") and holdsLocalContainers(T):
    {.
      error:
        "Atom[" & name(T) & "] holds thread-local containers from " &
        "thetos/local, whose reference counts are not atomic. Use the " &
        "containers from thetos for values shared between threads."
    .}
  elif compileOption("threads") and not defined(gcAtomicArc) and
      not defined(thetosUnsafeRefAtom) and holdsNimRefs(T):
    {.
      error:
        "Atom[" & name(T) & "] holds Nim refs or closures, whose reference " &
        "counts are not atomic under --mm:arc or --mm:orc. Sharing them " &
        "between threads corrupts memory. Build with --mm:atomicArc, or " &
        "define thetosUnsafeRefAtom to disable this check."
    .}

proc releaseCell[T](c: CellPtr[T]) {.raises: [], gcsafe.} =
  if c != nil and dropRef(c):
    {.cast(raises: []), cast(gcsafe).}:
      `=destroy`(c.value)
    freeAlignedRaw(c, alignof(AtomCell[T]))

template makeCell(T: typedesc, payload: untyped): untyped =
  block:
    var cell =
      cast[CellPtr[T]](allocAlignedRaw(sizeof(AtomCell[T]), alignof(AtomCell[T])))
    cell.rc.store(1, moRelaxed)
    defer:
      releaseCell(cell)
    cell.value = payload
    assert (packCell(cell) and not ptrMask) == 0, "pointer uses the count bits"
    cell.rc.store(installedBias, moRelaxed)
    move(cell)

proc newCell[T](value: sink T): CellPtr[T] =
  checkShareable(T)
  makeCell(T, value)

proc copyCell[T](value: T): CellPtr[T] =
  makeCell(T, value)

proc transferPending[T](cell: CellPtr[T], old: uint64) {.inline.} =
  # Readers may already have subtracted their reservations. The bias exceeds
  # the maximum reservation count, so those debits cannot free the cell.
  let pending = int64(old shr countShift)
  discard cell.rc.fetchAdd(pending + 1 - installedBias, moRelaxed)

proc retireCell[T](old: uint64) =
  let cell = cellOf[T](old)
  if cell != nil:
    transferPending(cell, old)
    releaseCell(cell)

proc `=destroy`*[T](a: Atom[T]) =
  # No other thread may use an atom while it is destroyed.
  let w = cast[ptr uint64](addr a.word)[]
  retireCell[T](w)

proc `=copy`*[T](dst: var Atom[T], src: Atom[T]) {.error.}
proc `=dup`*[T](src: Atom[T]): Atom[T] {.error.}

proc acquireCell[T](a: var Atom[T]): CellPtr[T] =
  ## Returns the current cell with one reference owned by the caller, or
  ## nil when the atom is empty.
  checkShareable(T)
  var w = a.word.load(moRelaxed)
  while true:
    if cellOf[T](w) == nil:
      return nil
    if (w and countMax) == countMax:
      # Absurd number of concurrent loaders; wait for one to finish.
      cpuRelax()
      w = a.word.load(moRelaxed)
      continue
    if a.word.compareExchangeWeak(w, w + countOne, moAcquire, moRelaxed):
      break
  let cell = cellOf[T](w)
  retain(cell)
  # Return the reservation to the word while it still refers to this cell.
  # After replacement, debit the cell even if the writer has yet to credit it.
  var cur = w + countOne
  while true:
    if cellOf[T](cur) != cell:
      discard dropRef(cell) # cannot reach zero: we hold our own reference
      break
    if a.word.compareExchangeWeak(cur, cur - countOne, moRelease, moRelaxed):
      break
  cell

proc initAtom*[T](value: sink T): Atom[T] =
  ## Creates an atom holding `value`.
  result.word.store(packCell(newCell(value)), moRelaxed)

proc load*[T](a: var Atom[T]): T =
  ## Returns the current value (a snapshot; O(1) for thetos containers).
  let cell = acquireCell(a)
  if cell != nil:
    defer:
      releaseCell(cell)
    result = cell.value

proc replaceCell[T](a: var Atom[T], value: sink T): uint64 {.inline.} =
  a.word.exchange(packCell(newCell(value)), moAcquireRelease)

proc takePrevious[T](old: uint64): T =
  let cell = cellOf[T](old)
  if cell != nil:
    transferPending(cell, old)
    defer:
      releaseCell(cell)
    # Unique means no loader holds or has reserved the cell: take the value.
    if isUnique(cell):
      result = move(cell.value)
    else:
      resetOnError(result):
        result = cell.value

proc exchange*[T](a: var Atom[T], value: sink T): T =
  ## Stores `value` and returns the previous value.
  takePrevious[T](a.replaceCell(value))

proc store*[T](a: var Atom[T], value: sink T) =
  ## Replaces the value.
  retireCell[T](a.replaceCell(value))

proc update*[T, F](a: var Atom[T], f: F): T {.discardable.} =
  ## Atomically replaces the value `x` with `f(x)` using a CAS loop and
  ## returns the stored value. `f` may run several times under contention,
  ## so it should be free of side effects.
  while true:
    let cell = acquireCell(a)
    defer:
      releaseCell(cell)
    result =
      if cell == nil:
        f(default(T))
      else:
        f(cell.value)
    # Copy before publishing: once installed, `next` may be freed by others.
    let next = copyCell(result)
    var expected = a.word.load(moRelaxed)
    while cellOf[T](expected) == cell:
      if a.word.compareExchangeWeak(
        expected, packCell(next), moAcquireRelease, moRelaxed
      ):
        retireCell[T](expected)
        return
    retireCell[T](packCell(next))

template updateIt*[T](a: var Atom[T], op: untyped): untyped =
  ## Like `update`, with the new value given as an expression of `it`, the
  ## current value: `counter.updateIt(it + 1)`. `op` may be evaluated
  ## several times under contention, so it should be free of side effects.
  a.update(
    proc(it {.inject.}: T): T =
      op
  )

# AtomRef -----------------------------------------------------------------

type
  AtomRefNode[T] = object
    rc*: DefaultRc # exported for the generic refcount helpers in core
    version: Atomic[int]
    atom: Atom[T]

  AtomRef*[T] = object
    ## Copyable handle to one shared `Atom[T]`. Copies are O(1) and share
    ## the atom, so every holder sees every update. `default(AtomRef[T])` is
    ## a nil handle; create one with `newAtomRef`.
    node: ptr AtomRefNode[T]

proc `=destroy`*[T](r: AtomRef[T]) =
  if r.node != nil and dropRef(r.node):
    {.cast(raises: []), cast(gcsafe).}:
      `=destroy`(r.node.atom)
    freeAlignedRaw(r.node, alignof(AtomRefNode[T]))

proc `=wasMoved`*[T](r: var AtomRef[T]) =
  r.node = nil

proc `=dup`*[T](r: AtomRef[T]): AtomRef[T] =
  if r.node != nil:
    retain(r.node)
  result.node = r.node

proc `=copy`*[T](dst: var AtomRef[T], src: AtomRef[T]) =
  if src.node != nil:
    retain(src.node)
  `=destroy`(dst)
  dst.node = src.node

proc newAtomRef*[T](value: sink T): AtomRef[T] =
  ## Creates a handle to a new atom holding `value`.
  runnableExamples:
    let a = newAtomRef(1)
    let b = a # shares the atom
    b.store(2)
    assert a.load() == 2

  var atom = initAtom(value)
  let node = cast[ptr AtomRefNode[T]](allocAlignedRaw(
    sizeof(AtomRefNode[T]), alignof(AtomRefNode[T])
  ))
  initRc(node)
  node.atom = move(atom)
  result.node = node

proc isNil*[T](r: AtomRef[T]): bool {.inline.} =
  ## True for a default-initialized or moved-from handle.
  r.node == nil

proc raiseNilAtomRef() {.noinline, noreturn.} =
  raise newException(ValueError, "nil AtomRef")

template target[T](r: AtomRef[T]): var Atom[T] =
  if r.node == nil:
    raiseNilAtomRef()
  r.node.atom

template published[T](r: AtomRef[T]) =
  # Release: a reader that sees the new version also sees the new value.
  discard r.node.version.fetchAdd(1, moRelease)

proc load*[T](r: AtomRef[T]): T =
  ## Returns the current value (a snapshot). Raises `ValueError` for a nil
  ## handle, as do the other operations.
  target(r).load()

proc publishReplacement[T](r: AtomRef[T], value: sink T): uint64 =
  # A payload hook may reassign the caller's handle while building the cell.
  let keep = `=dup`(r)
  result = target(keep).replaceCell(value)
  published(keep)

proc store*[T](r: AtomRef[T], value: sink T) =
  ## Replaces the value.
  retireCell[T](r.publishReplacement(value))

proc exchange*[T](r: AtomRef[T], value: sink T): T =
  ## Stores `value` and returns the previous value. If copying the previous
  ## value raises, the new value and its version have already been published.
  result = takePrevious[T](r.publishReplacement(value))

proc update*[T, F](r: AtomRef[T], f: F): T {.discardable.} =
  ## Atomically replaces the value `x` with `f(x)` and returns the stored
  ## value, like `Atom.update`. `f` may run several times under contention.
  # The callback can reassign the handle through which update was called.
  let keep = `=dup`(r)
  result = target(keep).update(f)
  published(keep)

template updateIt*[T](r: AtomRef[T], op: untyped): untyped =
  ## Like `update`, with the new value given as an expression of `it`, the
  ## current value. `op` may be evaluated several times under contention.
  r.update(
    proc(it {.inject.}: T): T =
      op
  )

proc version*[T](r: AtomRef[T]): int =
  ## Number of stores so far. Read it before `load`ing to know that the
  ## snapshot is at least that recent; `refresh` does this for you.
  if r.node == nil:
    raiseNilAtomRef()
  r.node.version.load(moAcquire)

proc refresh*[T](r: AtomRef[T], snapshot: var T, seen: var int): bool =
  ## Reloads `snapshot` if the atom has been stored to since version `seen`,
  ## and returns true when it did. Checking costs one atomic read, so
  ## holders can call it often and reload only on change. Start `seen` at
  ## -1 to force the first load.
  runnableExamples:
    let counter = newAtomRef(0)
    var snapshot: int
    var seen = -1
    assert counter.refresh(snapshot, seen) # first load
    assert not counter.refresh(snapshot, seen) # nothing changed
    counter.store(5)
    assert counter.refresh(snapshot, seen) and snapshot == 5

  let current = r.version
  if current == seen:
    return false
  snapshot = r.load()
  seen = current
  true

proc `==`*[T](a, b: AtomRef[T]): bool {.inline.} =
  ## True when both handles refer to the same atom.
  a.node == b.node

proc hash*[T](r: AtomRef[T]): Hash =
  ## Hash of the atom's identity, not of its value.
  hash(cast[pointer](r.node))

proc `$`*[T](r: AtomRef[T]): string =
  if r.node == nil:
    "AtomRef(nil)"
  else:
    var s = "AtomRef("
    s.addQuoted r.load()
    s.add ")"
    s
