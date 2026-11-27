# Included by `thetos/immstr` and `thetos/local`; not a module.
# The including module imports `std/[atomics, hashes, unicode]` and `private/core`,
# and declares `RcCount`, the type of each node's `rc`.

type
  ImmStrNode = object
    rc*: RcCount # exported for the generic refcount helpers in core
    len: int
    hash: Atomic[int] ## cached on first use; 0 until then
    # `len` bytes follow, then a NUL terminator.

  ImmStr* = object
    ## Immutable string with O(1) copies. Holds bytes like `string`, so
    ## UTF-8 text works as usual. `default(ImmStr)` is the empty string.
    node: ptr ImmStrNode

template strBytes(n: ptr ImmStrNode): ptr UncheckedArray[char] =
  cast[ptr UncheckedArray[char]](cast[uint](n) + uint(sizeof(ImmStrNode)))

proc `=destroy`*(s: ImmStr) =
  if s.node != nil and dropRef(s.node):
    freeRaw(s.node)

proc `=wasMoved`*(s: var ImmStr) =
  s.node = nil

proc `=dup`*(s: ImmStr): ImmStr =
  if s.node != nil:
    retain(s.node)
  result.node = s.node

proc `=copy`*(dst: var ImmStr, src: ImmStr) =
  if src.node != nil:
    retain(src.node)
  `=destroy`(dst)
  dst.node = src.node

proc newImmStrNode(len: int): ptr ImmStrNode =
  result = cast[ptr ImmStrNode](allocRawUninit(sizeof(ImmStrNode) + len + 1))
  initRc(result)
  result.len = len
  result.hash.store(0, moRelaxed)
  result.strBytes[len] = '\0'

proc toImmStr*(s: openArray[char]): ImmStr =
  ## Copies `s` (a `string` or any `openArray[char]`) into an `ImmStr`.
  if s.len == 0:
    return
  let n = newImmStrNode(s.len)
  copyMem(n.strBytes, unsafeAddr s[0], s.len)
  result.node = n

proc len*(s: ImmStr): int {.inline.} =
  ## Length in bytes. See `runeLen` for the number of UTF-8 code points.
  if s.node == nil: 0 else: s.node.len

proc high*(s: ImmStr): int {.inline.} =
  s.len - 1

proc low*(s: ImmStr): int {.inline.} =
  0

proc isEmpty*(s: ImmStr): bool {.inline.} =
  s.node == nil

template toOpenArray*(s: ImmStr): untyped =
  ## The bytes as an `openArray[char]`, without copying. Valid while `s`
  ## is alive.
  toOpenArray((if s.node == nil: nil else: s.node.strBytes), 0, s.len - 1)

proc `[]`*(s: ImmStr, i: Natural): char {.inline.} =
  ## Byte `i`.
  if i >= s.len:
    raiseIndex(i, s.len)
  s.node.strBytes[i]

proc `[]`*(s: ImmStr, i: BackwardsIndex): char {.inline.} =
  s[s.len - int(i)]

proc `[]`*[U, V: Ordinal](s: ImmStr, x: HSlice[U, V]): ImmStr =
  ## Bytes `x.a .. x.b` (`^i` allowed) as a new string. Keep slice bounds
  ## on UTF-8 code point boundaries.
  let a = (when U is BackwardsIndex: s.len - int(x.a) else: int(x.a))
  let b = (when V is BackwardsIndex: s.len - int(x.b) else: int(x.b))
  if b < a:
    return
  if a < 0 or a >= s.len:
    raiseIndex(a, s.len)
  if b >= s.len:
    raiseIndex(b, s.len)
  toImmStr(toOpenArray(s.node.strBytes, a, b))

proc toCString*(s: ImmStr): cstring =
  ## A NUL-terminated view of the bytes, without copying. Valid while `s`
  ## is alive.
  if s.node == nil:
    cstring("")
  else:
    cast[cstring](s.node.strBytes)

proc `$`*(s: ImmStr): string =
  ## Copies the bytes into a Nim `string`.
  result = newString(s.len)
  if s.len > 0:
    copyMem(addr result[0], s.node.strBytes, s.len)

iterator items*(s: ImmStr): char =
  let keep = s # keep the bytes alive even if `s` is reassigned
  for i in 0 ..< keep.len:
    yield keep.node.strBytes[i]

iterator pairs*(s: ImmStr): (int, char) =
  let keep = s
  for i in 0 ..< keep.len:
    yield (i, keep.node.strBytes[i])

