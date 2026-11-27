## Compile-time check for types whose copies touch Nim reference counts:
## refs and closures, at any depth. Under `--mm:arc`/`--mm:orc` those counts
## are not atomic. Modeled on `containsRefs` in sigils' `isolateutils`.

import std/macros
import ../[triemap, trieset, trievec, box]

proc holdsRefs(typ: NimNode, visited: var seq[NimNode]): bool {.compileTime.} =
  case typ.kind
  of nnkRefTy, nnkIteratorTy:
    return true
  of nnkProcTy:
    # Proc types are closures unless they name another calling convention.
    for p in typ[1]:
      if p.kind in {nnkIdent, nnkSym} and
          $p in ["nimcall", "cdecl", "stdcall", "fastcall", "noconv", "inline"]:
        return false
    return true
  of nnkObjectTy:
    if typ[1].kind == nnkOfInherit and holdsRefs(typ[1][0], visited):
      return true
    return holdsRefs(typ[2], visited)
  of nnkTupleTy, nnkRecList, nnkRecCase, nnkOfBranch, nnkElse, nnkTupleConstr:
    for child in typ:
      if child.kind notin {nnkEmpty, nnkIdent} and holdsRefs(child, visited):
        return true
  of nnkIdentDefs:
    return holdsRefs(typ[^2], visited)
  of nnkDistinctTy:
    return holdsRefs(typ[0], visited)
  of nnkBracketExpr, nnkSym:
    for previous in visited:
      if sameType(typ, previous):
        return false
    visited.add typ
    if typ.kind == nnkBracketExpr:
      # thetos containers hide their elements behind raw pointers.
      if typ[0] == bindSym"TrieMap" or typ[0] == bindSym"TrieSet" or
          typ[0] == bindSym"TrieVec" or typ[0] == bindSym"Box" or typ[0].eqIdent("seq") or
          typ[0].eqIdent("array"):
        for i in 1 ..< typ.len:
          if holdsRefs(typ[i], visited):
            return true
        return false
    let impl = typ.getTypeImpl()
    if impl.kind != nnkSym or impl != typ:
      return holdsRefs(impl, visited)
  else:
    discard
  false

macro holdsNimRefs*(T: typedesc): bool =
  ## True when copying a `T` changes a Nim `ref` or closure reference count.
  var visited: seq[NimNode]
  newLit(holdsRefs(T.getTypeInst()[1], visited))
