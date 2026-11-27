# JSON benchmarks on amd64: `JsonNode` vs `JsonValue`

`std/json` uses a mutable `JsonNode` tree. Thetos' `JsonValue` uses
`TrieMap` for objects, `FlexVec` for arrays, and `ImmStr` for keys and
strings. Edits preserve previous versions by sharing unchanged nodes.
[arm64 results on macOS](benchmark_jsonutils_arm64.md)

## Setup

* AMD Ryzen 7 8745HS, FreeBSD 15.1-RELEASE-p1, Nim 2.2.12, Clang 19.1.7.
  Measured on 2026-11-27.
* Benchmarks ran sequentially on logical CPU 2 with `cpuset -l 2`.
  The repository configuration uses `--mm:atomicArc --threads:on`.
* Each timing is the median of three program invocations. Each invocation
  reports its fastest of seven runs per operation.
* `benchmarks/bjsonutils.nim` was compiled with `-d:release --cc:clang`.
  Each timed run performs 500 operations on a 31,129-byte document
  containing 256 records with booleans, numbers, escaped text, and arrays.
* The direct JSON implementation is from `d0a1254`. Its historical
  baseline is `3d2041c`. Both builds use the same benchmark program.

## Summary

| Workload | Result on this machine |
|---|---|
| Parse text into a tree | `JsonNode` took 240.16 µs and `JsonValue` took 236.48 µs. |
| Render compact JSON | `JsonNode` took 116.30 µs and `JsonValue` took 81.89 µs. |
| Convert between a typed Nim value and a JSON tree | Both `JsonValue` conversions pass through the stdlib conversion engine and also convert the JSON tree. |
| Keep 501 document versions | Deep-copying `JsonNode` held 130.12 MiB of additional memory. Persistent edits held 1.02 MiB. |

## Results

### Text I/O

Both parsers read the same text. Rendering starts with an already parsed
tree and produces compact JSON.

| Operation | `JsonNode` | `JsonValue` |
| --- | ---: | ---: |
| Parse text | 240.16 µs | 236.48 µs |
| Render to `string` | 116.30 µs | 81.89 µs |

### Typed conversions

Both cases convert the same Nim object with a `FlexVec` of 256 records.
The stdlib case uses the thetos hooks for that vector. Text I/O is outside
the timed loops.

| Operation | `std/jsonutils` with `JsonNode` | `thetos/jsonutils` with `JsonValue` |
| --- | ---: | ---: |
| Encode the Nim object | 55.83 µs | 193.44 µs |
| Decode into the Nim object | 65.14 µs | 181.70 µs |

### Keeping every version

The benchmark changes one row's `id` per edit, using a fixed sequence of
row indexes. The stdlib case deep-copies the tree before each edit. The
thetos case updates the row, array, and root with `put`.

| Metric | Deep copy + edit `JsonNode` | Persistent edit of `JsonValue` |
| --- | ---: | ---: |
| Time per edit, including history management | 110.36 µs | 0.53 µs |
| Additional memory held by 500 retained edits | 130.12 MiB | 1.02 MiB |

Time includes building and releasing the history. Memory is the change in
Nim's `getOccupiedMem()` while all versions are live, with the original
tree already allocated.

### Direct text I/O

The initial port parsed and rendered through a temporary `JsonNode` tree.
The direct implementation fills the persistent tree with the stdlib
tokenizer and renders it directly into a string.

| Operation on `JsonValue` | Initial port (`3d2041c`) | Direct text I/O (`d0a1254`) |
| --- | ---: | ---: |
| Parse text | 399.73 µs | 236.48 µs |
| Render to `string` | 229.89 µs | 81.89 µs |
| Encode the Nim object | 196.35 µs | 193.44 µs |
| Decode into the Nim object | 180.33 µs | 181.70 µs |

## Reproducing

```sh
nim c -d:release --cc:clang --skipUserCfg:on -o:/tmp/bjsonutils benchmarks/bjsonutils.nim
cpuset -l 2 /tmp/bjsonutils
```

To reproduce the initial port measurements, copy the same benchmark
program into a checkout of `3d2041c` before compiling.
