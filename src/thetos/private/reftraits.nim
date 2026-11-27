## Compile-time checks on what a type holds, for `Atom[T]`:
##
## * refs and closures, at any depth, whose reference counts are not atomic
##   under `--mm:arc`/`--mm:orc` (modeled on `containsRefs` in sigils'
##   `isolateutils`);
## * thread-local thetos containers from `thetos/local`, whose node
##   reference counts are never atomic.
##
## thetos containers keep their elements behind raw pointers. Recognize
## their private node types to find those elements through type aliases.

import std/macros
import ../[box, flexvec, local, triemap, trieset, trievec]

type
  Finding = enum
    fRefs ## a Nim ref or closure
    fLocal ## a container with plain (non-atomic) node reference counts

  DefaultContainers =
    tuple[
      m: triemap.TrieMap[int, int],
      s: trieset.TrieSet[int],
      v: trievec.TrieVec[int],
      f: flexvec.FlexVec[int],
      b: box.Box[int],
    ]

  LocalContainers =
    tuple[
      m: local.TrieMap[int, int],
      s: local.TrieSet[int],
      v: local.TrieVec[int],
      f: local.FlexVec[int],
      b: local.Box[int],
    ]

proc nodeTypes(containers: NimNode): seq[NimNode] {.compileTime.} =
  for entry in containers.getTypeImpl():
    for field in entry[^2].getTypeImpl()[2]:
      let fieldType = field[^2].getTypeImpl()
      if fieldType.kind == nnkPtrTy:
        result.add fieldType[0][0]
        break

proc scan(
    typ: NimNode, defaultNodes, localNodes: seq[NimNode], visited: var seq[NimNode]
): set[Finding] {.compileTime.} =
  template visit(child: NimNode): set[Finding] =
    scan(child, defaultNodes, localNodes, visited)

  case typ.kind
  of nnkRefTy:
    return {fRefs} + visit(typ[0])
  of nnkIteratorTy:
    return {fRefs}
  of nnkProcTy:
    # Proc types are closures unless they name another calling convention.
    for p in typ[1]:
      if p.kind in {nnkIdent, nnkSym} and
          $p in ["nimcall", "cdecl", "stdcall", "fastcall", "noconv", "inline"]:
        return {}
    return {fRefs}
  of nnkObjectTy:
    if typ[1].kind == nnkOfInherit:
      result = visit(typ[1][0])
    result = result + visit(typ[2])
  of nnkTupleTy, nnkRecList, nnkRecCase, nnkOfBranch, nnkElse, nnkTupleConstr:
    for child in typ:
      if child.kind notin {nnkEmpty, nnkIdent}:
        result = result + visit(child)
  of nnkIdentDefs:
    return visit(typ[^2])
  of nnkDistinctTy:
    return visit(typ[0])
  of nnkPtrTy:
    let node = typ[0]
    if node.kind == nnkBracketExpr:
      if node[0] in localNodes:
        result.incl fLocal
      elif node[0] notin defaultNodes:
        return
      when not compileOption("threads"):
        result.incl fLocal # without threads, the default containers use plain counts
      for i in 1 ..< node.len:
        result = result + visit(node[i])
  of nnkBracketExpr, nnkSym:
    if typ.kind == nnkBracketExpr and typ[0].kind == nnkSym and
        typ[0].typeKind in {ntySequence, ntyArray}:
      return visit(typ[^1])
    for previous in visited:
      if sameType(typ, previous):
        return {}
    visited.add typ
    let impl = typ.getTypeImpl()
    if impl.kind != nnkSym or impl != typ:
      return visit(impl)
  else:
    discard

proc findings(T: NimNode): set[Finding] {.compileTime.} =
  var visited: seq[NimNode]
  scan(
    T.getTypeInst()[1],
    nodeTypes(bindSym"DefaultContainers"),
    nodeTypes(bindSym"LocalContainers"),
    visited,
  )

macro holdsNimRefs*(T: typedesc): bool =
  ## True when copying a `T` changes a Nim `ref` or closure reference count.
  newLit(fRefs in findings(T))

macro holdsLocalContainers*(T: typedesc): bool =
  ## True when `T` holds a thetos container with plain (non-atomic) node
  ## reference counts: one from `thetos/local`, or any container in a
  ## build with `--threads:off`.
  newLit(fLocal in findings(T))
