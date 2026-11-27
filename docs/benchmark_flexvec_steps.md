# FlexVec performance by step

Each column is the same benchmark source built against one commit of
the `perf-improv` branch, so every column measures the same work.
Times are ns per operation (µs where marked), the best of two runs of
7 samples each, built with `-d:danger` and the default `--mm:atomicArc`.
`change` compares the last column with the base. `FlexDeque` rows
(`deque:`) exist only from column 5, so their `change` compares them
with the `FlexVec` row for the same operation in the last column.

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
| 6 | `0d5fd05` | 6: node cloning kept out of line |

Machines: arm64 is an Apple M3 Pro (macOS); amd64 is a 4-vCPU QEMU
virtual machine running FreeBSD 15.1, so its numbers are noisier.
– marks a value that does not exist for that column.

Sources: `benchmarks/bflexvec.nim` and the `FlexStr` rows of
`benchmarks/bstring.nim`:

```
nim r -d:danger benchmarks/bflexvec.nim
nim r -d:danger benchmarks/bstring.nim
```

## Summary

`FlexVec` before this branch (base) and after it (column 6), in ns:

| operation | arch | base | final | change |
|---|---|---:|---:|---:|
| `==`, relaxed vs relaxed, 100k | arm64 | 9.3 | 0.5 | -95% |
| `==`, relaxed vs relaxed, 100k | amd64 | 9.5 | 1.0 | -89% |
| `items`, relaxed, 100k | arm64 | 0.4 | 0.2 | -50% |
| `items`, relaxed, 100k | amd64 | 0.7 | 0.4 | -43% |
| `a & b`, 100k + 100k | arm64 | 1587.0 | 844.3 | -47% |
| `a & b`, 100k + 100k | amd64 | 3490.8 | 2201.7 | -37% |
| `v.add(w)` of 1000, unique | arm64 | 1635.3 | 711.2 | -57% |
| `v.add(w)` of 1000, unique | amd64 | 3797.1 | 1800.5 | -53% |
| `insert` in the middle, 100k | arm64 | 1849.3 | 996.1 | -46% |
| `insert` in the middle, 100k | amd64 | 5144.5 | 2708.2 | -47% |
| `erase` in the middle, 100k | arm64 | 1746.9 | 986.8 | -44% |
| `erase` in the middle, 100k | amd64 | 4850.3 | 2711.6 | -44% |
| `pushFront`, 100k | arm64 | 1214.2 | 607.2 | -50% |
| `pushFront`, 100k | amd64 | 2643.3 | 1483.5 | -44% |
| `v[i] = x`, 100k | arm64 | 15.2 | 10.5 | -31% |
| `v[i] = x`, 100k | amd64 | 18.9 | 17.2 | -9% |
| FlexStr `&`, 1 MiB each | arm64 | 2390.8 | 1193.3 | -50% |
| FlexStr `&`, 1 MiB each | amd64 | 5134.6 | 3521.6 | -31% |
| FlexStr `insert`, 1 MiB | arm64 | 2592.9 | 1633.3 | -37% |
| FlexStr `insert`, 1 MiB | amd64 | 5757.1 | 4107.9 | -29% |
| FlexStr `s[a .. b]`, 1 MiB | arm64 | 719.2 | 612.3 | -15% |
| FlexStr `s[a .. b]`, 1 MiB | amd64 | 1637.7 | 1480.8 | -10% |
| FlexStr copy, 16 B | arm64 | 10.5 | 8.6 | -18% |
| FlexStr copy, 16 B | amd64 | 14.5 | 14.5 | +0% |
| FlexStr `==`, 16 B | arm64 | 7.2 | 6.9 | -4% |
| FlexStr `==`, 16 B | amd64 | 46.6 | 47.5 | +2% |

`FlexDeque` against `FlexVec`, both at column 6, in ns:

