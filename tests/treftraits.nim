import std/[unittest, hashes]
import thetos
import thetos/private/reftraits

type
  Node = ref object
    next: Node

  Plain = object
    a: int
    s: string
    xs: seq[float]

  WithRef = object
    a: int
    n: Node

  Base = object of RootObj
    n: ref int

  Derived = object of Base
    x: int

  Kind = enum
    kA
    kB

  Variant = object
    case kind: Kind
    of kA:
      a: int
    of kB:
      n: ref int

  PlainVariant = object
    case kind: Kind
    of kA:
      a: int
    of kB:
      s: string

  Tree = object
    kids: seq[Tree]

  DistinctRef = distinct ref int
  DistinctInt = distinct int

  Callback = proc(x: int): int
  NimcallCallback = proc(x: int): int {.nimcall.}
  ClosureIter = iterator (): int
  GcsafeCallback = proc(x: int): int {.gcsafe, raises: [].}
  NimcallGcsafe = proc(x: int): int {.nimcall, gcsafe.}

  Generic[T] = object
    item: T

proc hash(n: Node): Hash =
  hash(cast[pointer](n))

suite "holdsNimRefs":
  test "plain values":
    check not holdsNimRefs(int)
    check not holdsNimRefs(string)
    check not holdsNimRefs(seq[int])
    check not holdsNimRefs(array[4, string])
    check not holdsNimRefs((int, string))
    check not holdsNimRefs(Plain)
    check not holdsNimRefs(PlainVariant)
    check not holdsNimRefs(Tree)
    check not holdsNimRefs(DistinctInt)
    check not holdsNimRefs(ptr int)
    check not holdsNimRefs(pointer)
    check not holdsNimRefs(NimcallCallback)
    check not holdsNimRefs(NimcallGcsafe)
    check not holdsNimRefs(Generic[int])
    check not holdsNimRefs(set[char])

  test "refs and closures":
    check holdsNimRefs(ref int)
    check holdsNimRefs(Node)
    check holdsNimRefs(seq[ref int])
    check holdsNimRefs(array[2, Node])
    check holdsNimRefs((int, Node))
    check holdsNimRefs(tuple[a: int, b: ref int])
    check holdsNimRefs(WithRef)
    check holdsNimRefs(Derived)
    check holdsNimRefs(Variant)
    check holdsNimRefs(DistinctRef)
    check holdsNimRefs(Callback)
    check holdsNimRefs(ClosureIter)
    check holdsNimRefs(GcsafeCallback)
    check holdsNimRefs(Generic[Node])
    check holdsNimRefs(ref RootObj)

  test "thetos containers check their elements":
    check not holdsNimRefs(ImmStr)
    check not holdsNimRefs(FlexStr)
    check not holdsNimRefs(TrieMap[ImmStr, FlexStr])
    check not holdsNimRefs(TrieMap[int, string])
    check not holdsNimRefs(TrieMultiMap[int, string])
    check holdsNimRefs(TrieMultiMap[Node, int])
    check holdsNimRefs(TrieMultiMap[int, Node])
    check not holdsNimRefs(TrieSet[int])
    check not holdsNimRefs(TrieVec[TrieMap[string, seq[int]]])
    check not holdsNimRefs(Box[Plain])
    check not holdsNimRefs(FlexVec[string])
    check not holdsNimRefs(FlexVec[TrieMap[int, seq[int]]])
    check holdsNimRefs(TrieMap[int, Node])
    check holdsNimRefs(TrieMap[Node, int])
    check holdsNimRefs(TrieSet[Node])
    check holdsNimRefs(TrieVec[Callback])
    check holdsNimRefs(Box[WithRef])
    check holdsNimRefs(TrieVec[TrieMap[int, Box[ref int]]])
    check holdsNimRefs(FlexVec[Node])
    check holdsNimRefs(TrieMap[int, FlexVec[Callback]])
