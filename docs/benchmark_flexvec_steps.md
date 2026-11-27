# FlexVec performance by step

Each column is the same benchmark source built against one commit of
the `perf-improv` branch, so every column measures the same work.
Times are ns per operation (µs where marked), the best of two runs of
7 samples each, built with `-d:danger` and the default `--mm:atomicArc`.
`change` compares the last column with the base. `FlexDeque` rows
(`deque:`) exist only in column 5, so their `change` compares them
with the `FlexVec` row for the same operation in that column.

| column | commit | change |
|---|---|---|
| base | `90786af` | before this branch |
| 1 | `dd24052` | 1: leaf cursor in `items` and `==` |
| 2 | `f6b5a8b` | 2: hand the left vector's nodes to concatenation |
| 3a | `c5c49ed` | 3a: merge levels in stack buffers |
| 3b | `568d64f` | 3b: skip zeroing inner nodes |
| 3c | `9e89102` | 3c: pass known child sizes up through rebalancing |
| 4 | `6621acc` | 4: head leaf for `pushFront` and `drop`, in `FlexVec` |
| 5 | `54d7a35` | 5: head leaf moved to a separate `FlexDeque` type |

Machines: arm64 is an Apple M3 Pro (macOS). amd64 rows are filled in
from the same scripts on an x86-64 machine; – marks a value not
measured there yet.

Sources: `benchmarks/bflexvec.nim` and the `FlexStr` rows of
`benchmarks/bstring.nim`:

```
nim r -d:danger benchmarks/bflexvec.nim
nim r -d:danger benchmarks/bstring.nim
```

## Summary

`FlexVec` before this branch (base) and after it (column 5), in ns:

| operation | arch | base | final | change |
|---|---|---:|---:|---:|
| `==`, relaxed vs relaxed, 100k | arm64 | 9.3 | 0.5 | -95% |
| `==`, relaxed vs relaxed, 100k | amd64 | – | – | – |
| `items`, relaxed, 100k | arm64 | 0.4 | 0.2 | -50% |
| `items`, relaxed, 100k | amd64 | – | – | – |
| `a & b`, 100k + 100k | arm64 | 1587.0 | 858.2 | -46% |
| `a & b`, 100k + 100k | amd64 | – | – | – |
| `v.add(w)` of 1000, unique | arm64 | 1635.3 | 740.8 | -55% |
| `v.add(w)` of 1000, unique | amd64 | – | – | – |
| `insert` in the middle, 100k | arm64 | 1849.3 | 1004.7 | -46% |
| `insert` in the middle, 100k | amd64 | – | – | – |
| `erase` in the middle, 100k | arm64 | 1746.9 | 1011.7 | -42% |
| `erase` in the middle, 100k | amd64 | – | – | – |
| `pushFront`, 100k | arm64 | 1214.2 | 613.4 | -49% |
| `pushFront`, 100k | amd64 | – | – | – |
| `v[i] = x`, 100k | arm64 | 15.2 | 10.9 | -28% |
| `v[i] = x`, 100k | amd64 | – | – | – |
| FlexStr `&`, 1 MiB each | arm64 | 2390.8 | 1180.8 | -51% |
| FlexStr `&`, 1 MiB each | amd64 | – | – | – |
| FlexStr `insert`, 1 MiB | arm64 | 2592.9 | 1632.9 | -37% |
| FlexStr `insert`, 1 MiB | amd64 | – | – | – |
| FlexStr `s[a .. b]`, 1 MiB | arm64 | 719.2 | 578.3 | -20% |
| FlexStr `s[a .. b]`, 1 MiB | amd64 | – | – | – |
| FlexStr copy, 16 B | arm64 | 10.5 | 8.6 | -18% |
| FlexStr copy, 16 B | amd64 | – | – | – |
| FlexStr `==`, 16 B | arm64 | 7.2 | 7.1 | -1% |
| FlexStr `==`, 16 B | amd64 | – | – | – |

