# String benchmarks on amd64: `string` vs `ImmStr` vs `FlexStr`

Nim's `string` is a mutable flat buffer. `ImmStr` shares an immutable
flat buffer and caches its hash. `FlexStr` stores bytes in a persistent
tree and shares unchanged nodes during edits.
[arm64 results on macOS](benchmark_std_string_arm64.md)

## Setup

* AMD Ryzen 7 8745HS, FreeBSD 15.1-RELEASE-p1, Nim 2.2.12, Clang 19.1.7.
  Measured on 2026-11-27.
* Benchmarks ran sequentially on logical CPU 2 with `cpuset -l 2`.
  The repository configuration uses `--mm:atomicArc --threads:on`.
* Each timing is the median of three program invocations. Each invocation
  reports its fastest of seven runs per operation.
* `benchmarks/bstring.nim` was compiled with `-d:danger --cc:clang`.
  The current implementation (`d0a1254`) uses 128-byte leaves for `FlexStr`.
  The baseline (`e8a41bc`) uses 32-byte leaves. The text contains ASCII
  and multibyte UTF-8.

## Summary

| Workload | Result on this machine |
|---|---|
| Copy or hash a 64 KiB value | `ImmStr` took 3.2 ns to copy and 1.1 ns to return a cached hash. |
| Read a random byte in 64 KiB | `string` took 1.1 ns and `FlexStr` took 3.3 ns. |
| Insert 8 bytes into 1 MiB while retaining the original | `FlexStr` took 3.39 µs and `string` took 325.1 µs. |
| Keep 1,001 versions of 64 KiB | `FlexStr` used 1.3 MiB and `string` used 66.5 MiB. |

## Results with 128-byte leaves

### Copying

A copy overwrites one slot in a fixed-size array.

| Size | `string` | `ImmStr` | `FlexStr` |
| --- | ---: | ---: | ---: |
| 16 B | 2.9 ns | 3.2 ns | 5.3 ns |
| 1 KiB | 17.5 ns | 3.2 ns | 7.1 ns |
| 64 KiB | 925.2 ns | 3.2 ns | 7.1 ns |

### Copies inside thetos

| Operation, 1 KiB values | `string` | `ImmStr` |
| --- | ---: | ---: |
| `TrieMap.put` on a shared 10,000-entry map | 779.6 ns | 399.2 ns |
| `Atom.load` | 28.6 ns | 10.6 ns |

### Hashing

The benchmark rotates eight equal values held in separate allocations.
The `ImmStr` result uses hashes cached on their first call.

| Size | `string` | `ImmStr` | `FlexStr` |
| --- | ---: | ---: | ---: |
| 16 B | 2.4 ns | 1.1 ns | 26.7 ns |
| 1 KiB | 54.4 ns | 1.1 ns | 124.9 ns |
| 64 KiB | 3.13 µs | 1.1 ns | 6.39 µs |

### Equality

The benchmark compares equal values held in separate allocations.

| Size | `string` | `ImmStr` | `FlexStr` |
| --- | ---: | ---: | ---: |
| 16 B | 3.1 ns | 4.2 ns | 25.4 ns |
| 1 KiB | 19.7 ns | 18.6 ns | 71.3 ns |
| 64 KiB | 1.06 µs | 1.06 µs | 3.58 µs |

### Reading 64 KiB

| Operation | `string` | `ImmStr` | `FlexStr` |
| --- | ---: | ---: | ---: |
| Random byte lookup | 1.1 ns | 1.8 ns | 3.3 ns |
| Sequential iteration (per byte) | 0.4 ns | 0.3 ns | 0.3 ns |

### Building and editing

Byte-at-a-time appends build a 64 KiB value. Inserts retain the original
and use a random byte offset. Slices select exactly half of the input.

| Operation | `string` | `ImmStr` | `FlexStr` |
| --- | ---: | ---: | ---: |
| Append one byte | 2.5 ns | n/a | 5.7 ns |
| Concatenate two 64 KiB values | 1.91 µs | 1.88 µs | 1.42 µs |
| Concatenate two 1 MiB values | 35.2 µs | 35.0 µs | 2.47 µs |
| Insert 8 bytes into 64 KiB, retaining the original | 20.3 µs | n/a | 1.88 µs |
| Insert 8 bytes into 1 MiB, retaining the original | 325.1 µs | n/a | 3.39 µs |
| Slice half of a 1 MiB value | 236.3 µs | 9.15 µs | 877.7 ns |

### Keeping every version

The benchmark replaces one byte 1,000 times in a 64 KiB document.
The retained-memory measurement includes the initial value and all edits.

| Metric | `seq[string]` | `seq[FlexStr]` |
| --- | ---: | ---: |
| Time per edit | 4.93 µs | 385.3 ns |
| Memory held by 1,001 versions | 66.5 MiB | 1.3 MiB |

### Converting

| Operation, 64 KiB | Time |
| --- | ---: |
| `toImmStr(string)` | 1.98 µs |
| `$ImmStr` | 1.51 µs |
| `toFlexStr(string)` | 100.9 µs |
| `$FlexStr` | 3.77 µs |

## FlexStr leaf size

| Operation, 64 KiB | 32-byte leaves | 128-byte leaves |
| --- | ---: | ---: |
| Build from `string` | 126.2 µs | 100.9 µs |
| Convert back to `string` | 6.63 µs | 3.77 µs |
| Compare equal values | 9.45 µs | 3.58 µs |
| Random byte lookup | 3.6 ns | 3.3 ns |
| Insert 8 bytes | 2.41 µs | 1.88 µs |
| Replace one byte and retain each version | 525.7 ns | 385.3 ns |

## Reproducing

```sh
nim c -d:danger --cc:clang --skipUserCfg:on -o:/tmp/bstring benchmarks/bstring.nim
cpuset -l 2 /tmp/bstring
```

The baseline can be built with the same command from a checkout of commit
`e8a41bc`.
