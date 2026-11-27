# JSON benchmarks on arm64: `JsonNode` vs `JsonValue`

This compares the stdlib's mutable JSON tree with thetos' persistent JSON
tree across text I/O, typed conversions, and edits that retain previous
versions.
[amd64 results on FreeBSD](benchmark_jsonutils_amd64.md)

* **`JsonNode`** from `std/json` is a mutable tree with ordered object
  members and arrays backed by sequences. Assigning a node shares its
  reference, and `copy` recursively duplicates the tree.
* **`JsonValue`** from `thetos/jsonutils` uses `TrieMap` for objects,
  `FlexVec` for arrays, and `ImmStr` for keys and strings. Copies share
  storage, and edits copy the paths they change. Object member order is
  unspecified.

## Setup

* Apple M3 Pro, macOS 15.7.9, Nim 2.2.12. Measured on 2026-11-27.
* `-d:release` with the repository configuration
  (`--mm:atomicArc --threads:on`).
* One 31,129-byte document with 256 records. Each record has an integer,
  a boolean, a float, a string with escaped quotes and multibyte UTF-8,
  and an array of strings.
* Each timing is the median of three program invocations. Each invocation
  reports the fastest of seven runs of 500 operations. Timings are per
  operation. Direct comparisons use both APIs in the same executable.

## Summary

| Workload | Result on this document |
|---|---|
| Parse text into a JSON tree | Both representations took about 240 µs. |
| Render a JSON tree as compact text | `JsonValue` took 84.1 µs and `JsonNode` took 126.1 µs. |
| Convert between a typed Nim value and a JSON tree | Direct `std/jsonutils` conversions took about one-third the time of conversions through `JsonValue`. |
| Edit the document and keep all 501 versions | `JsonValue` shared unchanged nodes and held 1.02 MiB of additional memory. Deep-copying a `JsonNode` per edit held 130.12 MiB. |

## Results

### Text I/O

Both parsers read the same text and build a complete tree. Rendering starts
with a parsed tree and produces compact JSON.

| Operation | `JsonNode` | `JsonValue` |
|---|---:|---:|
| Parse text | 245.1 µs | 236.2 µs |
| Render to `string` | 126.1 µs | 84.1 µs |

`parseJsonValue` uses the stdlib tokenizer and writes tokens directly
into persistent containers. The renderer writes to one string buffer and
appends runs of unescaped bytes together.

### Typed conversions

Both sides convert the same Nim object containing a `FlexVec` of 256
records. The stdlib calls use the thetos hooks for that vector. Parsing
and rendering are outside the timed loops.

| Operation | `std/jsonutils` with `JsonNode` | `thetos/jsonutils` with `JsonValue` |
|---|---:|---:|
| Encode the Nim object | 71.3 µs | 209.0 µs |
| Decode into the Nim object | 74.0 µs | 206.7 µs |

`thetos/jsonutils` delegates typed conversions to the stdlib engine for
its options and hooks. Each call also converts the tree between
`JsonNode` and `JsonValue`.

### Keeping every version

The benchmark changes one `id` per edit, cycling through rows in a fixed
order. It retains the initial document and all 500 edits. The stdlib
case calls `JsonNode.copy` before mutating the selected
row, so each snapshot has its own mutable tree. The thetos case updates
the row, the array, and the root object with `put`.

| Operation | Deep copy + edit `JsonNode` | Persistent edit of `JsonValue` |
|---|---:|---:|
| Time per edit, including history management | 110.15 µs | 0.45 µs |
| Additional memory held by the history | 130.12 MiB | 1.02 MiB |

Time includes building and releasing the history. Memory is the change in
Nim's `getOccupiedMem()` measured while all versions are live, with the
original tree already allocated.

### Direct text I/O

The first implementation of `parseJsonValue` and `$` used an intermediate
`JsonNode` tree. macOS `sample` showed work in the conversion and traversal
of that temporary tree. The direct text paths reduced parse time by about
1.7× and render time by about 3.0× on this fixture.

| Operation on `JsonValue` | Initial port (`3d2041c`) | Direct text I/O (`d0a1254`) |
|---|---:|---:|
| Parse text | 395.8 µs | 236.2 µs |
| Render to `string` | 254.8 µs | 84.1 µs |
| Encode the Nim object | 210.7 µs | 209.0 µs |
| Decode into the Nim object | 200.0 µs | 206.7 µs |

## Reproducing

Run the [benchmark program](../benchmarks/bjsonutils.nim) from the repository
root. Selecting an operation runs just that workload once.

```sh
nim r -d:release benchmarks/bjsonutils.nim
nim r -d:release benchmarks/bjsonutils.nim history 500
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
