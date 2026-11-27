# String benchmarks on arm64: `string` vs `ImmStr` vs `FlexStr`

This compares Nim's `string` with thetos' two string types across common
operations, to show where each one is the right choice.
[amd64 results on FreeBSD](benchmark_std_string_amd64.md)

* **`string`**: Nim's mutable string. One contiguous buffer, copied in full
  on every copy.
* **`ImmStr`**: immutable string. One contiguous buffer behind a reference
  count, with a hash cached on first use. Copies are O(1). Building a new
  string (`&`, slicing) copies bytes, like `string`.
* **`FlexStr`**: persistent string (rope). Bytes in 128-byte leaves of a
  relaxed radix-balanced tree (`FlexVec[char]`). Copies are O(1), and
  concatenation, slicing, insertion and erasing are O(log n) and share
  structure with the inputs.

## FlexStr leaf size

Version 0.5.0 increased the capacity of a `FlexStr` leaf from 32 to
128 bytes. Building a 64 KiB string now needs 512 leaves instead of 2,048.
The table shows the median of three invocations of the benchmark program
for each capacity, using the setup below.

| Operation, 64 KiB | 32-byte leaves | 128-byte leaves |
|---|---:|---:|
| Build from `string` | 132.5 µs | 69.8 µs |
| Convert back to `string` | 8.08 µs | 3.49 µs |
| Compare two equal values | 6.79 µs | 3.06 µs |
| Random byte lookup | 6.1 ns | 4.6 ns |
| Insert 8 bytes | 2.01 µs | 1.72 µs |
| Replace one byte and retain each version | 277 ns | 250 ns |

## Setup

* Apple M3 Pro, macOS 15.7.9, Nim 2.2.12. Measured on 2026-11-27.
* `nim r -d:danger benchmarks/bstring.nim`, with the repository's
  `config.nims` (`--mm:atomicArc --threads:on`), so `ImmStr` and `FlexStr`
  use atomic reference counts.
* Each figure is the best of 7 runs, divided by the number of operations
  per run. The text is mixed ASCII and multi-byte UTF-8.
* Times are per operation unless a row specifies per byte. Small inputs
  are particularly sensitive to timing variation.

## Summary

The summary and detailed results below use the original 32-byte leaves.

| Workload | Best choice | Why |
|---|---|---|
| Strings copied a lot: map keys and values, `Atom` payloads, `Box` fields | `ImmStr` | An `ImmStr` copy increments a reference count. Copying the 64 KiB `string` took 153× as long. |
| Hashing the same strings repeatedly (map keys) | `ImmStr` | A cached 64 KiB hash took 1.6 ns. Hashing the same bytes as a `string` took 2.71 µs. |
| Reading, comparing, scanning | `string` or `ImmStr` | Both are flat buffers. `FlexStr` pays for a tree walk and scattered leaves. |
| Building text byte by byte | `string` | Appending to one buffer took 2.2 ns per byte. Appending to the rope took 7.0 ns. |
| Editing large text: insert, delete, concatenate, slice | `FlexStr` | Inserting 8 bytes into 1 MiB took 2.75 µs with `FlexStr` and 257.8 µs with `string`. |
| Keeping many versions of large text (undo, history, snapshots) | `FlexStr` | Retaining 1,001 versions of a 64 KiB document used 1.8 MiB with `FlexStr` and 66.5 MiB with `string`. |

The two thetos types complement each other. `ImmStr` makes strings cheap
to *share*, and `FlexStr` makes them cheap to *edit and version*. Neither
beats `string` at reading a single buffer.

## Results

### Copying

Copying one value into an array slot.

| Size | `string` | `ImmStr` | `FlexStr` |
|---:|---:|---:|---:|
| 16 B | 13.9 ns | 4.4 ns | 15.2 ns |
| 1 KiB | 13.1 ns | 3.8 ns | 9.2 ns |
| 64 KiB | 579.8 ns | 3.8 ns | 9.2 ns |

Copying either persistent type shares its existing storage. `ImmStr`
holds one node reference. A `FlexStr` with both a tree and a tail holds
two. A `string` copy allocates and copies the bytes.

### Copies inside thetos

| Operation | `string` | `ImmStr` |
|---|---:|---:|
| `TrieMap[int, V].put` on a shared 10k-entry map, 1 KiB values | 658.7 ns | 358.1 ns |
| `Atom[V].load` of a 1 KiB value | 19.4 ns | 6.1 ns |

A persistent update path-copies the nodes it changes, and copying a node
copies every entry in it: up to 32 values per level. With `string` values
that means copying their bytes; with `ImmStr`, a reference count increment
each. Every `Atom.load` also copies its payload.

