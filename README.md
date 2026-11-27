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

| thetos          | immer                | Structure                                   |
|-----------------|----------------------|---------------------------------------------|
| `TrieMap[K, V]` | `immer::map`         | CHAMP hash trie, 32-way, 64-bit hashes      |
| `TrieSet[T]`    | `immer::set`         | CHAMP hash trie                             |
| `TrieVec[T]`    | `immer::vector`      | 32-way radix-balanced tree with tail        |
| `FlexVec[T]`    | `immer::flex_vector` | relaxed radix-balanced (RRB) tree with tail |
| `Box[T]`        | `immer::box`         | refcounted immutable value                  |
| `Atom[T]`       | `immer::atom`        | lock-free cell to publish new versions      |

## Quick start

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

`import thetos` brings in every container. Each one also has its own
module (`thetos/triemap`, `thetos/trieset`, `thetos/trievec`,
`thetos/flexvec`, `thetos/box`, `thetos/atom`).

## How updates work

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

Iterators walk a snapshot, so reassigning the source variable inside the
loop is safe.

## TrieMap

`TrieMap[K, V]` is a hash map. Keys need `hash` and `==`. Lookups and
updates are O(log32 n), which is effectively constant.

```nim
import std/options
import thetos

var prices = toTrieMap({"apple": 3, "pear": 5})
prices["plum"] = 4                      # in place
assert prices["apple"] == 3             # `[]` raises KeyError when missing
assert prices.getOrDefault("kiwi") == 0
assert prices.get("kiwi").isNone

let sale = prices.put("pear", 2).erase("plum")
assert prices["pear"] == 5 and "plum" in prices   # the original is unchanged
assert sale["pear"] == 2 and "plum" notin sale

# `update` applies a function to the current value (`default(V)` if absent).
let counted = sale.update("apple", proc(n: int): int = n + 1)
assert counted["apple"] == 4

var total = 0
for name, price in prices:              # also `keys` and `values`
  total += price
assert total == 12
```

`diff(a, b)` lists what changed between two versions, after `immer::diff`.
It skips every subtree the versions still share, so comparing a map with
one derived from it costs time proportional to the number of changes, not
the size of the map. The order is unspecified.

```nim
import thetos

let before = toTrieMap({1: "one", 2: "two", 3: "three"})
let after = before.put(2, "deux").erase(3).put(4, "four")

var changes: seq[string]
for d in diff(before, after):
  case d.kind
  of dkAdded: changes.add "added " & $d.key & " = " & d.newValue
  of dkRemoved: changes.add "removed " & $d.key
  of dkChanged: changes.add "changed " & $d.key & ": " & d.oldValue & " -> " & d.newValue
assert changes.len == 3
assert "changed 2: two -> deux" in changes
```

API: `initTrieMap`, `toTrieMap`, `len`, `contains`/`in`, `hasKey`, `[]`,
`getOrDefault`, `get`, `[]=`, `del`, `put`, `erase`, `update`, `pairs`,
`keys`, `values`, `diff`, `==`, `hash`, `$`.

## TrieSet

`TrieSet[T]` is a hash set built on the same trie as `TrieMap`.

```nim
import thetos

var tags = toTrieSet(["nim", "trie"])
tags.incl "fast"                         # in place
let fewer = tags.erase("trie")           # functional
assert "trie" in tags and "trie" notin fewer

let a = toTrieSet([1, 2, 3, 4])
let b = toTrieSet([3, 4, 5])
assert a + b == toTrieSet([1, 2, 3, 4, 5])   # union
assert a * b == toTrieSet([3, 4])            # intersection
assert a - b == toTrieSet([1, 2])            # difference
assert toTrieSet([3, 4]) <= a                # subset

var removed: seq[int]
for d in diff(a, b):                         # dkAdded or dkRemoved
  if d.kind == dkRemoved:
    removed.add d.item
assert removed.len == 2 and 1 in removed and 2 in removed
```

API: `initTrieSet`, `toTrieSet`, `len`, `contains`/`in`, `incl`, `excl`,
`insert`, `erase`, `items`, `diff`, `+`, `*`, `-`, `<=`, `==`, `hash`, `$`.

## TrieVec

`TrieVec[T]` is an indexed sequence: a 32-way trie with a tail buffer.
Indexing and `[]=` are O(log32 n); `add` and `pop` are amortized O(1).

```nim
import thetos

var v = toTrieVec([1, 2, 3])
v.add 4                                  # in place
v[0] = 10
assert v[0] == 10 and v[^1] == 4
assert v.first == 10 and v.last == 4
assert v.pop() == 4 and v.len == 3

let longer = v.pushBack(99)              # functional versions
let changed = v.put(1, 20)
let doubled = v.update(2, proc(x: int): int = x * 2)
assert v == toTrieVec([10, 2, 3])        # the original is unchanged
assert longer.len == 4 and changed[1] == 20 and doubled[2] == 6
assert v.take(2) == toTrieVec([10, 2])
assert (v & toTrieVec([7])).len == 4     # O(n) in the right operand

var sum = 0
for i, x in v:                           # also `items`
  sum += i * x
assert sum == 2 + 6
```

