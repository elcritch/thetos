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
## reference. A writer that swaps the cell out transfers the outstanding
## count into the cell's reference count. Cells are never reinstalled, so
## pointer equality identifies one installation and avoids ABA.
##
## An `Atom` is a location, not a value: it cannot be copied. Keep it in a
## global, an object shared by pointer, or `createShared` memory.

runnableExamples:
  import thetos/hashmap
  var counts: Atom[Map[string, int]]
  counts.update(
    proc(m: Map[string, int]): Map[string, int] =
      m.put("hits", m.getOrDefault("hits") + 1)
  )
  assert counts.load()["hits"] == 1

import std/atomics
import ./private/core

type
  AtomCell[T] = object
    rc*: Atomic[int] # exported for the generic refcount helpers in core
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

template cellOf[T](w: uint64): CellPtr[T] =
  cast[CellPtr[T]](cast[uint](w and ptrMask))

template packCell(p: pointer): uint64 =
  uint64(cast[uint](p))

proc newCell[T](value: sink T): CellPtr[T] =
  result = cast[CellPtr[T]](allocRaw(sizeof(AtomCell[T])))
  result.rc.store(1, moRelaxed)
  result.value = value
  assert (packCell(result) and not ptrMask) == 0, "pointer uses the count bits"

proc releaseCell[T](c: CellPtr[T]) {.raises: [], gcsafe.} =
  if c != nil and dropRef(c):
    {.cast(raises: []), cast(gcsafe).}:
      `=destroy`(c.value)
    freeRaw(c)

proc `=destroy`*[T](a: Atom[T]) =
  # No other thread may use an atom while it is destroyed, so any
  # reservation count is zero and the atom owns one reference to the cell.
  let w = cast[ptr uint64](addr a.word)[]
  releaseCell(cellOf[T](w))

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
  # Hand the reservation back, unless a writer already moved it into the
  # cell's reference count.
  var cur = w + countOne
  while true:
    if cellOf[T](cur) != cell:
      discard dropRef(cell) # cannot reach zero: we hold our own reference
      break
    if a.word.compareExchangeWeak(cur, cur - countOne, moRelease, moRelaxed):
      break
  cell

proc transferPending[T](cell: CellPtr[T], old: uint64) {.inline.} =
  ## Moves the in-flight load reservations recorded in the swapped-out word
  ## `old` into the cell's reference count.
  let pending = int(old shr countShift)
  if pending > 0:
    discard cell.rc.fetchAdd(pending, moRelaxed)

proc retireCell[T](old: uint64) =
  ## Releases the atom's reference to a cell that was swapped out by a
  ## successful exchange/CAS returning the word `old`.
  let cell = cellOf[T](old)
  if cell != nil:
    transferPending(cell, old)
    releaseCell(cell)

proc initAtom*[T](value: sink T): Atom[T] =
  ## Creates an atom holding `value`.
  result.word.store(packCell(newCell(value)), moRelaxed)

proc load*[T](a: var Atom[T]): T =
  ## Returns the current value (a snapshot; O(1) for thetos containers).
  let cell = acquireCell(a)
  if cell != nil:
    result = cell.value
    releaseCell(cell)

proc exchange*[T](a: var Atom[T], value: sink T): T =
  ## Stores `value` and returns the previous value.
  let old = a.word.exchange(packCell(newCell(value)), moAcquireRelease)
  let cell = cellOf[T](old)
  if cell != nil:
    transferPending(cell, old)
    # Unique means no loader holds or has reserved the cell: take the value.
    if isUnique(cell):
      result = move(cell.value)
    else:
      result = cell.value
    releaseCell(cell)

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
    result =
      if cell == nil:
        f(default(T))
      else:
        f(cell.value)
    # Copy before publishing: once installed, `next` may be freed by others.
    let next = newCell(result)
    var expected = a.word.load(moRelaxed)
    var swapped = false
    while cellOf[T](expected) == cell:
      if a.word.compareExchangeWeak(
        expected, packCell(next), moAcquireRelease, moRelaxed
      ):
        swapped = true
        break
    if swapped:
      retireCell[T](expected)
      releaseCell(cell)
      return
    releaseCell(next)
    releaseCell(cell)
