## Stores Nim refs in an Atom. Rejected under arc/orc with threads unless
## -d:thetosUnsafeRefAtom is set (see tatomrefs.nim).
import thetos

var a: Atom[TrieMap[int, ref int]]
let r = new int
a.store(a.load().put(1, r))
