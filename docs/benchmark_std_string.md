# String benchmarks: `string` vs `ImmStr` vs `FlexStr`

This compares Nim's `string` with thetos' two string types across common
operations, to show where each one is the right choice.

* **`string`**: Nim's mutable string. One contiguous buffer, copied in full
  on every copy.
* **`ImmStr`**: immutable string. One contiguous buffer behind a reference
  count, with a hash cached on first use. Copies are O(1). Building a new
  string (`&`, slicing) copies bytes, like `string`.
* **`FlexStr`**: persistent string (rope). Bytes in 32-byte leaves of a
  relaxed radix-balanced tree (`FlexVec[char]`). Copies are O(1), and
  concatenation, slicing, insertion and erasing are O(log n) and share
  structure with the inputs.

## Setup

* Apple M3 Pro, macOS, Nim 2.2.12.
* `nim r -d:danger benchmarks/bstring.nim`, with the repository's
  `config.nims` (`--mm:atomicArc --threads:on`), so `ImmStr` and `FlexStr`
  use atomic reference counts. The thread-local variants in `thetos/local`
  would be somewhat faster on copies.
* Each figure is the best of 7 runs, divided by the number of operations
  per run. The text is mixed ASCII and multi-byte UTF-8.
* Lower is better. Results vary by a few percent between runs; treat
  differences under about 20% as noise.

## Summary

| Workload | Best choice | Why |
|---|---|---|
| Strings copied a lot: map keys and values, `Atom` payloads, `Box` fields | `ImmStr` | Copies are a reference count increment at any size; a 64 KiB `string` copy is 150× slower. |
| Hashing the same strings repeatedly (map keys) | `ImmStr` | The hash is cached: 1.6 ns at any size, against 2.7 µs to hash 64 KiB. |
| Reading, comparing, scanning | `string` or `ImmStr` | Both are flat buffers. `FlexStr` pays for a tree walk and scattered leaves. |
| Building text byte by byte | `string` | Amortized appends to one buffer: 3× faster than `FlexStr`. |
| Editing large text: insert, delete, concatenate, slice | `FlexStr` | O(log n): 2.7 µs to insert into 1 MiB, against 303 µs for `string`. |
| Keeping many versions of large text (undo, history, snapshots) | `FlexStr` | Versions share structure: 1.8 MiB for 1,001 versions of a 64 KiB document, against 66.5 MiB. |

The two thetos types complement each other. `ImmStr` makes strings cheap
to *share*, and `FlexStr` makes them cheap to *edit and version*. Neither
beats `string` at reading a single buffer.

## Results

### Copying

Copying one value into an array slot.

| Size | `string` | `ImmStr` | `FlexStr` |
|---:|---:|---:|---:|
| 16 B | 4.7 ns | 3.7 ns | 9.3 ns |
| 1 KiB | 13.1 ns | 3.8 ns | 9.1 ns |
| 64 KiB | 586.8 ns | 3.8 ns | 9.0 ns |

`ImmStr` and `FlexStr` copies cost the same at any size: an atomic
increment (`FlexStr` holds two node references, so it costs about twice as
much). A `string` copy allocates and copies every byte.

### Copies inside thetos

| Operation | `string` | `ImmStr` |
|---|---:|---:|
| `TrieMap[int, V].put` on a shared 10k-entry map, 1 KiB values | 697.3 ns | 352.7 ns |
| `Atom[V].load` of a 1 KiB value | 18.9 ns | 6.0 ns |

A persistent update path-copies the nodes it changes, and copying a node
copies every entry in it: up to 32 values per level. With `string` values
that means copying their bytes; with `ImmStr`, a reference count increment
each. Every `Atom.load` also copies its payload.

### Hashing

Eight equal values in separate allocations, rotated so the compiler cannot
reuse a result.

| Size | `string` | `ImmStr` (cached after first) | `FlexStr` |
|---:|---:|---:|---:|
| 16 B | 2.4 ns | 1.6 ns | 23.3 ns |
| 1 KiB | 43.1 ns | 1.6 ns | 178.8 ns |
| 64 KiB | 2679.9 ns | 1.6 ns | 11149.0 ns |

