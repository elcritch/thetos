# JSON benchmarks on arm64 and amd64

This compares the stdlib's mutable JSON tree with thetos' persistent JSON
tree across text I/O, typed conversions, and edits that retain previous
versions.

* **`JsonNode`** from `std/json` is a mutable tree with ordered object
  members and arrays backed by sequences. Assigning a node shares its
  reference, and `copy` recursively duplicates the tree.
* **`JsonValue`** from `thetos/jsonutils` uses `TrieMap` for objects,
  `FlexVec` for arrays, and `ImmStr` for keys and strings. Copies share
  storage, and edits copy the paths they change. Object member order is
  unspecified.

## ORC on arm64

On the Apple M3 Pro, thetos rendered the document 1.50× faster and decoded
it 1.38× faster than the stdlib. The stdlib encoded it 1.44× faster.

| Operation | Stdlib JSON | thetos JSON (`97efd2c`) |
| --- | ---: | ---: |
| Parse JSON text into a tree | 239.88 µs | 237.67 µs |
| Render a tree to JSON text | 126.94 µs | 84.60 µs |
| Encode a Nim `Document` into a tree | 65.40 µs | 94.05 µs |
| Decode a tree into a Nim `Document` | 74.66 µs | 54.07 µs |
| Edit the current document | 0.05 µs/edit | 0.54 µs/edit |
| Edit and retain a snapshot | 118.88 µs/edit | 0.58 µs/edit |
| Memory retained across 500 edits | 130.12 MiB | 1.02 MiB |

Both APIs ran in the same executable with Nim 2.2.12, ORC, and threads
enabled. Each timing is the fastest of seven rounds of 500 operations on
the same 31,129-byte document containing 256 rows. Each round calls
`GC_fullCollect()` before starting the timer and again after its locals
leave scope, before stopping the timer.

Both edit workloads replace one row's `id` per operation and visit rows
in the same order. The current-document workload starts with an independently
parsed tree outside the timer. The stdlib updates the row in place and
thetos replaces the edited path. Only the latest document is kept.
For each retained snapshot the
stdlib deep-copied the mutable tree before editing one row, while thetos
copied the changed path and shared the other rows. The history benchmark
also runs a timed collection with all 501 versions live immediately before
measuring retained memory.

Run the ORC benchmark from the repository root.

```sh
nim r -d:release --mm:orc --threads:on benchmarks/bjsonutils.nim all 500
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
