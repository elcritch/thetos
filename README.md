# thetos

*θετός, "placed, fixed"*

Persistent, immutable data structures for Nim, after the C++ library
[immer](https://github.com/arximboldi/immer).

Every container is a value type. Copying one is O(1) and shares all of
its structure; an "update" returns a new version that shares everything
except the changed path, and every older version stays valid. Nodes use
**atomic reference counts** and are **never mutated while shared**, so
versions can be handed between threads with no locks, under `--mm:arc`,
`--mm:orc` or `--mm:atomicArc`.

| thetos  | immer         | Structure                                   |
|-------------|---------------|---------------------------------------------|
| `Map[K, V]` | `immer::map`  | CHAMP hash trie, 32-way, 64-bit hashes      |
| `Set[T]`    | `immer::set`  | CHAMP hash trie                             |
| `Vector[T]` | `immer::vector` | 32-way radix-balanced tree with tail      |
| `Box[T]`    | `immer::box`  | refcounted immutable value                  |
| `Atom[T]`   | `immer::atom` | lock-free cell to publish new versions      |

## Example

```nim
import thetos

var a = initMap[string, int]()
a["one"] = 1                  # edits only this map value
let b = a.put("two", 2)       # functional update; `a` is unchanged
assert a.len == 1 and b.len == 2

var v = toVector([1, 2, 3])
let w = v.pushBack(4)
v[0] = 10
assert w[0] == 1              # `w` still sees the old element
```

Sharing state between threads:

```nim
import std/typedthreads
import thetos

var state: Atom[Map[int, string]]

proc worker(id: int) {.thread.} =
  for i in 0 ..< 1000:
    state.update(proc(m: Map[int, string]): Map[int, string] =
      m.put(id * 1000 + i, $i))

var ts: array[4, Thread[int]]
for i in 0 ..< ts.len:
  createThread(ts[i], worker, i)
joinThreads(ts)
assert state.load().len == 4000
```

## API at a glance

The API has two styles that share one implementation:

* **In-place on a `var`**: `m[k] = v`, `m.del(k)`, `s.incl(x)`,
  `s.excl(x)`, `v.add(x)`, `v[i] = x`, `v.pop()`. These change only that
  variable's value. Other copies are never affected.
* **Functional, returning a new version**: `put`, `erase`, `update`,
  `insert`, `pushBack`, `popBack`, `take`. They take the receiver as
  `sink`, so the receiver is reused at its last use.

When a node's reference count is 1, the caller provably holds the only
reference, so it is edited in place instead of copied. This gives immer's
transient and rvalue optimizations automatically: filling a map in a loop
with `[]=` (or `m = m.put(...)`) costs about the same as a mutable table.
Once a version is shared, its nodes are path-copied.

* `Map`: `initMap`, `toMap`, `len`, `contains`/`in`, `[]` (raises
  `KeyError`), `getOrDefault`, `get` (`Option`), `[]=`, `del`, `put`,
  `erase`, `update`, `pairs`, `keys`, `values`, `==`, `hash`, `$`.
* `Set`: `initSet`, `toSet`, `len`, `contains`, `incl`, `excl`, `insert`,
  `erase`, `items`, `+`, `*`, `-`, `<=`, `==`, `hash`, `$`.
* `Vector`: `initVector`, `toVector`, `len`, `[]` (also `^i`), `first`,
  `last`, `[]=`, `add`, `pop`, `pushBack`, `popBack`, `put`, `update`,
  `take`, `&`, `items`, `pairs`, `==`, `hash`, `$`.
* `Box`: `box`, `[]`, `update`, `isEmpty`, `==`, `hash`, `$`.
* `Atom`: `initAtom`, `load`, `store`, `exchange`, `update` (CAS loop).
  Atoms are locations and cannot be copied. Keep them in globals or in
  shared memory.

Iterators walk a snapshot, so reassigning the source variable inside the
loop is safe.

## Thread-safety contract

* Containers can be shared and copied between threads freely. A copy is an
  atomic increment, and nothing reachable from a shared node is ever
  written.
* Element types must themselves be safe to copy from several threads.
  Plain values, `string`, `seq` and thetos containers are. Nim `ref`
  values are only safe under `--mm:atomicArc`, because `arc`/`orc` count
  `ref`s non-atomically.
* `Atom` is lock-free. It uses split reference counting: the atom word packs
  the cell pointer with a count of in-flight loads (16 bits on 64-bit
  targets, 32 on 32-bit). The old cell stays alive while the writer
  accounts for any in-flight loads. Every store installs a fresh cell,
  so pointer equality has no ABA problem. `update` may call its function
  more than once under contention.
* Under ORC, reference cycles that pass through an thetos container are
  not collected. Persistent values cannot form cycles on their own.

## Not (yet) ported from immer

`flex_vector` (RRB trees with O(log n) concatenation and slicing),
`array`, `table`, explicit transient types (unique ownership already gives
in-place updates), custom memory policies, and diffing.

## Development

```sh
atlas install           # dependencies (none at the moment)
nim test                # all tests with the default config (atomicArc)
nim testAll             # arc, orc and atomicArc in debug and release
nim r tests/tmap.nim    # one test file
```

`tests/tleaks.nim` builds with `-d:thetosTrackAllocs` and checks that
every node is freed. The test suite is also clean under AddressSanitizer
and ThreadSanitizer:

```sh
nim c -r --skipParentCfg --threads:on --mm:arc -d:useMalloc --cc:clang \
  --passC:-fsanitize=thread --passL:-fsanitize=thread tests/tthreads.nim
```
