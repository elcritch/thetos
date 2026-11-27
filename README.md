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

| thetos          | immer           | Structure                              |
|-----------------|-----------------|----------------------------------------|
| `TrieMap[K, V]` | `immer::map`    | CHAMP hash trie, 32-way, 64-bit hashes |
| `TrieSet[T]`    | `immer::set`    | CHAMP hash trie                        |
| `TrieVec[T]`    | `immer::vector` | 32-way radix-balanced tree with tail   |
| `Box[T]`        | `immer::box`    | refcounted immutable value             |
| `Atom[T]`       | `immer::atom`   | lock-free cell to publish new versions |

## Example

```nim
import thetos

var a = initTrieMap[string, int]()
a["one"] = 1                  # edits only this map value
let b = a.put("two", 2)       # functional update; `a` is unchanged
assert a.len == 1 and b.len == 2

var v = toTrieVec([1, 2, 3])
let w = v.pushBack(4)
v[0] = 10
assert w[0] == 1              # `w` still sees the old element
```

Sharing state between threads:

```nim
import std/typedthreads
import thetos

var state: Atom[TrieMap[int, string]]

proc worker(id: int) {.thread.} =
  for i in 0 ..< 1000:
    state.update(proc(m: TrieMap[int, string]): TrieMap[int, string] =
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

* `TrieMap`: `initTrieMap`, `toTrieMap`, `len`, `contains`/`in`, `[]` (raises
  `KeyError`), `getOrDefault`, `get` (`Option`), `[]=`, `del`, `put`,
  `erase`, `update`, `pairs`, `keys`, `values`, `diff`, `==`, `hash`, `$`.
* `TrieSet`: `initTrieSet`, `toTrieSet`, `len`, `contains`, `incl`, `excl`, `insert`,
  `erase`, `items`, `diff`, `+`, `*`, `-`, `<=`, `==`, `hash`, `$`.
* `TrieVec`: `initTrieVec`, `toTrieVec`, `len`, `[]` (also `^i`), `first`,
  `last`, `[]=`, `add`, `pop`, `pushBack`, `popBack`, `put`, `update`,
  `take`, `&`, `items`, `pairs`, `==`, `hash`, `$`.
* `Box`: `box`, `[]`, `update`, `isEmpty`, `==`, `hash`, `$`.
* `Atom`: `initAtom`, `load`, `store`, `exchange`, `update` (CAS loop).
  Atoms are locations and cannot be copied. Keep them in globals or in
  shared memory.

Iterators walk a snapshot, so reassigning the source variable inside the
loop is safe.

`diff(a, b)` yields the keys added, removed or changed (maps only) between
two versions of a map or set, after `immer::diff`. It skips every subtree the
two versions still share, so comparing a version with one derived from it
costs time proportional to the number of changes, not the size:

```nim
let before = state.load()
# ... other threads publish updates ...
for d in diff(before, state.load()):
  echo d.kind, " ", d.key   # dkAdded, dkRemoved or dkChanged
```

## Thread-safety contract

* Containers can be shared and copied between threads freely. A copy is an
  atomic increment, and nothing reachable from a shared node is ever
  written.
* Element types must themselves be safe to copy from several threads.
  Plain values, `string`, `seq` and thetos containers are. Nim `ref`
  values and closures are only safe under `--mm:atomicArc`, because
  `arc`/`orc` count them non-atomically.
* `Atom[T]` checks this at compile time. Under `--mm:arc` or `--mm:orc`
  with threads on, an `Atom` whose `T` holds a `ref` or closure, at any
  depth and including inside thetos containers, fails to compile. Build
  with `--mm:atomicArc`, or define `thetosUnsafeRefAtom` to turn the check
  off. Passing such values between threads some other way, such as
  `createThread` arguments or channels, is not checked.
* `Atom` is lock-free. It uses split reference counting: the atom word packs
  the cell pointer with a count of in-flight loads (16 bits on 64-bit
  targets, 32 on 32-bit). The old cell stays alive while the writer
  accounts for any in-flight loads. Every store installs a fresh cell,
  so pointer equality has no ABA problem. `update` may call its function
  more than once under contention.
* Under ORC, reference cycles that pass through an thetos container are
  not collected. Persistent values cannot form cycles on their own.

## Single-threaded builds

Programs that never share thetos values between threads can build with
`-d:thetosSingleThread`. Node reference counts then use plain integer
operations instead of atomic ones. This removes nothing from the API
except `Atom`, which fails to compile in this mode.

On an Apple M3 Pro this made persistent updates of shared maps and sets
about 20% faster and in-place vector `[]=` about 2 ns faster. Lookups,
iteration and building a container you own alone barely changed.

With the flag set, sharing any thetos value between threads is a data race.
The compiler cannot detect it, so only use the flag when the whole program
keeps thetos values on one thread.

## Development

```sh
atlas install               # dependencies (none at the moment)
nim test                    # all tests with the default config (atomicArc)
nim testAll                 # arc, orc and atomicArc in debug and release
nim testSingleThread        # container tests with -d:thetosSingleThread
nim r tests/ttriemap.nim    # one test file
```

`tests/tleaks.nim` builds with `-d:thetosTrackAllocs` and checks that
every node is freed. The test suite is also clean under AddressSanitizer
and ThreadSanitizer:

```sh
nim c -r --skipParentCfg --threads:on --mm:arc -d:useMalloc --cc:clang \
  --passC:-fsanitize=thread --passL:-fsanitize=thread tests/tthreads.nim
```
