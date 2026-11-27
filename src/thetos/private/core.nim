## Shared low-level helpers: raw shared allocation, reference counts and
## hash mixing. Each node has an `rc` field for ownership tracking.
##
## The reference count helpers pick their operations from the type of a
## node's `rc` field: `Atomic[int]` (or `Atomic[int64]`) uses atomic
## operations, a plain `int` uses ordinary arithmetic. The containers in
## `thetos` use `DefaultRc` (atomic unless built with `--threads:off`); the
## ones in `thetos/local` always use `int`.

import std/[atomics, hashes, typetraits]

when defined(thetosTrackAllocs):
  var liveAllocs: Atomic[int]
  var totalAllocs: Atomic[int]

  proc allocCount*(): int =
    ## Total nodes ever allocated. Only with `-d:thetosTrackAllocs`.
    totalAllocs.load(moAcquire)

  proc liveAllocations*(): int =
    ## Number of live thetos nodes. Only with `-d:thetosTrackAllocs`.
    liveAllocs.load(moAcquire)

proc allocRaw*(size: int): pointer {.inline.} =
  ## Zeroed allocation from the shared heap.
  when defined(thetosTrackAllocs):
    discard liveAllocs.fetchAdd(1, moRelaxed)
    discard totalAllocs.fetchAdd(1, moRelaxed)
  when compileOption("threads"):
    allocShared0(size)
  else:
    alloc0(size)

proc freeRaw*(p: pointer) {.inline.} =
  when defined(thetosTrackAllocs):
    discard liveAllocs.fetchSub(1, moRelaxed)
  when compileOption("threads"):
    deallocShared(p)
  else:
    dealloc(p)

template alignUp*(size, align: int): int =
  (size + align - 1) and not (align - 1)

proc allocAlignedRaw*(size: int, alignment: static int): pointer {.inline.} =
  when alignment <= alignof(pointer):
    allocRaw(size)
  else:
    # Keep the allocator's original pointer immediately before the aligned node.
    let raw = allocRaw(size + sizeof(pointer) + alignment - 1)
    let address =
      (cast[uint](raw) + uint(sizeof(pointer) + alignment - 1)) and
      not uint(alignment - 1)
    cast[ptr pointer](address - uint(sizeof(pointer)))[] = raw
    cast[pointer](address)

proc freeAlignedRaw*(p: pointer, alignment: static int) {.inline.} =
  when alignment <= alignof(pointer):
    freeRaw(p)
  else:
    freeRaw(cast[ptr pointer](cast[uint](p) - uint(sizeof(pointer)))[])

const thetosAtomicRc* = compileOption("threads")
  ## False when built with `--threads:off`. A program without threads cannot
  ## share values between threads, so plain counts are always safe there.

when thetosAtomicRc:
  type DefaultRc* = Atomic[int] ## reference count type of the `thetos` containers
else:
  type DefaultRc* = int

type DiffKind* = enum ## What happened to a key between two versions, from `diff`.
  dkAdded ## only in the second version
  dkRemoved ## only in the first version
  dkChanged ## in both, with different values (maps only)

proc initRc*[N](n: ptr N) {.inline.} =
  ## Sets the reference count of a fresh node to one.
  when n[].rc is Atomic:
    n[].rc.store(1, moRelaxed)
  else:
    n[].rc = 1

proc refCount*[N](n: ptr N): int {.inline.} =
  ## Current reference count; for assertions and diagnostics.
  when n[].rc is Atomic:
    int(n[].rc.load(moRelaxed))
  else:
    n[].rc

proc retain*[N](n: ptr N) {.inline.} =
  ## Adds an owner. The caller must already own a reference.
  when n[].rc is Atomic:
    discard n[].rc.fetchAdd(1, moRelaxed)
  else:
    n[].rc = n[].rc +% 1

proc dropRef*[N](n: ptr N): bool {.inline.} =
  ## Drops an owner. Returns true when the caller was the last owner and
  ## must free the node.
  when n[].rc is Atomic:
    if n[].rc.fetchSub(1, moRelease) == 1:
      fence(moAcquire)
      true
    else:
      false
  else:
    # Checked arithmetic can make generated cleanup return early while an
    # exception is pending. Match the atomic operations' wrapping arithmetic.
    n[].rc = n[].rc -% 1
    n[].rc == 0

proc isUnique*[N](n: ptr N): bool {.inline.} =
  ## True when the caller holds the only reference, so the node may be
  ## mutated in place. For atomic counts, the acquire pairs with the release
  ## in `dropRef`.
  when n[].rc is Atomic:
    n[].rc.load(moAcquire) == 1
  else:
    n[].rc == 1

proc raiseIndex*(i, size: int) {.noinline, noreturn.} =
  raise newException(IndexDefect, "index " & $i & " not in 0 .. " & $(size - 1))

proc mixHash*(h: Hash): uint64 {.inline.} =
  ## Spreads a user hash over 64 bits (murmur3 finalizer), so weak hashes
  ## (identity, multiples of 32, 32-bit hashes) still give balanced tries.
  var x = uint64(cast[uint](h))
  x = (x xor (x shr 33)) * 0xff51afd7ed558ccd'u64
  x = (x xor (x shr 33)) * 0xc4ceb9fe1a85ec53'u64
  x xor (x shr 33)

proc keyHash*[K](key: K): uint64 {.inline.} =
  mixin hash
  mixHash(hash(key))

template resetOnError*(value, body: untyped) =
  ## A raising copy can leave an owned value behind even when Nim omits
  ## its implicit destruction. Handle cleanup before propagating the error.
  when supportsCopyMem(typeof(value)):
    body
  else:
    try:
      body
    except Exception:
      reset(value)
      raise

template resetOnCopyError*(T: typedesc, value, body: untyped) =
  ## Use when only an element copy can fail while owning allocations.
  when supportsCopyMem(T):
    body
  else:
    resetOnError(value):
      body

proc ownedCopy*[T](value: T): T {.inline.} =
  ## Clean up a partial copy if an element hook raises.
  resetOnError(result):
    result = value

proc appendCopy*[V, T](v: var V, x: T) {.inline.} =
  mixin add
  when supportsCopyMem(T):
    v.add(x)
  else:
    # An implicit `=dup` for the sink argument can strand a partial copy in
    # its result. Copy into a local whose cleanup is under our control.
    var value: T
    resetOnError(value):
      value = x
    v.add(move(value))
