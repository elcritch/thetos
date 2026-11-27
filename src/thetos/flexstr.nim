## Persistent strings: ropes with O(log n) editing.
##
## `FlexStr` keeps its bytes in a relaxed radix-balanced tree (a
## `FlexVec[char]`), so concatenation, slicing, `insert`, `erase` and
## `replace` are O(log n) and every version shares structure with the ones
## it came from. Old versions stay valid, which makes it a natural fit for
## text that is edited often and needs history, such as an editor buffer
## with undo.
##
## Like `string`, it holds bytes: UTF-8 text works as usual, `len` and
## offsets count bytes, and `runes` and `runeLen` work in code points.
## Keep offsets on code point boundaries. Indexing is O(log n), so for
## short strings that are mostly read, `ImmStr` or `string` is faster.

runnableExamples:
  let doc = toFlexStr("hello wörld")
  let edited = doc.insert(5, ",").replace(7 .. 12, "there")
  assert $edited == "hello, there"
  assert $doc == "hello wörld" # the old version is unchanged
  assert doc.len == 12 and doc.runeLen == 11

import std/[hashes, unicode]
import ./private/core
import ./[flexvec, immstr]

include ./private/flexstrimpl
