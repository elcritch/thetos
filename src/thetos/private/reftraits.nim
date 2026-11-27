## Compile-time checks on what a type holds, for `Atom[T]`:
##
## * refs and closures, at any depth, whose reference counts are not atomic
##   under `--mm:arc`/`--mm:orc` (modeled on `containsRefs` in sigils'
##   `isolateutils`);
## * thread-local thetos containers from `thetos/local`, whose node
##   reference counts are never atomic.
##
## thetos containers keep their elements behind raw pointers, so they are
## recognized by name and confirmed by the `rc` field of their nodes.

import std/macros

type Finding = enum
  fRefs ## a Nim ref or closure
  fLocal ## a container with plain (non-atomic) node reference counts

const containerNames = ["TrieMap", "TrieSet", "TrieVec", "FlexVec", "Box"]

proc nodeRc(typ: NimNode): NimNode {.compileTime.} =
  ## For a thetos container instance, the type of its nodes' `rc` field;
  ## nil for anything else.
  if typ.kind != nnkBracketExpr or typ[0].kind != nnkSym or $typ[0] notin containerNames:
    return nil
  let impl = typ.getTypeImpl()
  if impl.kind != nnkObjectTy:
    return nil
  for field in impl[2]:
    if field.kind != nnkIdentDefs:
      continue
    let target = field[^2].getTypeImpl()
    if target.kind != nnkPtrTy:
      continue
    let node = target[0].getTypeImpl()
    if node.kind != nnkObjectTy:
      continue
    for nodeField in node[2]:
      if nodeField.kind == nnkIdentDefs and nodeField[0].eqIdent("rc"):
        return nodeField[^2]
  nil

proc scan(typ: NimNode, visited: var seq[NimNode]): set[Finding] {.compileTime.} =
  case typ.kind
  of nnkRefTy, nnkIteratorTy:
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
      result = scan(typ[1][0], visited)
    result = result + scan(typ[2], visited)
  of nnkTupleTy, nnkRecList, nnkRecCase, nnkOfBranch, nnkElse, nnkTupleConstr:
    for child in typ:
      if child.kind notin {nnkEmpty, nnkIdent}:
        result = result + scan(child, visited)
  of nnkIdentDefs:
    return scan(typ[^2], visited)
  of nnkDistinctTy:
    return scan(typ[0], visited)
  of nnkBracketExpr, nnkSym:
    for previous in visited:
      if sameType(typ, previous):
        return {}
    visited.add typ
    if typ.kind == nnkBracketExpr:
      let rc = nodeRc(typ)
      if rc != nil and rc.getTypeImpl().kind != nnkObjectTy:
        result.incl fLocal # plain `int` count rather than `Atomic[int]`
      if rc != nil or typ[0].eqIdent("seq") or typ[0].eqIdent("array"):
        for i in 1 ..< typ.len:
          result = result + scan(typ[i], visited)
        return
    let impl = typ.getTypeImpl()
    if impl.kind != nnkSym or impl != typ:
      return scan(impl, visited)
  else:
    discard

proc findings(T: NimNode): set[Finding] {.compileTime.} =
  var visited: seq[NimNode]
  scan(T.getTypeInst()[1], visited)

macro holdsNimRefs*(T: typedesc): bool =
  ## True when copying a `T` changes a Nim `ref` or closure reference count.
  newLit(fRefs in findings(T))

macro holdsLocalContainers*(T: typedesc): bool =
  ## True when `T` holds a thetos container with plain (non-atomic) node
  ## reference counts: one from `thetos/local`, or any container under
  ## `-d:thetosSingleThread`.
  newLit(fLocal in findings(T))