`FlexDeque` against `FlexVec`, both at column 5, in ns:

| operation | arch | FlexVec | FlexDeque | change |
|---|---|---:|---:|---:|
| `pushFront`, 100k | arm64 | 613.4 | 34.1 | -94% |
| `pushFront`, 100k | amd64 | – | – | – |
| `pushFront` from empty to 100k | arm64 | 571.9 | 86.0 | -85% |
| `pushFront` from empty to 100k | amd64 | – | – | – |
| repeated `drop(1)`, 100k | arm64 | 243.2 | 62.4 | -74% |
| repeated `drop(1)`, 100k | amd64 | – | – | – |
| `v[i] = x`, 100k | arm64 | 10.9 | 10.9 | +0% |
| `v[i] = x`, 100k | amd64 | – | – | – |
| `a & b`, 100k + 100k | arm64 | 858.2 | 864.7 | +1% |
| `a & b`, 100k + 100k | amd64 | – | – | – |
| `insert` in the middle, 100k | arm64 | 1004.7 | 1055.0 | +5% |
| `insert` in the middle, 100k | amd64 | – | – | – |

Where the gains came from, by column:

- **1**: `==` and `items` walk leaves with a cursor instead of indexing
  each element from the root; `==` drops from several ns per element to
  under one.
- **2**: appending a vector that the caller owns alone edits its right
  edge in place instead of copying it.
- **3a**: concatenation collects each level's nodes in stack buffers
  instead of growing `seq`s. This is the largest single gain for
  concatenation, `insert`, `erase`, `pushFront` and FlexStr editing.
- **3b, 3c**: inner nodes are no longer zeroed, and rebalancing passes
  known child sizes up instead of walking down to recompute them.
- **4, 5**: a head leaf makes `pushFront` and repeated small `drop`s
  amortized O(1). Inside `FlexVec` (column 4) it slowed short FlexStr
  copies, hashing and comparison, so column 5 moved it to `FlexDeque`
  and returned `FlexVec` to its column 3c code.

Reusing uniquely owned nodes in place during concatenation (the
paper's section 6.4) was tried on paper and not built: removing every
atomic count operation saved only 5-16%, which bounds its benefit.

The `v[i]` indexing rows change between columns although no step
touched indexing; they follow code layout in each benchmark binary.
Isolated side by side, column 5 `FlexVec` indexes as fast as column
3c, and `FlexDeque` about 0.3 ns slower than `FlexVec`.

## FlexVec

### Iteration and comparison

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| items, regular, 1000 | arm64 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | +0% |
| items, regular, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| items, relaxed, 1000 | arm64 | 0.3 | 0.2 | 0.2 | 0.2 | 0.2 | 0.3 | 0.2 | 0.2 | -33% |
| items, relaxed, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| == regular vs relaxed, 1000 | arm64 | 5.9 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | -93% |
| == regular vs relaxed, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| == relaxed vs relaxed, 1000 | arm64 | 5.8 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | -93% |
| == relaxed vs relaxed, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| hash, relaxed, 1000 | arm64 | 1.4 | 1.4 | 1.4 | 1.4 | 1.4 | 1.5 | 1.5 | 1.4 | +0% |
| hash, relaxed, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| items, regular, 100000 | arm64 | 0.3 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | -33% |
| items, regular, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| items, relaxed, 100000 | arm64 | 0.4 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | -50% |
| items, relaxed, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| == regular vs relaxed, 100000 | arm64 | 9.1 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | -95% |
| == regular vs relaxed, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| == relaxed vs relaxed, 100000 | arm64 | 9.3 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | -95% |
| == relaxed vs relaxed, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| hash, relaxed, 100000 | arm64 | 1.4 | 1.4 | 1.4 | 1.4 | 1.4 | 1.5 | 1.5 | 1.4 | +0% |
| hash, relaxed, 100000 | amd64 | – | – | – | – | – | – | – | – | – |

### Indexing

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| v[i] random, regular, 1000 | arm64 | 4.3 | 3.4 | 3.5 | 3.4 | 3.5 | 2.9 | 2.9 | 3.5 | -19% |
| v[i] random, regular, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] random, relaxed, 1000 | arm64 | 11.1 | 7.5 | 7.8 | 7.6 | 7.6 | 6.7 | 6.5 | 7.9 | -29% |
| v[i] random, relaxed, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] sequential, regular, 1000 | arm64 | 4.4 | 4.3 | 3.4 | 3.4 | 3.4 | 2.9 | 2.9 | 3.6 | -18% |
| v[i] sequential, regular, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] = x random, unique, 1000 | arm64 | 9.0 | 9.0 | 9.9 | 9.7 | 8.7 | 8.4 | 9.0 | 8.3 | -8% |
| v[i] = x random, unique, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] random, regular, 100000 | arm64 | 6.8 | 5.0 | 5.0 | 5.0 | 4.9 | 4.5 | 4.5 | 5.1 | -25% |
| v[i] random, regular, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] random, relaxed, 100000 | arm64 | 14.7 | 9.2 | 9.8 | 9.5 | 9.5 | 8.3 | 8.4 | 9.1 | -38% |
| v[i] random, relaxed, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] sequential, regular, 100000 | arm64 | 6.8 | 5.9 | 5.0 | 5.0 | 5.0 | 4.5 | 4.5 | 5.1 | -25% |
| v[i] sequential, regular, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| v[i] = x random, unique, 100000 | arm64 | 15.2 | 15.2 | 17.5 | 17.3 | 11.6 | 11.3 | 11.7 | 10.9 | -28% |
| v[i] = x random, unique, 100000 | amd64 | – | – | – | – | – | – | – | – | – |

