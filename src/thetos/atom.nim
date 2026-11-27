## Lock-free mutable cell holding an immutable value, after `immer::atom`.
##
## An `Atom[T]` is the one place shared state changes: threads `load`
## snapshots, compute new versions with the persistent containers, and
## publish them with `store`, `exchange` or a compare-and-swap `update`.
## None of these operations take a lock.
##
## `T` must be safe to copy from several threads at once. All thetos
## containers qualify (copying one is an atomic increment), as do plain
## values, strings and seqs.
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
## global, an object shared by pointer, or `createShared` memory.

runnableExamples:
  import thetos/triemap
  var counts: Atom[TrieMap[string, int]]
  counts.update(
    proc(m: TrieMap[string, int]): TrieMap[string, int] =
      m.put("hits", m.getOrDefault("hits") + 1)
  )
  assert counts.load()["hits"] == 1

when defined(thetosSingleThread):
  {.
    error:
      "thetos/atom shares values between threads and cannot be used " &
      "with -d:thetosSingleThread"
  .}

import std/atomics
import ./private/core

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

proc exchange*[T](a: var Atom[T], value: sink T): T =
  ## Stores `value` and returns the previous value.
  let old = a.word.exchange(packCell(newCell(value)), moAcquireRelease)
  let cell = cellOf[T](old)
  if cell != nil:
    transferPending(cell, old)
    defer:
      releaseCell(cell)
    # Unique means no loader holds or has reserved the cell: take the value.
    if isUnique(cell):
      result = move(cell.value)
    else:
      result = cell.value

proc store*[T](a: var Atom[T], value: sink T) =
  ## Replaces the value.
  let old = a.word.exchange(packCell(newCell(value)), moAcquireRelease)
  retireCell[T](old)

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