| operation | arch | FlexVec | FlexDeque | change |
|---|---|---:|---:|---:|
| `pushFront`, 100k | arm64 | 607.2 | 38.6 | -94% |
| `pushFront`, 100k | amd64 | 1483.5 | 70.6 | -95% |
| `pushFront` from empty to 100k | arm64 | 567.3 | 87.8 | -85% |
| `pushFront` from empty to 100k | amd64 | 1578.1 | 181.0 | -89% |
| repeated `drop(1)`, 100k | arm64 | 237.2 | 63.4 | -73% |
| repeated `drop(1)`, 100k | amd64 | 731.4 | 122.3 | -83% |
| `v[i] = x`, 100k | arm64 | 10.5 | 11.0 | +5% |
| `v[i] = x`, 100k | amd64 | 17.2 | 17.3 | +1% |
| `a & b`, 100k + 100k | arm64 | 844.3 | 866.4 | +3% |
| `a & b`, 100k + 100k | amd64 | 2201.7 | 2271.4 | +3% |
| `insert` in the middle, 100k | arm64 | 996.1 | 1035.7 | +4% |
| `insert` in the middle, 100k | amd64 | 2708.2 | 2816.7 | +4% |

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
- **6**: `clone` is kept out of line. Column 3b changed its body, and
  clang on amd64 then inlined it into the in-place `[]=` path, which
  slowed `v[i] = x` by about a third there; out of line it is faster
  than before the branch on both machines.