### Concatenation

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| a & b, 1000 + 1000 | arm64 | 2082.5 | 2087.8 | 2135.2 | 1759.2 | 1717.8 | 1647.6 | 1694.8 | 1639.7 | -21% |
| a & b, 1000 + 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| unique v.add(w) of 50, until 1000 | arm64 | 451.7 | 445.4 | 387.9 | 252.6 | 252.8 | 242.7 | 251.2 | 246.8 | -45% |
| unique v.add(w) of 50, until 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| unique v.add(w) of 1000, until 10000 | arm64 | 999.8 | 980.7 | 871.1 | 534.4 | 554.0 | 486.9 | 491.1 | 491.0 | -51% |
| unique v.add(w) of 1000, until 10000 | amd64 | – | – | – | – | – | – | – | – | – |
| strings: s & s, 1000 | arm64 | 922.6 | 903.3 | 906.5 | 633.5 | 627.1 | 552.8 | 549.9 | 542.3 | -41% |
| strings: s & s, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| a & b, 100000 + 100000 | arm64 | 1587.0 | 1547.0 | 1527.7 | 1008.1 | 955.0 | 858.2 | 865.9 | 858.2 | -46% |
| a & b, 100000 + 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| unique v.add(w) of 50, until 100000 | arm64 | 945.7 | 928.4 | 780.6 | 495.9 | 445.8 | 448.7 | 455.9 | 449.3 | -52% |
| unique v.add(w) of 50, until 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| unique v.add(w) of 1000, until 1000000 | arm64 | 1635.3 | 1609.5 | 1359.8 | 868.7 | 834.7 | 738.1 | 743.7 | 740.8 | -55% |
| unique v.add(w) of 1000, until 1000000 | amd64 | – | – | – | – | – | – | – | – | – |
| strings: s & s, 100000 | arm64 | 1617.6 | 1591.1 | 1597.9 | 1008.0 | 946.9 | 891.4 | 926.5 | 922.1 | -43% |
| strings: s & s, 100000 | amd64 | – | – | – | – | – | – | – | – | – |

