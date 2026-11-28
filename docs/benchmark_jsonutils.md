# JSON benchmarks on arm64 and amd64

This compares the stdlib's mutable JSON tree with thetos' persistent JSON
tree across text I/O, typed conversions, ordinary edits, and edits that
retain previous versions.

* **`JsonNode`** from `std/json` is a mutable tree with ordered object
  members and arrays backed by sequences. Assigning a node shares its
  reference, and `copy` recursively duplicates the tree.
* **`JsonValue`** from `thetos/jsonutils` uses `TrieMap` for objects,
  `FlexVec` for arrays, and `ImmStr` for keys and strings. Copies share
  storage, and edits copy the paths they change. Object member order is
  unspecified.

## ORC and ARC on arm64

On an Apple M3 Pro, both libraries took about 0.05 µs to update a field
when keeping only the current document. Retaining all 501 versions took
0.99 MiB for thetos and 130.12 MiB for the stdlib under either memory manager.

| Operation | ORC stdlib JSON | ORC thetos JSON | ARC stdlib JSON | ARC thetos JSON |
| --- | ---: | ---: | ---: | ---: |
| Parse JSON text into a tree | 239.80 µs | 237.40 µs | 243.69 µs | 238.58 µs |
| Render a tree to JSON text | 126.12 µs | 84.82 µs | 128.03 µs | 86.92 µs |
| Encode a Nim `Document` into a tree | 68.25 µs | 91.11 µs | 70.48 µs | 90.95 µs |
| Decode a tree into a Nim `Document` | 77.96 µs | 52.48 µs | 71.63 µs | 52.53 µs |
| Edit the current document | 0.049 µs/edit | 0.049 µs/edit | 0.050 µs/edit | 0.048 µs/edit |
| Edit and retain a snapshot | 119.15 µs/edit | 0.465 µs/edit | 137.00 µs/edit | 0.475 µs/edit |
| Memory retained across 500 edits | 130.12 MiB | 0.99 MiB | 130.12 MiB | 0.99 MiB |

For each memory manager, both libraries ran in the same release executable
with Nim 2.2.12 and threads enabled. The table reports the median of three
invocations. Each invocation took the fastest of seven rounds of 500
operations on a 31,129-byte document containing 256 rows. Each round calls
`GC_fullCollect()` before starting the timer and again after its locals
leave scope, before stopping the timer.

Both edit workloads replace one row's `id` per operation and visit rows in
the same order. The current-document workload starts with an independently
parsed tree outside the timer. The stdlib assigns to
`document["rows"][i]["id"]`. Thetos calls
`document.setPath(("rows", i, "id"), value)`, which reuses uniquely owned
nodes and copies shared nodes along the path. For the snapshot workload,
the stdlib deep-copies the document before each edit and thetos keeps a
copy of the root value. The benchmark calls `GC_fullCollect()` with all
501 versions live immediately before measuring retained memory.

Run the comparisons from the repository root.

```sh
nim r -d:release --mm:orc --threads:on benchmarks/bjsonutils.nim all 500
nim r -d:release --mm:arc --threads:on benchmarks/bjsonutils.nim all 500
```

## atomicArc setup

* arm64 ran on an Apple M3 Pro with macOS 15.7.9.
* amd64 ran on an AMD Ryzen 7 8745HS with FreeBSD 15.1-RELEASE-p1 and
  Clang 19.1.7. Benchmarks ran sequentially on logical CPU 2.
* Both used Nim 2.2.12 and `-d:release` with `--mm:atomicArc --threads:on`
  on 2026-11-27.
* The 31,129-byte document contains 256 records with integers, booleans,
  floats, strings with escaped quotes and multibyte UTF-8, and arrays
  of strings.
* Each timing is the median of three program invocations. Each invocation
  reports the fastest of seven runs of 500 operations. Direct comparisons
  use both APIs in the same executable.

## atomicArc results

### Text I/O

Both parsers read the same text and build a complete tree. Rendering starts
with a parsed tree and produces compact JSON.

| Operation | Arch | `JsonNode` (µs) | `JsonValue` (µs) |
| --- | --- | ---: | ---: |
| Parse text | arm64 | 245.1 | 236.2 |
| Parse text | amd64 | 240.16 | 236.48 |
| Render to `string` | arm64 | 126.1 | 84.1 |
| Render to `string` | amd64 | 116.30 | 81.89 |

`parseJsonValue` uses the stdlib tokenizer and writes tokens directly
into persistent containers. The renderer writes to one string buffer and
appends runs of unescaped bytes together.

### Keeping every version

The benchmark changes one `id` per edit, cycling through rows in a fixed
order. It retains the initial document and all 500 edits. The stdlib
case calls `JsonNode.copy` before mutating the selected row, so each
snapshot has its own mutable tree. The thetos case updates the row, the
array, and the root object with `put`.

| Arch | Deep copy + edit `JsonNode` (µs/edit) | Persistent edit of `JsonValue` (µs/edit) | `JsonNode` history (MiB) | `JsonValue` history (MiB) |
| --- | ---: | ---: | ---: | ---: |
| arm64 | 110.15 | 0.45 | 130.12 | 1.02 |
| amd64 | 110.36 | 0.53 | 130.12 | 1.02 |

Time includes building and releasing the history. Memory is the change in
Nim's `getOccupiedMem()` measured while all versions are live, with the
original tree already allocated.

## Reproducing

Run the benchmark from the repository root. Selecting an operation runs
just that workload once. [Benchmark program](../benchmarks/bjsonutils.nim)

```sh
nim r -d:release benchmarks/bjsonutils.nim
nim r -d:release benchmarks/bjsonutils.nim history 500
```

On FreeBSD, compile with Clang and pin the process to one CPU.

```sh
nim c -d:release --cc:clang --skipUserCfg:on -o:/tmp/bjsonutils benchmarks/bjsonutils.nim
cpuset -l 2 /tmp/bjsonutils
```

Sample the persistent parsing workload on macOS.

```sh
nim c -d:release --debugger:native -o:/tmp/bjsonutils benchmarks/bjsonutils.nim
/tmp/bjsonutils parse 30000 &
sample "$!" 2 1 -file /tmp/json-parse-sample.txt
```