Reusing uniquely owned nodes in place during concatenation (the
paper's section 6.4) was tried on paper and not built: removing every
atomic count operation saved only 5-16%, which bounds its benefit.

The `v[i]` indexing rows change between columns although no step
touched indexing; they follow code layout in each benchmark binary.
Isolated side by side on arm64, column 5 `FlexVec` indexes as fast as
column 3c, and `FlexDeque` about 0.3 ns slower than `FlexVec`.

## FlexVec

### Iteration and comparison

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| items, regular, 1000 | arm64 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | +0% |
| items, regular, 1000 | amd64 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | +0% |
| items, relaxed, 1000 | arm64 | 0.3 | 0.2 | 0.2 | 0.2 | 0.2 | 0.3 | 0.2 | 0.2 | 0.2 | -33% |
| items, relaxed, 1000 | amd64 | 0.5 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.4 | -20% |
| == regular vs relaxed, 1000 | arm64 | 5.9 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | -93% |
| == regular vs relaxed, 1000 | amd64 | 6.0 | 0.9 | 0.6 | 0.6 | 0.9 | 0.6 | 1.0 | 0.6 | 0.7 | -88% |
| == relaxed vs relaxed, 1000 | arm64 | 5.8 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | -93% |
| == relaxed vs relaxed, 1000 | amd64 | 6.2 | 0.9 | 0.7 | 0.7 | 0.9 | 0.7 | 1.0 | 0.6 | 0.7 | -89% |
| hash, relaxed, 1000 | arm64 | 1.4 | 1.4 | 1.4 | 1.4 | 1.4 | 1.5 | 1.5 | 1.4 | 1.4 | +0% |
| hash, relaxed, 1000 | amd64 | 2.0 | 1.9 | 1.9 | 1.9 | 1.9 | 1.9 | 1.9 | 1.9 | 1.9 | -5% |
| items, regular, 100000 | arm64 | 0.3 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | -33% |
| items, regular, 100000 | amd64 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | +0% |
| items, relaxed, 100000 | arm64 | 0.4 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 | -50% |
| items, relaxed, 100000 | amd64 | 0.7 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | 0.4 | -43% |
| == regular vs relaxed, 100000 | arm64 | 9.1 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | -95% |
| == regular vs relaxed, 100000 | amd64 | 9.2 | 1.2 | 0.8 | 0.9 | 1.2 | 1.0 | 1.1 | 0.8 | 0.8 | -91% |
| == relaxed vs relaxed, 100000 | arm64 | 9.3 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | -95% |
| == relaxed vs relaxed, 100000 | amd64 | 9.5 | 1.3 | 1.0 | 1.0 | 1.3 | 1.1 | 1.2 | 1.0 | 1.0 | -89% |
| hash, relaxed, 100000 | arm64 | 1.4 | 1.4 | 1.4 | 1.4 | 1.4 | 1.5 | 1.5 | 1.4 | 1.4 | +0% |
| hash, relaxed, 100000 | amd64 | 2.3 | 2.0 | 2.0 | 2.0 | 2.0 | 2.0 | 2.0 | 2.0 | 2.0 | -13% |

### Indexing

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| v[i] random, regular, 1000 | arm64 | 4.3 | 3.4 | 3.5 | 3.4 | 3.5 | 2.9 | 2.9 | 3.5 | 3.5 | -19% |
| v[i] random, regular, 1000 | amd64 | 4.1 | 4.1 | 4.3 | 4.7 | 4.1 | 4.7 | 4.1 | 4.4 | 4.4 | +7% |
| v[i] random, relaxed, 1000 | arm64 | 11.1 | 7.5 | 7.8 | 7.6 | 7.6 | 6.7 | 6.5 | 7.9 | 7.9 | -29% |
| v[i] random, relaxed, 1000 | amd64 | 13.2 | 12.5 | 13.0 | 13.1 | 12.7 | 13.4 | 12.7 | 13.1 | 12.9 | -2% |
| v[i] sequential, regular, 1000 | arm64 | 4.4 | 4.3 | 3.4 | 3.4 | 3.4 | 2.9 | 2.9 | 3.6 | 3.5 | -20% |
| v[i] sequential, regular, 1000 | amd64 | 4.1 | 4.3 | 4.4 | 4.3 | 4.4 | 4.6 | 4.0 | 4.6 | 4.4 | +7% |
| v[i] = x random, unique, 1000 | arm64 | 9.0 | 9.0 | 9.9 | 9.7 | 8.7 | 8.4 | 9.0 | 8.3 | 7.9 | -12% |
| v[i] = x random, unique, 1000 | amd64 | 10.6 | 10.1 | 10.4 | 10.4 | 11.3 | 11.2 | 11.2 | 11.2 | 8.6 | -19% |
| v[i] random, regular, 100000 | arm64 | 6.8 | 5.0 | 5.0 | 5.0 | 4.9 | 4.5 | 4.5 | 5.1 | 4.9 | -28% |
| v[i] random, regular, 100000 | amd64 | 8.1 | 8.9 | 9.0 | 8.3 | 8.9 | 7.6 | 7.9 | 7.9 | 8.2 | +1% |
| v[i] random, relaxed, 100000 | arm64 | 14.7 | 9.2 | 9.8 | 9.5 | 9.5 | 8.3 | 8.4 | 9.1 | 9.6 | -35% |
| v[i] random, relaxed, 100000 | amd64 | 24.6 | 24.6 | 23.7 | 25.2 | 23.8 | 24.0 | 23.8 | 24.1 | 24.0 | -2% |
| v[i] sequential, regular, 100000 | arm64 | 6.8 | 5.9 | 5.0 | 5.0 | 5.0 | 4.5 | 4.5 | 5.1 | 5.0 | -26% |
| v[i] sequential, regular, 100000 | amd64 | 6.3 | 6.6 | 6.9 | 6.5 | 6.7 | 6.8 | 6.2 | 6.5 | 6.4 | +2% |
| v[i] = x random, unique, 100000 | arm64 | 15.2 | 15.2 | 17.5 | 17.3 | 11.6 | 11.3 | 11.7 | 10.9 | 10.5 | -31% |
| v[i] = x random, unique, 100000 | amd64 | 18.9 | 18.9 | 18.7 | 18.6 | 25.1 | 24.8 | 24.5 | 24.3 | 17.2 | -9% |

### Concatenation

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| a & b, 1000 + 1000 | arm64 | 2082.5 | 2087.8 | 2135.2 | 1759.2 | 1717.8 | 1647.6 | 1694.8 | 1639.7 | 1609.4 | -23% |
| a & b, 1000 + 1000 | amd64 | 4608.3 | 5069.3 | 5002.8 | 3865.0 | 3776.1 | 3713.3 | 3772.4 | 3919.5 | 3782.4 | -18% |
| unique v.add(w) of 50, until 1000 | arm64 | 451.7 | 445.4 | 387.9 | 252.6 | 252.8 | 242.7 | 251.2 | 246.8 | 236.7 | -48% |
| unique v.add(w) of 50, until 1000 | amd64 | 1016.1 | 1017.5 | 795.0 | 585.8 | 503.2 | 529.7 | 536.1 | 537.6 | 529.7 | -48% |
| unique v.add(w) of 1000, until 10000 | arm64 | 999.8 | 980.7 | 871.1 | 534.4 | 554.0 | 486.9 | 491.1 | 491.0 | 461.9 | -54% |
| unique v.add(w) of 1000, until 10000 | amd64 | 2272.0 | 2258.6 | 1865.7 | 1307.7 | 1185.9 | 1209.4 | 1201.6 | 1193.1 | 1197.2 | -47% |
| strings: s & s, 1000 | arm64 | 922.6 | 903.3 | 906.5 | 633.5 | 627.1 | 552.8 | 549.9 | 542.3 | 545.8 | -41% |
| strings: s & s, 1000 | amd64 | 2189.5 | 2203.6 | 2191.8 | 1679.0 | 1548.8 | 1543.2 | 1553.1 | 1549.0 | 1535.4 | -30% |
| a & b, 100000 + 100000 | arm64 | 1587.0 | 1547.0 | 1527.7 | 1008.1 | 955.0 | 858.2 | 865.9 | 858.2 | 844.3 | -47% |
| a & b, 100000 + 100000 | amd64 | 3490.8 | 3584.0 | 3403.2 | 2519.5 | 2205.0 | 2193.9 | 2198.2 | 2165.1 | 2201.7 | -37% |
| unique v.add(w) of 50, until 100000 | arm64 | 945.7 | 928.4 | 780.6 | 495.9 | 445.8 | 448.7 | 455.9 | 449.3 | 437.0 | -54% |
| unique v.add(w) of 50, until 100000 | amd64 | 2104.5 | 2139.0 | 1563.8 | 1129.6 | 953.6 | 1011.6 | 996.2 | 995.3 | 984.6 | -53% |
| unique v.add(w) of 1000, until 1000000 | arm64 | 1635.3 | 1609.5 | 1359.8 | 868.7 | 834.7 | 738.1 | 743.7 | 740.8 | 711.2 | -57% |
| unique v.add(w) of 1000, until 1000000 | amd64 | 3797.1 | 3805.5 | 2934.9 | 1981.5 | 1789.5 | 1828.8 | 1824.3 | 1798.2 | 1800.5 | -53% |
| strings: s & s, 100000 | arm64 | 1617.6 | 1591.1 | 1597.9 | 1008.0 | 946.9 | 891.4 | 926.5 | 922.1 | 893.1 | -45% |
| strings: s & s, 100000 | amd64 | 3674.6 | 3638.3 | 3649.4 | 2644.5 | 2353.6 | 2267.2 | 2312.6 | 2259.3 | 2261.7 | -38% |

### Edits in the middle and at the front

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| insert middle, persistent, 1000 | arm64 | 775.9 | 771.3 | 706.8 | 539.7 | 490.8 | 473.4 | 491.6 | 483.9 | 471.4 | -39% |
| insert middle, persistent, 1000 | amd64 | 1901.9 | 1909.7 | 1665.0 | 1390.2 | 1242.4 | 1267.3 | 1267.2 | 1259.2 | 1286.2 | -32% |
| erase middle, persistent, 1000 | arm64 | 823.0 | 803.2 | 744.4 | 562.0 | 546.0 | 506.5 | 531.4 | 507.8 | 497.4 | -40% |
| erase middle, persistent, 1000 | amd64 | 1942.3 | 1959.9 | 1743.4 | 1456.7 | 1290.8 | 1303.8 | 1337.0 | 1318.4 | 1325.1 | -32% |
| insert random, unique, into 1000 | arm64 | 1506.5 | 1484.2 | 1423.9 | 1149.8 | 1119.3 | 1104.0 | 1139.0 | 1084.9 | 1057.4 | -30% |
| insert random, unique, into 1000 | amd64 | 3365.5 | 3418.6 | 3134.1 | 2674.9 | 2350.0 | 2467.5 | 2439.2 | 2499.5 | 2431.6 | -28% |
| drop(1), persistent, 1000 | arm64 | 197.1 | 198.1 | 198.0 | 202.5 | 196.5 | 190.8 | 193.4 | 186.5 | 189.8 | -4% |
| drop(1), persistent, 1000 | amd64 | 568.2 | 569.9 | 578.2 | 570.8 | 538.7 | 541.3 | 546.2 | 564.3 | 547.0 | -4% |
| drop(1) repeated, unique, half of 1000 | arm64 | 162.2 | 161.0 | 162.9 | 162.3 | 158.7 | 151.2 | 61.3 | 151.5 | 149.5 | -8% |
| drop(1) repeated, unique, half of 1000 | amd64 | 484.2 | 484.6 | 494.3 | 494.4 | 445.7 | 432.9 | 115.9 | 451.4 | 474.8 | -2% |
| pushFront, persistent, 1000 | arm64 | 493.9 | 483.5 | 488.0 | 302.8 | 297.9 | 277.5 | 36.0 | 283.9 | 279.2 | -43% |
| pushFront, persistent, 1000 | amd64 | 1021.4 | 1042.2 | 1027.4 | 747.0 | 680.3 | 703.2 | 71.7 | 692.8 | 686.8 | -33% |
| pushFront repeated, unique, from empty to 1000 | arm64 | 381.3 | 380.3 | 371.9 | 245.2 | 241.8 | 235.5 | 74.1 | 237.5 | 231.9 | -39% |
| pushFront repeated, unique, from empty to 1000 | amd64 | 877.7 | 877.8 | 857.8 | 646.0 | 558.0 | 575.8 | 140.7 | 583.8 | 583.7 | -33% |
| insert middle, persistent, 100000 | arm64 | 1849.3 | 1828.7 | 1653.8 | 1171.5 | 1101.4 | 1006.4 | 1040.3 | 1004.7 | 996.1 | -46% |
| insert middle, persistent, 100000 | amd64 | 5144.5 | 4663.6 | 3978.4 | 3069.4 | 2690.5 | 2708.6 | 2659.8 | 2667.5 | 2708.2 | -47% |
| erase middle, persistent, 100000 | arm64 | 1746.9 | 1729.9 | 1558.1 | 1104.7 | 1052.8 | 1012.2 | 1039.2 | 1011.7 | 986.8 | -44% |
| erase middle, persistent, 100000 | amd64 | 4850.3 | 4835.0 | 3669.1 | 3026.0 | 2699.0 | 2691.5 | 2713.5 | 2666.6 | 2711.6 | -44% |
| insert random, unique, into 100000 | arm64 | 2523.8 | 2504.6 | 2351.6 | 1854.4 | 1833.9 | 1785.1 | 1793.5 | 1766.5 | 1787.0 | -29% |
| insert random, unique, into 100000 | amd64 | 6582.4 | 6685.6 | 5957.6 | 4946.9 | 4879.2 | 4578.9 | 4516.2 | 4599.8 | 4821.1 | -27% |
| drop(1), persistent, 100000 | arm64 | 387.5 | 401.8 | 399.0 | 399.1 | 380.1 | 369.5 | 373.3 | 369.0 | 369.4 | -5% |
| drop(1), persistent, 100000 | amd64 | 1190.0 | 1183.4 | 1179.7 | 1176.9 | 1092.2 | 1095.9 | 1096.4 | 1106.1 | 1108.6 | -7% |
| drop(1) repeated, unique, half of 100000 | arm64 | 263.6 | 266.7 | 264.6 | 261.9 | 251.3 | 243.4 | 64.8 | 243.2 | 237.2 | -10% |
| drop(1) repeated, unique, half of 100000 | amd64 | 834.0 | 842.8 | 837.6 | 835.8 | 739.6 | 734.5 | 122.8 | 733.8 | 731.4 | -12% |
| pushFront, persistent, 100000 | arm64 | 1214.2 | 1205.1 | 1203.1 | 678.8 | 679.1 | 591.9 | 38.7 | 613.4 | 607.2 | -50% |
| pushFront, persistent, 100000 | amd64 | 2643.3 | 2616.7 | 2551.0 | 1758.9 | 1511.6 | 1486.9 | 70.7 | 1495.6 | 1483.5 | -44% |
| pushFront repeated, unique, from empty to 100000 | arm64 | 1055.0 | 1040.6 | 1038.1 | 618.5 | 602.5 | 563.4 | 88.2 | 571.9 | 567.3 | -46% |
| pushFront repeated, unique, from empty to 100000 | amd64 | 2469.9 | 2465.3 | 2415.3 | 1741.7 | 1550.9 | 1549.5 | 189.3 | 1562.4 | 1578.1 | -36% |

### FlexDeque: the same operations with a head leaf

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| deque: v[i] random, regular, 1000 | arm64 | – | – | – | – | – | – | – | 3.8 | 3.8 | +9% vs FlexVec |
| deque: v[i] random, regular, 1000 | amd64 | – | – | – | – | – | – | – | 4.0 | 4.2 | -5% vs FlexVec |
| deque: v[i] = x random, unique, 1000 | arm64 | – | – | – | – | – | – | – | 8.4 | 8.4 | +6% vs FlexVec |
| deque: v[i] = x random, unique, 1000 | amd64 | – | – | – | – | – | – | – | 11.0 | 10.0 | +16% vs FlexVec |
| deque: a & b, 1000 + 1000 | arm64 | – | – | – | – | – | – | – | 1272.5 | 1295.8 | -19% vs FlexVec |
| deque: a & b, 1000 + 1000 | amd64 | – | – | – | – | – | – | – | 3075.3 | 3037.7 | -20% vs FlexVec |
| deque: insert middle, persistent, 1000 | arm64 | – | – | – | – | – | – | – | 498.6 | 500.4 | +6% vs FlexVec |
| deque: insert middle, persistent, 1000 | amd64 | – | – | – | – | – | – | – | 1273.1 | 1347.7 | +5% vs FlexVec |
| deque: erase middle, persistent, 1000 | arm64 | – | – | – | – | – | – | – | 528.2 | 528.7 | +6% vs FlexVec |
| deque: erase middle, persistent, 1000 | amd64 | – | – | – | – | – | – | – | 1339.9 | 1419.9 | +7% vs FlexVec |
| deque: drop(1), persistent, 1000 | arm64 | – | – | – | – | – | – | – | 198.7 | 198.7 | +5% vs FlexVec |
| deque: drop(1), persistent, 1000 | amd64 | – | – | – | – | – | – | – | 544.1 | 553.0 | +1% vs FlexVec |
| deque: drop(1) repeated, unique, half of 1000 | arm64 | – | – | – | – | – | – | – | 61.5 | 62.3 | -58% vs FlexVec |
| deque: drop(1) repeated, unique, half of 1000 | amd64 | – | – | – | – | – | – | – | 120.7 | 117.7 | -75% vs FlexVec |
| deque: pushFront, persistent, 1000 | arm64 | – | – | – | – | – | – | – | 34.0 | 40.9 | -85% vs FlexVec |
| deque: pushFront, persistent, 1000 | amd64 | – | – | – | – | – | – | – | 70.5 | 71.1 | -90% vs FlexVec |
| deque: pushFront repeated, unique, from empty to 1000 | arm64 | – | – | – | – | – | – | – | 75.0 | 74.0 | -68% vs FlexVec |
| deque: pushFront repeated, unique, from empty to 1000 | amd64 | – | – | – | – | – | – | – | 145.4 | 135.9 | -77% vs FlexVec |
| deque: v[i] random, regular, 100000 | arm64 | – | – | – | – | – | – | – | 5.4 | 5.4 | +10% vs FlexVec |
| deque: v[i] random, regular, 100000 | amd64 | – | – | – | – | – | – | – | 8.1 | 9.6 | +17% vs FlexVec |
| deque: v[i] = x random, unique, 100000 | arm64 | – | – | – | – | – | – | – | 10.9 | 11.0 | +5% vs FlexVec |
| deque: v[i] = x random, unique, 100000 | amd64 | – | – | – | – | – | – | – | 23.9 | 17.3 | +1% vs FlexVec |
| deque: a & b, 100000 + 100000 | arm64 | – | – | – | – | – | – | – | 864.7 | 866.4 | +3% vs FlexVec |
| deque: a & b, 100000 + 100000 | amd64 | – | – | – | – | – | – | – | 2222.7 | 2271.4 | +3% vs FlexVec |
| deque: insert middle, persistent, 100000 | arm64 | – | – | – | – | – | – | – | 1055.0 | 1035.7 | +4% vs FlexVec |
| deque: insert middle, persistent, 100000 | amd64 | – | – | – | – | – | – | – | 2682.4 | 2816.7 | +4% vs FlexVec |
| deque: erase middle, persistent, 100000 | arm64 | – | – | – | – | – | – | – | 1042.4 | 1009.2 | +2% vs FlexVec |
| deque: erase middle, persistent, 100000 | amd64 | – | – | – | – | – | – | – | 2677.7 | 2744.5 | +1% vs FlexVec |
| deque: drop(1), persistent, 100000 | arm64 | – | – | – | – | – | – | – | 378.2 | 375.3 | +2% vs FlexVec |
| deque: drop(1), persistent, 100000 | amd64 | – | – | – | – | – | – | – | 1102.9 | 1122.5 | +1% vs FlexVec |
| deque: drop(1) repeated, unique, half of 100000 | arm64 | – | – | – | – | – | – | – | 62.4 | 63.4 | -73% vs FlexVec |
| deque: drop(1) repeated, unique, half of 100000 | amd64 | – | – | – | – | – | – | – | 124.8 | 122.3 | -83% vs FlexVec |
| deque: pushFront, persistent, 100000 | arm64 | – | – | – | – | – | – | – | 34.1 | 38.6 | -94% vs FlexVec |
| deque: pushFront, persistent, 100000 | amd64 | – | – | – | – | – | – | – | 69.8 | 70.6 | -95% vs FlexVec |
| deque: pushFront repeated, unique, from empty to 100000 | arm64 | – | – | – | – | – | – | – | 86.0 | 87.8 | -85% vs FlexVec |
| deque: pushFront repeated, unique, from empty to 100000 | amd64 | – | – | – | – | – | – | – | 181.6 | 181.0 | -89% vs FlexVec |

## FlexStr

### Copying one value (into an array slot)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr copy, 16 B | arm64 | 10.5 | 11.2 | 10.6 | 8.7 | 8.6 | 8.6 | 10.0 | 8.6 | 8.6 | -18% |
| FlexStr copy, 16 B | amd64 | 14.5 | 14.6 | 14.7 | 14.6 | 14.6 | 14.6 | 16.6 | 14.7 | 14.5 | +0% |
| FlexStr copy, 1024 B | arm64 | 11.0 | 11.0 | 10.1 | 8.4 | 8.4 | 9.0 | 11.6 | 9.0 | 9.0 | -18% |
| FlexStr copy, 1024 B | amd64 | 24.0 | 25.1 | 25.5 | 25.6 | 25.5 | 25.6 | 26.0 | 24.1 | 25.8 | +8% |
| FlexStr copy, 65536 B | arm64 | 10.3 | 11.0 | 10.9 | 9.0 | 9.0 | 8.8 | 10.9 | 8.4 | 8.4 | -18% |
| FlexStr copy, 65536 B | amd64 | 25.7 | 25.5 | 25.1 | 25.7 | 25.4 | 23.4 | 26.8 | 25.5 | 24.7 | -4% |

### Hashing (8 equal values in separate allocations, rotated)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr hash, 16 B | arm64 | 23.5 | 21.9 | 23.7 | 21.6 | 22.5 | 21.6 | 25.1 | 22.3 | 21.2 | -10% |
| FlexStr hash, 16 B | amd64 | 47.2 | 48.2 | 47.2 | 47.7 | 47.2 | 47.6 | 54.3 | 47.1 | 47.8 | +1% |
| FlexStr hash, 1024 B | arm64 | 92.5 | 93.0 | 91.8 | 92.2 | 92.0 | 92.4 | 95.9 | 92.3 | 92.2 | -0% |
| FlexStr hash, 1024 B | amd64 | 220.2 | 221.2 | 217.4 | 220.0 | 218.4 | 228.0 | 219.4 | 229.4 | 218.6 | -1% |
| FlexStr hash, 65536 B | arm64 | 5486.3 | 5503.5 | 5460.4 | 5476.0 | 5469.4 | 5511.4 | 5492.7 | 5464.4 | 5503.9 | +0% |
| FlexStr hash, 65536 B | amd64 | 10212.4 | 10141.3 | 10287.6 | 10394.4 | 10073.7 | 10140.4 | 10209.9 | 10247.5 | 10329.8 | +1% |

### Equality of equal values in separate allocations

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr ==, 16 B | arm64 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 8.6 | 7.1 | 6.9 | -4% |
| FlexStr ==, 16 B | amd64 | 46.6 | 46.5 | 46.5 | 46.2 | 46.0 | 46.3 | 49.6 | 46.7 | 47.5 | +2% |
| FlexStr ==, 1024 B | arm64 | 45.1 | 45.3 | 45.0 | 45.2 | 43.5 | 45.1 | 44.3 | 45.0 | 45.3 | +0% |
| FlexStr ==, 1024 B | amd64 | 114.8 | 114.8 | 114.5 | 114.4 | 111.1 | 112.1 | 114.1 | 111.2 | 115.2 | +0% |
| FlexStr ==, 65536 B | arm64 | 2997.9 | 2991.4 | 2983.4 | 2998.0 | 3002.5 | 2985.1 | 3048.2 | 3018.0 | 3001.0 | +0% |
| FlexStr ==, 65536 B | amd64 | 5682.0 | 5686.5 | 5724.4 | 5617.4 | 5503.0 | 5681.6 | 5819.5 | 5673.4 | 5790.0 | +2% |

### Random byte access, 64 KiB

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr s[i] | arm64 | 4.5 | 4.5 | 4.5 | 4.5 | 4.0 | 4.0 | 4.0 | 3.7 | 3.7 | -18% |
| FlexStr s[i] | amd64 | 5.5 | 5.2 | 5.3 | 5.3 | 5.3 | 5.3 | 5.7 | 5.1 | 5.1 | -7% |

### Iterating every byte, 64 KiB (per byte)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr items | arm64 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 | +0% |
| FlexStr items | amd64 | 0.6 | 0.6 | 0.6 | 0.6 | 0.6 | 0.6 | 0.6 | 0.6 | 0.6 | +0% |

### Appending 64 KiB one byte at a time (per byte)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr add | arm64 | 6.2 | 6.2 | 6.2 | 6.2 | 4.7 | 4.6 | 6.2 | 4.7 | 4.7 | -24% |
| FlexStr add | amd64 | 8.3 | 8.0 | 8.4 | 8.3 | 8.5 | 8.5 | 8.4 | 8.6 | 6.4 | -23% |

### Concatenating two equal-size values

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr &, 65536 B each | arm64 | 1555.1 | 1551.5 | 1534.5 | 824.1 | 877.9 | 726.7 | 740.6 | 677.6 | 732.9 | -53% |
| FlexStr &, 65536 B each | amd64 | 3338.1 | 3344.4 | 3292.4 | 2529.0 | 2289.1 | 2273.3 | 2290.4 | 2291.2 | 2326.6 | -30% |
| FlexStr &, 1048576 B each | arm64 | 2390.8 | 2334.2 | 2357.5 | 1292.5 | 1326.7 | 1170.8 | 1178.3 | 1180.8 | 1193.3 | -50% |
| FlexStr &, 1048576 B each | amd64 | 5134.6 | 5129.0 | 5133.8 | 3929.7 | 3634.9 | 3565.3 | 3490.9 | 3474.5 | 3521.6 | -31% |

### Inserting 8 bytes at a random offset (new version each time)

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr insert, 65536 B | arm64 | 1852.2 | 1849.9 | 1786.2 | 1242.9 | 1160.0 | 1145.0 | 1189.1 | 1109.6 | 1120.5 | -40% |
| FlexStr insert, 65536 B | amd64 | 4016.8 | 4023.6 | 3929.8 | 3295.7 | 2946.1 | 2923.0 | 3063.2 | 2887.9 | 2945.2 | -27% |
| FlexStr insert, 1048576 B | arm64 | 2592.9 | 2589.2 | 2546.9 | 1798.8 | 1720.0 | 1618.3 | 1670.4 | 1632.9 | 1633.3 | -37% |
| FlexStr insert, 1048576 B | amd64 | 5757.1 | 5690.6 | 5683.7 | 4971.0 | 4073.6 | 4078.7 | 4305.1 | 4090.2 | 4107.9 | -29% |

### Slicing half of a 1 MiB value

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FlexStr s[a .. b] | arm64 | 719.2 | 720.0 | 725.4 | 647.5 | 620.2 | 611.0 | 589.2 | 578.3 | 612.3 | -15% |
| FlexStr s[a .. b] | amd64 | 1637.7 | 1643.7 | 1635.0 | 1655.0 | 1463.7 | 1450.4 | 1559.0 | 1463.0 | 1480.8 | -10% |

### Editing a 64 KiB document 1000 times, keeping every version

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| seq[FlexStr] history (per edit) | arm64 | 247.3 | 230.6 | 227.9 | 227.7 | 216.8 | 215.8 | 224.8 | 217.2 | 216.5 | -12% |
| seq[FlexStr] history (per edit) | amd64 | 616.2 | 614.1 | 622.3 | 620.0 | 561.1 | 560.2 | 570.3 | 570.9 | 563.1 | -9% |

### Converting from and to string, 64 KiB

| operation | arch | base | 1 | 2 | 3a | 3b | 3c | 4 | 5 | 6 | change |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| toFlexStr(string) | arm64 | 64980.1 | 64486.0 | 63961.9 | 64156.7 | 64007.3 | 62862.2 | 62593.3 | 63698.5 | 63443.3 | -2% |
| toFlexStr(string) | amd64 | 163.9 µs | 161.2 µs | 161.5 µs | 158.3 µs | 142.3 µs | 141.3 µs | 161.6 µs | 140.4 µs | 140.1 µs | -15% |
| $FlexStr | arm64 | 3181.2 | 3339.1 | 3393.0 | 3286.6 | 3197.6 | 3377.3 | 3412.1 | 3333.5 | 3295.0 | +4% |
| $FlexStr | amd64 | 6224.4 | 6100.2 | 6092.4 | 6108.0 | 6125.0 | 6122.5 | 6145.8 | 6122.4 | 6121.8 | -2% |
