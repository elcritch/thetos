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

## Setup

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

## Results

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

### Typed conversions

Both sides convert the same Nim object containing a `FlexVec` of 256
records. The stdlib calls use the thetos hooks for that vector. Parsing
and rendering are outside the timed loops.

| Operation | Arch | `std/jsonutils` with `JsonNode` (µs) | `thetos/jsonutils` with `JsonValue` (µs) |
| --- | --- | ---: | ---: |
| Encode the Nim object | arm64 | 71.3 | 209.0 |
| Encode the Nim object | amd64 | 55.83 | 193.44 |
| Decode into the Nim object | arm64 | 74.0 | 206.7 |
| Decode into the Nim object | amd64 | 65.14 | 181.70 |

`thetos/jsonutils` delegates typed conversions to the stdlib engine for
its options and hooks. Each call also converts the tree between
`JsonNode` and `JsonValue`.

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

### Direct text I/O

The initial port used an intermediate `JsonNode` tree to parse and render
`JsonValue`. Sampling on macOS showed time spent converting and traversing
that tree. Direct text I/O reduced parse time by about 1.7× on both
machines. Rendering dropped from 254.8 to 84.1 µs on arm64 and from
229.89 to 81.89 µs on amd64.

| Operation | Arch | Initial port (`3d2041c`) (µs) | Direct text I/O (`d0a1254`) (µs) |
| --- | --- | ---: | ---: |
| Parse text | arm64 | 395.8 | 236.2 |
| Parse text | amd64 | 399.73 | 236.48 |
| Render to `string` | arm64 | 254.8 | 84.1 |
| Render to `string` | amd64 | 229.89 | 81.89 |
| Encode the Nim object | arm64 | 210.7 | 209.0 |
| Encode the Nim object | amd64 | 196.35 | 193.44 |
| Decode into the Nim object | arm64 | 200.0 | 206.7 |
| Decode into the Nim object | amd64 | 180.33 | 181.70 |

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

Run the same program against the initial port in a temporary directory.

```sh
baseline=$(mktemp -d)
git archive 3d2041c config.nims src benchmarks/config.nims | tar -x -C "$baseline"
cp benchmarks/bjsonutils.nim "$baseline/benchmarks/"
(cd "$baseline" && nim r -d:release benchmarks/bjsonutils.nim)
```

Sample the persistent parsing workload on macOS.

```sh
nim c -d:release --debugger:native -o:/tmp/bjsonutils benchmarks/bjsonutils.nim
/tmp/bjsonutils parse 30000 &
sample "$!" 2 1 -file /tmp/json-parse-sample.txt
```