### Edits in the middle and at the front

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| insert middle, persistent, 1000 | arm64 | 775.9 | 771.3 | 706.8 | 539.7 | 490.8 | 473.4 | 491.6 | 483.9 | -38% |
| insert middle, persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| erase middle, persistent, 1000 | arm64 | 823.0 | 803.2 | 744.4 | 562.0 | 546.0 | 506.5 | 531.4 | 507.8 | -38% |
| erase middle, persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| insert random, unique, into 1000 | arm64 | 1506.5 | 1484.2 | 1423.9 | 1149.8 | 1119.3 | 1104.0 | 1139.0 | 1084.9 | -28% |
| insert random, unique, into 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| drop(1), persistent, 1000 | arm64 | 197.1 | 198.1 | 198.0 | 202.5 | 196.5 | 190.8 | 193.4 | 186.5 | -5% |
| drop(1), persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| drop(1) repeated, unique, half of 1000 | arm64 | 162.2 | 161.0 | 162.9 | 162.3 | 158.7 | 151.2 | 61.3 | 151.5 | -7% |
| drop(1) repeated, unique, half of 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| pushFront, persistent, 1000 | arm64 | 493.9 | 483.5 | 488.0 | 302.8 | 297.9 | 277.5 | 36.0 | 283.9 | -43% |
| pushFront, persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| pushFront repeated, unique, from empty to 1000 | arm64 | 381.3 | 380.3 | 371.9 | 245.2 | 241.8 | 235.5 | 74.1 | 237.5 | -38% |
| pushFront repeated, unique, from empty to 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| insert middle, persistent, 100000 | arm64 | 1849.3 | 1828.7 | 1653.8 | 1171.5 | 1101.4 | 1006.4 | 1040.3 | 1004.7 | -46% |
| insert middle, persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| erase middle, persistent, 100000 | arm64 | 1746.9 | 1729.9 | 1558.1 | 1104.7 | 1052.8 | 1012.2 | 1039.2 | 1011.7 | -42% |
| erase middle, persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| insert random, unique, into 100000 | arm64 | 2523.8 | 2504.6 | 2351.6 | 1854.4 | 1833.9 | 1785.1 | 1793.5 | 1766.5 | -30% |
| insert random, unique, into 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| drop(1), persistent, 100000 | arm64 | 387.5 | 401.8 | 399.0 | 399.1 | 380.1 | 369.5 | 373.3 | 369.0 | -5% |
| drop(1), persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| drop(1) repeated, unique, half of 100000 | arm64 | 263.6 | 266.7 | 264.6 | 261.9 | 251.3 | 243.4 | 64.8 | 243.2 | -8% |
| drop(1) repeated, unique, half of 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| pushFront, persistent, 100000 | arm64 | 1214.2 | 1205.1 | 1203.1 | 678.8 | 679.1 | 591.9 | 38.7 | 613.4 | -49% |
| pushFront, persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| pushFront repeated, unique, from empty to 100000 | arm64 | 1055.0 | 1040.6 | 1038.1 | 618.5 | 602.5 | 563.4 | 88.2 | 571.9 | -46% |
| pushFront repeated, unique, from empty to 100000 | amd64 | – | – | – | – | – | – | – | – | – |