API: `initTrieVec`, `toTrieVec`, `len`, `high`, `low`, `[]` (also `^i`),
`first`, `last`, `[]=`, `add`, `pop`, `pushBack`, `popBack`, `put`,
`update`, `take`, `&`, `items`, `pairs`, `==`, `hash`, `$`.

## FlexVec

`FlexVec[T]` is a relaxed radix-balanced (RRB) tree, after
`immer::flex_vector`. It has the whole `TrieVec` API, and concatenation,
slicing, `drop`, `insert`, `erase` and `pushFront` are O(log n) and share
structure with their inputs.

```nim
import thetos

let a = toFlexVec([1, 2, 3, 4, 5])
let b = toFlexVec([6, 7, 8])

let both = a & b                         # O(log n) concatenation
assert both.len == 8 and both[5] == 6
assert both[2 .. 4] == toFlexVec([3, 4, 5])   # slice, `^i` works too
assert both.drop(6) == toFlexVec([7, 8])
assert both.take(2) == toFlexVec([1, 2])

let edited = both.insert(1, 100).erase(0).pushFront(0)
assert edited[0] == 0 and edited[1] == 100 and edited.len == 9

var log = toFlexVec(["start"])
log.add toFlexVec(["a", "b"])            # in-place append of another FlexVec
assert log.len == 3

let fromTrie = toFlexVec(toTrieVec([1, 2]))   # copies, O(n)
assert fromTrie.len == 2
```

A `FlexVec` built only by appending stays regular and indexes almost as
fast as a `TrieVec` (about 4.8 ns vs 3.4 ns per random lookup on an Apple
M3 Pro). After concatenations, inner nodes carry size tables and lookups
take a few times longer. Use `TrieVec` when you never need the extra
operations.

API: everything `TrieVec` has, plus `drop`, `[a .. b]`, `add` of another
`FlexVec`, `pushFront`, `insert`, `erase`, and `toFlexVec` from a `TrieVec`.

## Box

`Box[T]` holds one immutable value behind a reference count. Copying a box
is O(1) however large the value is, which makes it a cheap way to share a
big object, or to store one inside other containers.

```nim
import thetos

type Config = object
  name: string
  limits: seq[int]

let a = box(Config(name: "default", limits: @[1, 2, 3]))
let b = a                                 # O(1); both share one Config
assert b[].name == "default"

# `update` builds a new box. It reuses the allocation if the box is unique.
let c = a.update(proc(cfg: Config): Config =
  result = cfg
  result.limits.add 4)
assert a[].limits.len == 3 and c[].limits.len == 4

assert default(Box[int]).isEmpty           # `[]` on an empty box raises
```

API: `box`, `[]`, `update`, `isEmpty`, `==`, `hash`, `$`.

## Atom

`Atom[T]` is the one place shared state changes. Threads `load` a
snapshot, compute a new version with the persistent containers, and
publish it with `store`, `exchange` or `update` (a compare-and-swap loop).
None of these take a lock. An atom is a location, not a value: it cannot
be copied, so keep it in a global or in shared memory.

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

`update` may call its function more than once under contention, so the
function should have no side effects. The other operations:

```nim
import thetos

var current = initAtom(toTrieSet([1]))
let snapshot = current.load()            # O(1)
current.store(snapshot.insert(2))
let previous = current.exchange(toTrieSet([9]))
assert previous == toTrieSet([1, 2])
assert snapshot == toTrieSet([1])        # snapshots never change

# `diff` shows what other threads changed since a snapshot.
var added: seq[int]
for d in diff(snapshot, current.load()):
  if d.kind == dkAdded:
    added.add d.item
assert added == @[9]
```

API: `initAtom`, `load`, `store`, `exchange`, `update`.

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

## Known limitations

* If an element's `=copy` hook raises during `add(openArray)`, elements
  already appended remain in the vector. Both `TrieVec` and `FlexVec`
  release partially copied elements and temporary nodes when a copy raises,
  including with `-d:thetosSingleThread`.
* thetos requires Nim 2.2.12 or later. Nim 2.2.10 can leak allocations when
  a copy raises during a vector update or `Atom.update`.

## Development

```sh
atlas install               # dependencies (none at the moment)
nim test                    # all tests with the default config (atomicArc)
nim testAll                 # arc, orc and atomicArc in debug and release
nim testSingleThread        # container tests with -d:thetosSingleThread
nim r tests/ttriemap.nim    # one test file
atlas-run tests -- --skipParentCfg --threads:on --mm:arc   # what CI runs, in parallel
```

`tests/tleaks.nim` builds with `-d:thetosTrackAllocs` and checks that
every node is freed. The test suite is also clean under AddressSanitizer
and ThreadSanitizer:

```sh
nim c -r --skipParentCfg --threads:on --mm:arc -d:useMalloc --cc:clang \
  --passC:-fsanitize=thread --passL:-fsanitize=thread tests/tthreads.nim
```
