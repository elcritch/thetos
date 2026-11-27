# String benchmarks on arm64 and amd64

This compares Nim's `string` with thetos' two string types across common
operations.

* **`string`** is a mutable contiguous buffer, copied in full on every copy.
* **`ImmStr`** shares an immutable contiguous buffer and caches its hash on
  first use. Copies are O(1). Concatenating and slicing copy bytes.
* **`FlexStr`** stores bytes in a relaxed radix-balanced tree
  (`FlexVec[char]`). Copies are O(1), and concatenation, slicing,
  insertion, and erasing are O(log n) and share structure with the inputs.

## Setup

* arm64 ran on an Apple M3 Pro with macOS 15.7.9. Detailed results use
  32-byte `FlexStr` leaves and report the best of seven samples.
* amd64 ran on an AMD Ryzen 7 8745HS with FreeBSD 15.1-RELEASE-p1 and
  Clang 19.1.7, pinned to logical CPU 2. Detailed results use 128-byte
  `FlexStr` leaves (`d0a1254`) and report the median of three invocations.
  Each invocation reports the best of seven samples.
* Both used Nim 2.2.12 and `-d:danger` with `--mm:atomicArc --threads:on`
  on 2026-11-27. The text mixes ASCII and multibyte UTF-8.
* Times are per operation unless the row or column gives another
  denominator.

## FlexStr leaf size

Version 0.5.0 increased the capacity of a `FlexStr` leaf from 32 to 128
bytes. Building a 64 KiB string takes 512 leaves with the larger capacity,
compared with 2,048 before. Both architectures report the median of three
invocations for each capacity. The amd64 baseline was `e8a41bc`.

| Operation, 64 KiB | Arch | 32-byte leaves (ns) | 128-byte leaves (ns) |
| --- | --- | ---: | ---: |
| Build from `string` | arm64 | 132500 | 69800 |
| Build from `string` | amd64 | 126200 | 100900 |
| Convert back to `string` | arm64 | 8080 | 3490 |
| Convert back to `string` | amd64 | 6630 | 3770 |
| Compare two equal values | arm64 | 6790 | 3060 |
| Compare two equal values | amd64 | 9450 | 3580 |
| Random byte lookup | arm64 | 6.1 | 4.6 |
| Random byte lookup | amd64 | 3.6 | 3.3 |
| Insert 8 bytes | arm64 | 2010 | 1720 |
| Insert 8 bytes | amd64 | 2410 | 1880 |
| Replace one byte and retain each version | arm64 | 277 | 250 |
| Replace one byte and retain each version | amd64 | 525.7 | 385.3 |

## Results

The arm64 results below use 32-byte `FlexStr` leaves and the amd64 results
use 128-byte leaves. The leaf-size table above measures both capacities on
each machine.

### Copying

Copying one value into an array slot.

| Size | Arch | `string` (ns) | `ImmStr` (ns) | `FlexStr` (ns) |
| --- | --- | ---: | ---: | ---: |
| 16 B | arm64 | 13.9 | 4.4 | 15.2 |
| 16 B | amd64 | 2.9 | 3.2 | 5.3 |
| 1 KiB | arm64 | 13.1 | 3.8 | 9.2 |
| 1 KiB | amd64 | 17.5 | 3.2 | 7.1 |
| 64 KiB | arm64 | 579.8 | 3.8 | 9.2 |
| 64 KiB | amd64 | 925.2 | 3.2 | 7.1 |

A `string` copy allocates and copies bytes. An `ImmStr` copy retains one
node, and a `FlexStr` with both a tree and a tail retains two.

### Copies inside thetos

| Operation, 1 KiB values | Arch | `string` (ns) | `ImmStr` (ns) |
| --- | --- | ---: | ---: |
| `TrieMap.put` on a shared 10,000-entry map | arm64 | 658.7 | 358.1 |
| `TrieMap.put` on a shared 10,000-entry map | amd64 | 779.6 | 399.2 |
| `Atom.load` | arm64 | 19.4 | 6.1 |
| `Atom.load` | amd64 | 28.6 | 10.6 |

A persistent update path-copies the nodes it changes, and copying a node
copies every entry in it. A `string` value copies its bytes and an
`ImmStr` value increments its reference count. `Atom.load` also copies
its payload.

### Hashing

The benchmark rotates eight equal values held in separate allocations.
The `ImmStr` measurement uses the hash cached on the first call.

| Size | Arch | `string` (ns) | `ImmStr`, cached (ns) | `FlexStr` (ns) |
| --- | --- | ---: | ---: | ---: |
| 16 B | arm64 | 2.4 | 1.6 | 22.3 |
| 16 B | amd64 | 2.4 | 1.1 | 26.7 |
| 1 KiB | arm64 | 43.9 | 1.6 | 180.4 |
| 1 KiB | amd64 | 54.4 | 1.1 | 124.9 |
| 64 KiB | arm64 | 2713.1 | 1.6 | 11219.8 |
| 64 KiB | amd64 | 3130 | 1.1 | 6390 |

`FlexStr` hashes the flattened bytes so equal values produce the same
hash regardless of the tree shape.