### FlexDeque: the same operations with a head leaf

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| deque: v[i] random, regular, 1000 | arm64 | – | – | – | – | – | – | – | 3.8 | +9% vs FlexVec |
| deque: v[i] random, regular, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: v[i] = x random, unique, 1000 | arm64 | – | – | – | – | – | – | – | 8.4 | +1% vs FlexVec |
| deque: v[i] = x random, unique, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: a & b, 1000 + 1000 | arm64 | – | – | – | – | – | – | – | 1272.5 | -22% vs FlexVec |
| deque: a & b, 1000 + 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: insert middle, persistent, 1000 | arm64 | – | – | – | – | – | – | – | 498.6 | +3% vs FlexVec |
| deque: insert middle, persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: erase middle, persistent, 1000 | arm64 | – | – | – | – | – | – | – | 528.2 | +4% vs FlexVec |
| deque: erase middle, persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: drop(1), persistent, 1000 | arm64 | – | – | – | – | – | – | – | 198.7 | +7% vs FlexVec |
| deque: drop(1), persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: drop(1) repeated, unique, half of 1000 | arm64 | – | – | – | – | – | – | – | 61.5 | -59% vs FlexVec |
| deque: drop(1) repeated, unique, half of 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: pushFront, persistent, 1000 | arm64 | – | – | – | – | – | – | – | 34.0 | -88% vs FlexVec |
| deque: pushFront, persistent, 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: pushFront repeated, unique, from empty to 1000 | arm64 | – | – | – | – | – | – | – | 75.0 | -68% vs FlexVec |
| deque: pushFront repeated, unique, from empty to 1000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: v[i] random, regular, 100000 | arm64 | – | – | – | – | – | – | – | 5.4 | +6% vs FlexVec |
| deque: v[i] random, regular, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: v[i] = x random, unique, 100000 | arm64 | – | – | – | – | – | – | – | 10.9 | +0% vs FlexVec |
| deque: v[i] = x random, unique, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: a & b, 100000 + 100000 | arm64 | – | – | – | – | – | – | – | 864.7 | +1% vs FlexVec |
| deque: a & b, 100000 + 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: insert middle, persistent, 100000 | arm64 | – | – | – | – | – | – | – | 1055.0 | +5% vs FlexVec |
| deque: insert middle, persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: erase middle, persistent, 100000 | arm64 | – | – | – | – | – | – | – | 1042.4 | +3% vs FlexVec |
| deque: erase middle, persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: drop(1), persistent, 100000 | arm64 | – | – | – | – | – | – | – | 378.2 | +2% vs FlexVec |
| deque: drop(1), persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: drop(1) repeated, unique, half of 100000 | arm64 | – | – | – | – | – | – | – | 62.4 | -74% vs FlexVec |
| deque: drop(1) repeated, unique, half of 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: pushFront, persistent, 100000 | arm64 | – | – | – | – | – | – | – | 34.1 | -94% vs FlexVec |
| deque: pushFront, persistent, 100000 | amd64 | – | – | – | – | – | – | – | – | – |
| deque: pushFront repeated, unique, from empty to 100000 | arm64 | – | – | – | – | – | – | – | 86.0 | -85% vs FlexVec |
| deque: pushFront repeated, unique, from empty to 100000 | amd64 | – | – | – | – | – | – | – | – | – |

## FlexStr

### Copying one value (into an array slot)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr copy, 16 B | arm64 | 10.5 | 11.2 | 10.6 | 8.7 | 8.6 | 8.6 | 10.0 | 8.6 | -18% |
| FlexStr copy, 16 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr copy, 1024 B | arm64 | 11.0 | 11.0 | 10.1 | 8.4 | 8.4 | 9.0 | 11.6 | 9.0 | -18% |
| FlexStr copy, 1024 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr copy, 65536 B | arm64 | 10.3 | 11.0 | 10.9 | 9.0 | 9.0 | 8.8 | 10.9 | 8.4 | -18% |
| FlexStr copy, 65536 B | amd64 | – | – | – | – | – | – | – | – | – |

### Hashing (8 equal values in separate allocations, rotated)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr hash, 16 B | arm64 | 23.5 | 21.9 | 23.7 | 21.6 | 22.5 | 21.6 | 25.1 | 22.3 | -5% |
| FlexStr hash, 16 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr hash, 1024 B | arm64 | 92.5 | 93.0 | 91.8 | 92.2 | 92.0 | 92.4 | 95.9 | 92.3 | -0% |
| FlexStr hash, 1024 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr hash, 65536 B | arm64 | 5486.3 | 5503.5 | 5460.4 | 5476.0 | 5469.4 | 5511.4 | 5492.7 | 5464.4 | -0% |
| FlexStr hash, 65536 B | amd64 | – | – | – | – | – | – | – | – | – |