iterator runes*(s: ImmStr): Rune =
  ## The UTF-8 code points.
  let keep = s
  var i = 0
  while i < keep.len:
    var r: Rune
    fastRuneAt(toOpenArray(keep), i, r, true)
    yield r

proc runeLen*(s: ImmStr): int =
  ## Number of UTF-8 code points.
  runeLen(toOpenArray(s))

proc validateUtf8*(s: ImmStr): int =
  ## The byte index of the first invalid UTF-8 sequence, or -1 if `s` is
  ## valid UTF-8.
  validateUtf8(toOpenArray(s))

proc hash*(s: ImmStr): Hash =
  ## Computed on first use and cached. Equal to `hash` of the same `string`.
  if s.node == nil:
    return hash("")
  var h = s.node.hash.load(moRelaxed)
  if h == 0:
    # Threads that race here compute and store the same value.
    h = hash(toOpenArray(s.node.strBytes, 0, s.node.len - 1))
    s.node.hash.store(h, moRelaxed)
  Hash(h)

proc cmp*(a, b: ImmStr): int =
  if a.node == b.node:
    return 0
  let n = min(a.len, b.len)
  if n > 0:
    result = cmpMem(a.node.strBytes, b.node.strBytes, n)
    if result != 0:
      return
  result = cmp(a.len, b.len)

proc `==`*(a, b: ImmStr): bool =
  if a.node == b.node:
    return true
  if a.len != b.len:
    return false
  # Cached hashes can reject a match early, but never force a hash.
  let ha = a.node.hash.load(moRelaxed)
  let hb = b.node.hash.load(moRelaxed)
  if ha != 0 and hb != 0 and ha != hb:
    return false
  cmpMem(a.node.strBytes, b.node.strBytes, a.len) == 0

proc `==`*(a: ImmStr, b: openArray[char]): bool =
  if a.len != b.len:
    return false
  a.len == 0 or cmpMem(a.node.strBytes, unsafeAddr b[0], a.len) == 0

proc `==`*(a: openArray[char], b: ImmStr): bool {.inline.} =
  b == a

proc `<`*(a, b: ImmStr): bool {.inline.} =
  cmp(a, b) < 0

proc `<=`*(a, b: ImmStr): bool {.inline.} =
  cmp(a, b) <= 0

proc concat(a, b: openArray[char]): ImmStr =
  let total = a.len + b.len
  if total == 0:
    return
  let n = newImmStrNode(total)
  if a.len > 0:
    copyMem(n.strBytes, unsafeAddr a[0], a.len)
  if b.len > 0:
    copyMem(addr n.strBytes[a.len], unsafeAddr b[0], b.len)
  result.node = n

proc `&`*(a, b: ImmStr): ImmStr =
  ## A new string holding `a` then `b`. O(len); see `FlexStr` for O(log n)
  ## concatenation.
  if a.len == 0:
    return b
  if b.len == 0:
    return a
  concat(toOpenArray(a), toOpenArray(b))

proc `&`*(a: ImmStr, b: openArray[char]): ImmStr =
  concat(toOpenArray(a), b)

proc `&`*(a: openArray[char], b: ImmStr): ImmStr =
  concat(a, toOpenArray(b))

proc find*(s: ImmStr, sub: openArray[char], start: Natural = 0): int =
  ## Byte index of the first occurrence of `sub` at or after `start`, or -1.
  if sub.len == 0:
    return (if start <= s.len: int(start) else: -1)
  var i = int(start)
  while i + sub.len <= s.len:
    if s.node.strBytes[i] == sub[0] and
        cmpMem(addr s.node.strBytes[i], unsafeAddr sub[0], sub.len) == 0:
      return i
    inc i
  -1

proc find*(s: ImmStr, c: char, start: Natural = 0): int =
  ## Byte index of the first `c` at or after `start`, or -1.
  for i in int(start) ..< s.len:
    if s.node.strBytes[i] == c:
      return i
  -1

proc contains*(s: ImmStr, sub: openArray[char]): bool {.inline.} =
  s.find(sub) >= 0

proc contains*(s: ImmStr, c: char): bool {.inline.} =
  s.find(c) >= 0

proc startsWith*(s: ImmStr, prefix: openArray[char]): bool =
  prefix.len <= s.len and
    (prefix.len == 0 or cmpMem(s.node.strBytes, unsafeAddr prefix[0], prefix.len) == 0)

proc endsWith*(s: ImmStr, suffix: openArray[char]): bool =
  suffix.len <= s.len and (
    suffix.len == 0 or
    cmpMem(addr s.node.strBytes[s.len - suffix.len], unsafeAddr suffix[0], suffix.len) ==
    0
  )