`ImmStr` computes its hash on first use (the same cost as hashing a
`string`, and the same value) and caches it. `FlexStr` flattens itself to
hash, because equal strings can have different tree shapes, and the hash
must not depend on them.

### Equality

Equal values in separate allocations.

| Size | `string` | `ImmStr` | `FlexStr` |
|---:|---:|---:|---:|
| 16 B | 1.6 ns | 3.4 ns | 23.6 ns |
| 1 KiB | 19.9 ns | 20.6 ns | 231.3 ns |
| 64 KiB | 1311.3 ns | 1339.5 ns | 12574.4 ns |

`string` and `ImmStr` both compare one buffer with `memcmp`. `ImmStr`
returns at once for two copies of the same value (same buffer), and rejects
early when both hashes are cached and differ. `FlexStr` compares leaf by
leaf.

### Reading

| Operation, 64 KiB | `string` | `ImmStr` | `FlexStr` |
|---|---:|---:|---:|
| Random byte `s[i]` | 0.8 ns | 0.6 ns | 5.0 ns |
| Iterating every byte (per byte) | 0.1 ns | 0.1 ns | 0.2 ns |

Indexing a `FlexStr` walks the tree, O(log n). Iterating is nearly as fast
as a flat buffer because it visits each leaf once.

### Building

| Operation | `string` | `ImmStr` | `FlexStr` |
|---|---:|---:|---:|
| Appending 64 KiB one byte at a time (per byte) | 2.1 ns | n/a | 6.9 ns |
| `a & b`, 64 KiB each | 1135.2 ns | 1173.1 ns | 1930.8 ns |
| `a & b`, 1 MiB each | 24775.4 ns | 24777.9 ns | 2805.4 ns |

`ImmStr` has no in-place append: it is immutable, and each `&` builds a new
buffer. Concatenation is O(n) for the flat types and O(log n) for
`FlexStr`, so `FlexStr` falls behind on small inputs and wins by about 9×
at 1 MiB.

### Editing

| Operation | `string` | `ImmStr` | `FlexStr` |
|---|---:|---:|---:|
| Insert 8 bytes in the middle of 64 KiB, as a new version | 19957.2 ns | n/a | 2017.6 ns |
| Insert 8 bytes in the middle of 1 MiB, as a new version | 303.1 µs | n/a | 2691.7 ns |
| Slice half of a 1 MiB value | 280.7 µs | 6694.4 ns | 622.9 ns |

Keeping the original means `string` must copy before inserting. `FlexStr`
builds the new version from the old one's pieces in O(log n): 110× faster
at 1 MiB. Slicing `FlexStr` shares the leaves. Slicing `ImmStr` copies the
selected bytes with `copyMem`. In this run Nim's `string` slice (`s[a .. b]`)
copied far more slowly than that, about 2 GB/s.

### Keeping every version

Editing one byte of a 64 KiB document 1,000 times and keeping all 1,001
versions (as an undo history would).

| | `seq[string]` | `seq[FlexStr]` |
|---|---:|---:|
| Time per edit | 2387.1 ns | 3441.6 ns |
| Memory held by all versions | 66.5 MiB | 1.8 MiB |

At 64 KiB, copying a `string` per version is still slightly faster than a
`FlexStr` edit (`replace` is an erase plus an insert), but it holds a full
copy of the document per version. `FlexStr` versions share every leaf
except the edited one, so memory grows with the number of edits rather
than the document size, and the time per edit stays flat as documents grow
(see the 1 MiB insert above).

### Converting

| Operation, 64 KiB | Time |
|---|---:|
| `toImmStr(string)` | 576.6 ns |
| `$ImmStr` | 933.8 ns |
| `toFlexStr(string)` | 132.6 µs |
| `$FlexStr` | 8108.8 ns |

`ImmStr` converts in each direction with one allocation and `copyMem`.
`FlexStr` allocates a node per 32 bytes when built (2,048 leaves for
64 KiB), and flattening it gathers them back. Build a `FlexStr` once and
edit it, rather than converting back and forth.

## Reproducing

```sh
nim r -d:danger benchmarks/bstring.nim
```

The program prints the tables above (per type and size) in Markdown.