### Equality of equal values in separate allocations

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr ==, 16 B | arm64 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 8.6 | 7.1 | -1% |
| FlexStr ==, 16 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr ==, 1024 B | arm64 | 45.1 | 45.3 | 45.0 | 45.2 | 43.5 | 45.1 | 44.3 | 45.0 | -0% |
| FlexStr ==, 1024 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr ==, 65536 B | arm64 | 2997.9 | 2991.4 | 2983.4 | 2998.0 | 3002.5 | 2985.1 | 3048.2 | 3018.0 | +1% |
| FlexStr ==, 65536 B | amd64 | – | – | – | – | – | – | – | – | – |

### Random byte access, 64 KiB

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr s[i] | arm64 | 4.5 | 4.5 | 4.5 | 4.5 | 4.0 | 4.0 | 4.0 | 3.7 | -18% |
| FlexStr s[i] | amd64 | – | – | – | – | – | – | – | – | – |

### Iterating every byte, 64 KiB (per byte)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr items | arm64 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | +0% |
| FlexStr items | amd64 | – | – | – | – | – | – | – | – | – |

### Appending 64 KiB one byte at a time (per byte)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr add | arm64 | 6.2 | 6.2 | 6.2 | 6.2 | 4.7 | 4.6 | 6.2 | 4.7 | -24% |
| FlexStr add | amd64 | – | – | – | – | – | – | – | – | – |

### Concatenating two equal-size values

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr &, 65536 B each | arm64 | 1555.1 | 1551.5 | 1534.5 | 824.1 | 877.9 | 726.7 | 740.6 | 677.6 | -56% |
| FlexStr &, 65536 B each | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr &, 1048576 B each | arm64 | 2390.8 | 2334.2 | 2357.5 | 1292.5 | 1326.7 | 1170.8 | 1178.3 | 1180.8 | -51% |
| FlexStr &, 1048576 B each | amd64 | – | – | – | – | – | – | – | – | – |

### Inserting 8 bytes at a random offset (new version each time)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr insert, 65536 B | arm64 | 1852.2 | 1849.9 | 1786.2 | 1242.9 | 1160.0 | 1145.0 | 1189.1 | 1109.6 | -40% |
| FlexStr insert, 65536 B | amd64 | – | – | – | – | – | – | – | – | – |
| FlexStr insert, 1048576 B | arm64 | 2592.9 | 2589.2 | 2546.9 | 1798.8 | 1720.0 | 1618.3 | 1670.4 | 1632.9 | -37% |
| FlexStr insert, 1048576 B | amd64 | – | – | – | – | – | – | – | – | – |

### Slicing half of a 1 MiB value

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr s[a .. b] | arm64 | 719.2 | 720.0 | 725.4 | 647.5 | 620.2 | 611.0 | 589.2 | 578.3 | -20% |
| FlexStr s[a .. b] | amd64 | – | – | – | – | – | – | – | – | – |

### Editing a 64 KiB document 1000 times, keeping every version

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| seq[FlexStr] history (per edit) | arm64 | 247.3 | 230.6 | 227.9 | 227.7 | 216.8 | 215.8 | 224.8 | 217.2 | -12% |
| seq[FlexStr] history (per edit) | amd64 | – | – | – | – | – | – | – | – | – |

### Converting from and to string, 64 KiB

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| toFlexStr(string) | arm64 | 64980.1 | 64486.0 | 63961.9 | 64156.7 | 64007.3 | 62862.2 | 62593.3 | 63698.5 | -2% |
| toFlexStr(string) | amd64 | – | – | – | – | – | – | – | – | – |
| $FlexStr | arm64 | 3181.2 | 3339.1 | 3393.0 | 3286.6 | 3197.6 | 3377.3 | 3412.1 | 3333.5 | +5% |
| $FlexStr | amd64 | – | – | – | – | – | – | – | – | – |
