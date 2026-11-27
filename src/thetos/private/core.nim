## Shared low-level helpers: raw shared allocation, atomic reference counts
## and hash mixing. Each node has an atomic `rc` field for ownership tracking.

import std/[atomics, hashes]

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

proc retain*[N](n: ptr N) {.inline.} =
  ## Adds an owner. The caller must already own a reference.
  discard n[].rc.fetchAdd(1, moRelaxed)

proc dropRef*[N](n: ptr N): bool {.inline.} =
  ## Drops an owner. Returns true when the caller was the last owner and
  ## must free the node.
  if n[].rc.fetchSub(1, moRelease) == 1:
    fence(moAcquire)
    true
  else:
    false

proc isUnique*[N](n: ptr N): bool {.inline.} =
  ## True when the caller holds the only reference, so the node may be
  ## mutated in place. Acquire pairs with the release in `dropRef`.
  n[].rc.load(moAcquire) == 1

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
