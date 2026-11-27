## Must fail to compile under -d:thetosSingleThread (see tsinglethread.nim).
import thetos/atom

var a: Atom[int]
a.store(1)