### Equality

Equal values in separate allocations.

| Size | Arch | `string` (ns) | `ImmStr` (ns) | `FlexStr` (ns) |
| --- | --- | ---: | ---: | ---: |
| 16 B | arm64 | 1.6 | 3.5 | 7.3 |
| 16 B | amd64 | 3.1 | 4.2 | 25.4 |
| 1 KiB | arm64 | 20.2 | 21.0 | 103.5 |
| 1 KiB | amd64 | 19.7 | 18.6 | 71.3 |
| 64 KiB | arm64 | 1337.4 | 1365.6 | 6738.1 |
| 64 KiB | amd64 | 1060 | 1060 | 3580 |

`string` and `ImmStr` compare flat buffers with `memcmp`. `FlexStr` walks
the two trees together and stops at the first unequal byte range. On
arm64, the leaf walk reduced the 64 KiB comparison from 13.16 µs when
equality built a temporary list of leaves to 6.74 µs.

### Reading

| Operation, 64 KiB | Arch | `string` (ns) | `ImmStr` (ns) | `FlexStr` (ns) |
| --- | --- | ---: | ---: | ---: |
| Random byte `s[i]` | arm64 | 0.8 | 0.6 | 6.1 |
| Random byte `s[i]` | amd64 | 1.1 | 1.8 | 3.3 |
| Iterating every byte (per byte) | arm64 | 0.1 | 0.1 | 0.2 |
| Iterating every byte (per byte) | amd64 | 0.4 | 0.3 | 0.3 |

Indexing a `FlexStr` walks the tree in O(log n). Sequential iteration
visits each leaf once.

### Building and editing

Byte-at-a-time appends build a 64 KiB value. Inserts retain the original
and use a random byte offset. Slices select exactly half of the input.

| Operation | Arch | `string` (ns) | `ImmStr` (ns) | `FlexStr` (ns) |
| --- | --- | ---: | ---: | ---: |
| Append one byte at a time to build 64 KiB (per byte) | arm64 | 2.2 | n/a | 7.0 |
| Append one byte at a time to build 64 KiB (per byte) | amd64 | 2.5 | n/a | 5.7 |
| Concatenate two 64 KiB values | arm64 | 1162.3 | 1226.7 | 1956.6 |
| Concatenate two 64 KiB values | amd64 | 1910 | 1880 | 1420 |
| Concatenate two 1 MiB values | arm64 | 25282.5 | 25277.9 | 2775.4 |
| Concatenate two 1 MiB values | amd64 | 35200 | 35000 | 2470 |
| Insert 8 bytes into 64 KiB, retaining the original | arm64 | 18627.6 | n/a | 2008.8 |
| Insert 8 bytes into 64 KiB, retaining the original | amd64 | 20300 | n/a | 1880 |
| Insert 8 bytes into 1 MiB, retaining the original | arm64 | 257800 | n/a | 2752.5 |
| Insert 8 bytes into 1 MiB, retaining the original | amd64 | 325100 | n/a | 3390 |
| Slice half of a 1 MiB value | arm64 | 285500 | 6897.5 | 628.8 |
| Slice half of a 1 MiB value | amd64 | 236300 | 9150 | 877.7 |

`ImmStr` concatenation builds a new buffer. `FlexStr` shares the
unchanged parts of the input when concatenating, slicing, or inserting.

### Keeping every version

The benchmark replaces one byte 1,000 times in a 64 KiB document and
retains the initial value and every edit.

| Arch | `seq[string]` time (ns/edit) | `seq[FlexStr]` time (ns/edit) | `seq[string]` memory (MiB) | `seq[FlexStr]` memory (MiB) |
| --- | ---: | ---: | ---: | ---: |
| arm64 | 2444.9 | 279.3 | 66.5 | 1.8 |
| amd64 | 4930 | 385.3 | 66.5 | 1.3 |

A single-byte replacement copies the edited leaf and the path leading to
it. On arm64, this reduced time per edit from 3.55 µs using erase followed
by insert to 0.28 µs.

### Converting

| Operation, 64 KiB | arm64 (ns) | amd64 (ns) |
| --- | ---: | ---: |
| `toImmStr(string)` | 618.7 | 1980 |
| `$ImmStr` | 951.9 | 1510 |
| `toFlexStr(string)` | 131800 | 100900 |
| `$FlexStr` | 8073.5 | 3770 |

`ImmStr` makes a copy with one allocation and `copyMem` in either
direction. Building a `FlexStr` allocates its leaves, and converting back
gathers the bytes into a flat buffer.

## Reproducing

Run the benchmark from the repository root. [Benchmark program](../benchmarks/bstring.nim)

```sh
nim r -d:danger benchmarks/bstring.nim
```

On FreeBSD, compile with Clang and pin the process to one CPU.

```sh
nim c -d:danger --cc:clang --skipUserCfg:on -o:/tmp/bstring benchmarks/bstring.nim
cpuset -l 2 /tmp/bstring
```

Use a checkout of `e8a41bc` to reproduce the amd64 results with 32-byte
leaves.