### Hashing

Eight equal values in separate allocations, rotated so the compiler cannot
reuse a result.

| Size | `string` | `ImmStr` (cached after first) | `FlexStr` |
|---:|---:|---:|---:|
| 16 B | 2.4 ns | 1.6 ns | 22.3 ns |
| 1 KiB | 43.9 ns | 1.6 ns | 180.4 ns |
| 64 KiB | 2713.1 ns | 1.6 ns | 11219.8 ns |

`ImmStr` computes its hash on first use (the same cost as hashing a
`string`, and the same value) and caches it. `FlexStr` flattens itself to
hash, because equal strings can have different tree shapes, and the hash
must not depend on them.

### Equality

Equal values in separate allocations.

| Size | `string` | `ImmStr` | `FlexStr` |
|---:|---:|---:|---:|
| 16 B | 1.6 ns | 3.5 ns | 7.3 ns |
| 1 KiB | 20.2 ns | 21.0 ns | 103.5 ns |
| 64 KiB | 1337.4 ns | 1365.6 ns | 6738.1 ns |

`string` and `ImmStr` both compare one buffer with `memcmp`. `ImmStr`
returns at once for two copies of the same value (same buffer), and rejects
early when both hashes are cached and differ. `FlexStr` walks the two trees
together and stops at the first unequal byte range. On separately allocated
64 KiB values this took 6.74 µs, down from 13.16 µs when equality built a
temporary list of leaves.

### Reading

| Operation, 64 KiB | `string` | `ImmStr` | `FlexStr` |
|---|---:|---:|---:|
| Random byte `s[i]` | 0.8 ns | 0.6 ns | 6.1 ns |
| Iterating every byte (per byte) | 0.1 ns | 0.1 ns | 0.2 ns |

Indexing a `FlexStr` walks the tree, O(log n). Iterating is nearly as fast
as a flat buffer because it visits each leaf once.

### Building

| Operation | `string` | `ImmStr` | `FlexStr` |
|---|---:|---:|---:|
| Appending 64 KiB one byte at a time (per byte) | 2.2 ns | n/a | 7.0 ns |
| `a & b`, 64 KiB each | 1162.3 ns | 1226.7 ns | 1956.6 ns |
| `a & b`, 1 MiB each | 25282.5 ns | 25277.9 ns | 2775.4 ns |

`ImmStr` has no in-place append: it is immutable, and each `&` builds a new
buffer. Concatenation is O(n) for the flat types and O(log n) for
`FlexStr`, so `FlexStr` falls behind on small inputs and wins by about 9×
at 1 MiB.

### Editing

| Operation | `string` | `ImmStr` | `FlexStr` |
|---|---:|---:|---:|
| Insert 8 bytes at a random offset in 64 KiB, as a new version | 18627.6 ns | n/a | 2008.8 ns |
| Insert 8 bytes at a random offset in 1 MiB, as a new version | 257.8 µs | n/a | 2752.5 ns |
| Slice half of a 1 MiB value | 285.5 µs | 6897.5 ns | 628.8 ns |

Keeping the original means `string` must copy before inserting. `FlexStr`
shares the prefix and suffix with the old version. At 1 MiB, copying and
editing the flat string took 94× as long. Slicing `FlexStr` shares the
leaves. Slicing `ImmStr` copies the selected bytes with `copyMem`. In this
run Nim's `string` slice copied 1.8 GB/s.

### Keeping every version

Editing one byte of a 64 KiB document 1,000 times and keeping all 1,001
versions (as an undo history would).

| | `seq[string]` | `seq[FlexStr]` |
|---|---:|---:|
| Time per edit | 2444.9 ns | 279.3 ns |
| Memory held by all versions | 66.5 MiB | 1.8 MiB |

A one-byte replacement copies the edited leaf and the path leading to it.
The other leaves are shared with the previous version. This reduced time
per edit from 3.55 µs with erase followed by insert to 0.28 µs in the
same benchmark. The timed loop includes maintaining the version history.

### Converting

| Operation, 64 KiB | Time |
|---|---:|
| `toImmStr(string)` | 618.7 ns |
| `$ImmStr` | 951.9 ns |
| `toFlexStr(string)` | 131.8 µs |
| `$FlexStr` | 8073.5 ns |

`ImmStr` converts in each direction with one allocation and `copyMem`.
`FlexStr` allocated a node per 32 bytes in this run (2,048 leaves for
64 KiB), and flattening it gathers them back. Build a `FlexStr` once and
edit it, rather than converting back and forth.

## Reproducing

```sh
nim r -d:danger benchmarks/bstring.nim
```

The program prints the tables above (per type and size) in Markdown.
