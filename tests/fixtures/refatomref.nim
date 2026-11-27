## An AtomRef of refs: rejected under arc/orc with threads, like Atom (see
## tatomref.nim).
import thetos

let r = newAtomRef(new int)
discard r.load()
