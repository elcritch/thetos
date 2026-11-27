# Included by `thetos/flexstr` and `thetos/local`; not a module.
# The including module provides `FlexVec` and `ImmStr` (with the same
# reference count type) and imports `std/[hashes, unicode]`.

type FlexStr* = object
  ## Persistent string: a rope of bytes on a relaxed radix-balanced tree
  ## (`FlexVec[char]`). Concatenation, slicing, insertion and erasing are
  ## O(log n) and share structure with the inputs. Holds bytes like
  ## `string`, so UTF-8 text works as usual. `default(FlexStr)` is empty.
  bytes: FlexVec[char]

proc toFlexStr*(s: openArray[char]): FlexStr =
  ## Copies `s` (a `string` or any `openArray[char]`) into a `FlexStr`.
  result.bytes.add(s)

proc toFlexStr*(s: ImmStr): FlexStr =
  toFlexStr(toOpenArray(s))

proc len*(s: FlexStr): int {.inline.} =
  ## Length in bytes. See `runeLen` for the number of UTF-8 code points.
  s.bytes.len

proc high*(s: FlexStr): int {.inline.} =
  s.bytes.len - 1

proc low*(s: FlexStr): int {.inline.} =
  0

proc isEmpty*(s: FlexStr): bool {.inline.} =
  s.bytes.len == 0

proc `[]`*(s: FlexStr, i: Natural): char {.inline.} =
  ## Byte `i`, in O(log n).
  s.bytes[i]

proc `[]`*(s: FlexStr, i: BackwardsIndex): char {.inline.} =
  s.bytes[i]

proc `[]`*[U, V: Ordinal](s: FlexStr, x: HSlice[U, V]): FlexStr =
  ## Bytes `x.a .. x.b` (`^i` allowed), in O(log n), sharing structure with
  ## `s`. Keep slice bounds on UTF-8 code point boundaries.
  FlexStr(bytes: s.bytes[x])

proc take*(s: FlexStr, n: Natural): FlexStr =
  ## The first `n` bytes, in O(log n).
  FlexStr(bytes: s.bytes.take(n))

proc drop*(s: FlexStr, n: Natural): FlexStr =
  ## All but the first `n` bytes, in O(log n).
  FlexStr(bytes: s.bytes.drop(n))

proc `&`*(a, b: FlexStr): FlexStr =
  ## Concatenation in O(log n).
  FlexStr(bytes: a.bytes & b.bytes)

proc `&`*(a: FlexStr, b: openArray[char]): FlexStr =
  a & toFlexStr(b)

proc `&`*(a: openArray[char], b: FlexStr): FlexStr =
  toFlexStr(a) & b

proc add*(s: var FlexStr, x: FlexStr) =
  ## Appends `x` to this string value only, in O(log n).
  s.bytes.add(x.bytes)

proc add*(s: var FlexStr, x: openArray[char]) =
  ## Appends `x` to this string value only.
  s.bytes.add(x)

proc add*(s: var FlexStr, c: char) =
  s.bytes.add c

proc insert*(s: FlexStr, i: Natural, x: FlexStr): FlexStr =
  ## A string with `x` inserted before byte `i` (`i == len` appends), in
  ## O(log n).
  if i > s.len:
    raiseIndex(i, s.len + 1)
  s.take(i) & x & s.drop(i)

proc insert*(s: FlexStr, i: Natural, x: openArray[char]): FlexStr =
  s.insert(i, toFlexStr(x))

proc erase*[U, V: Ordinal](s: FlexStr, x: HSlice[U, V]): FlexStr =
  ## A string without bytes `x.a .. x.b` (`^i` allowed), in O(log n).
  let a = (when U is BackwardsIndex: s.len - int(x.a) else: int(x.a))
  let b = (when V is BackwardsIndex: s.len - int(x.b) else: int(x.b))
  if b < a:
    return s
  if a < 0 or a >= s.len:
    raiseIndex(a, s.len)
  if b >= s.len:
    raiseIndex(b, s.len)
  s.take(a) & s.drop(b + 1)

proc replace*[U, V: Ordinal](
    s: FlexStr, x: HSlice[U, V], by: openArray[char]
): FlexStr =
  ## A string with bytes `x.a .. x.b` replaced by `by`, in O(log n) plus
  ## the length of `by`.
  let a = (when U is BackwardsIndex: s.len - int(x.a) else: int(x.a))
  s.erase(x).insert(a, by)

iterator items*(s: FlexStr): char =
  for c in s.bytes:
    yield c

iterator pairs*(s: FlexStr): (int, char) =
  for i, c in s.bytes:
    yield (i, c)

proc `$`*(s: FlexStr): string =
  ## Copies the bytes into a Nim `string`.
  result = newString(s.len)
  var at = 0
  for (p, n) in s.bytes.chunks:
    copyMem(addr result[at], p, n)
    at += n

proc toImmStr*(s: FlexStr): ImmStr =
  toImmStr($s)

iterator runes*(s: FlexStr): Rune =
  ## The UTF-8 code points.
  # std/unicode also recognizes legacy five- and six-byte lead bytes.
  var buf: array[6, char]
  var have, need: int
  for c in s.bytes:
    buf[have] = c
    if have == 0:
      need = runeLenAt(buf, 0)
    inc have
    if have == need:
      yield runeAt(buf, 0)
      have = 0
  var i = 0
  while i < have:
    var r: Rune
    fastRuneAt(buf.toOpenArray(0, have - 1), i, r)
    yield r

proc runeLen*(s: FlexStr): int =
  ## Counts code points using the same lead-byte widths as std/unicode.
  var i = 0
  for (p, n) in s.bytes.chunks:
    while i < n:
      i += runeLenAt(p.toOpenArray(0, n - 1), i)
      inc result
    i -= n

proc `==`*(a, b: FlexStr): bool =
  ## Compares the bytes, a leaf at a time.
  if a.len != b.len:
    return false
  var other: seq[(ptr UncheckedArray[char], int)]
  for chunk in b.bytes.chunks:
    other.add chunk
  var bi = 0 # chunk of `b`
  var bo = 0 # offset in that chunk
  for (p, n) in a.bytes.chunks:
    var ao = 0
    while ao < n:
      let take = min(n - ao, other[bi][1] - bo)
      if cmpMem(addr p[ao], addr other[bi][0][bo], take) != 0:
        return false
      ao += take
      bo += take
      if bo == other[bi][1]:
        inc bi
        bo = 0
  true

proc `==`*(a: FlexStr, b: openArray[char]): bool =
  if a.len != b.len:
    return false
  var at = 0
  for (p, n) in a.bytes.chunks:
    if cmpMem(p, unsafeAddr b[at], n) != 0:
      return false
    at += n
  true

proc `==`*(a: openArray[char], b: FlexStr): bool {.inline.} =
  b == a

proc hash*(s: FlexStr): Hash =
  ## Equal to `hash` of the same `string`. Equal strings can have different
  ## tree shapes, so this hashes the flattened bytes.
  hash($s)

proc startsWith*(s: FlexStr, prefix: openArray[char]): bool =
  if prefix.len > s.len:
    return false
  for i in 0 ..< prefix.len:
    if s.bytes[i] != prefix[i]:
      return false
  true

proc endsWith*(s: FlexStr, suffix: openArray[char]): bool =
  if suffix.len > s.len:
    return false
  let offset = s.len - suffix.len
  for i in 0 ..< suffix.len:
    if s.bytes[offset + i] != suffix[i]:
      return false
  true
