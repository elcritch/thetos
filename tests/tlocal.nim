## `thetos/local`: thread-local containers with plain reference counts, used
## next to the atomic ones. The container suites also run against
## `thetos/local` with `-d:thetosTestLocal`.

import std/[unittest, os, strutils]
import thetos
import thetos/local
import thetos/private/reftraits

const
  testDir = currentSourcePath().parentDir()
  src = testDir.parentDir() / "src"
  fixture = testDir / "fixtures" / "localatom.nim"
  message = "holds thread-local containers"

template compileFixture(flags: static string): untyped =
  gorgeEx(
    quoteShell(getCurrentCompilerExe()) & " check --hints:off --skipParentCfg " & flags &
      " --path:" & quoteShell(src) & " " & quoteShell(fixture)
  )

suite "thetos/local":
  test "local and atomic containers are distinct types":
    check not (local.TrieMap[int, int] is thetos.TrieMap[int, int])
    check not (local.TrieSet[int] is thetos.TrieSet[int])
    check not (local.TrieVec[int] is thetos.TrieVec[int])
    check not (local.FlexVec[int] is thetos.FlexVec[int])
    check not (local.Box[int] is thetos.Box[int])
    check not (local.ImmStr is thetos.ImmStr)
    check not (local.FlexStr is thetos.FlexStr)

  test "both kinds work in one program":
    var scratch = local.toTrieMap({"a": 1})
    var shared = thetos.toTrieMap({"a": 1})
    scratch["b"] = 2 # procs resolve by argument type
    shared["c"] = 3
    check scratch.len == 2 and shared.len == 2
    check "b" in scratch and "b" notin shared
    var changes = 0
    for d in diff(scratch, scratch.erase("a")):
      check d.kind == dkRemoved
      inc changes
    check changes == 1

    let lv = local.toFlexVec([1, 2, 3]) & local.toFlexVec([4])
    let tv = thetos.toTrieVec([1, 2, 3])
    check lv.len == 4 and lv[3] == 4 and tv.len == 3
    # `thetos.box` names the re-exported module, so qualify with `box.box`.
    check local.box("x")[] == box.box("x")[]

  test "thread-local containers are detected at any depth":
    type
      LocalValue = local.TrieVec[int]
      SharedMap = thetos.TrieMap[int, LocalValue]
      LocalSeq = seq[LocalValue]
      Sequence[T] = seq[T]

    check holdsLocalContainers(local.TrieMap[int, int])
    check holdsLocalContainers(local.Box[string])
    check holdsLocalContainers(local.ImmStr)
    check holdsLocalContainers(local.FlexStr)
    check holdsLocalContainers(thetos.TrieMap[thetos.ImmStr, local.ImmStr])
    check not holdsLocalContainers(thetos.ImmStr)
    check not holdsLocalContainers(thetos.FlexStr)
    check holdsLocalContainers(thetos.TrieMap[int, local.TrieVec[int]])
    check holdsLocalContainers(seq[local.FlexVec[int]])
    check holdsLocalContainers(LocalValue)
    check holdsLocalContainers(SharedMap)
    check holdsLocalContainers(LocalSeq)
    check holdsLocalContainers(Sequence[LocalValue])
    check holdsLocalContainers(array[2, LocalValue])
    check not holdsLocalContainers(thetos.TrieMap[int, thetos.TrieVec[int]])
    check not holdsLocalContainers(seq[int])

  test "Atom rejects thread-local containers":
    const arc = compileFixture("--threads:on --mm:arc")
    check arc.exitCode != 0
    check message in arc.output
    const atomicArc = compileFixture("--threads:on --mm:atomicArc")
    check atomicArc.exitCode != 0
    check message in atomicArc.output
    const nested = compileFixture("--threads:on --mm:atomicArc -d:nested")
    check nested.exitCode != 0
    check message in nested.output
    const aliased = compileFixture("--threads:on --mm:atomicArc -d:localAlias")
    check aliased.exitCode != 0
    check message in aliased.output
    const throughRef = compileFixture("--threads:on --mm:atomicArc -d:localRef")
    check throughRef.exitCode != 0
    check message in throughRef.output
    const throughObject = compileFixture("--threads:on --mm:atomicArc -d:shadowedSeq")
    check throughObject.exitCode != 0
    check message in throughObject.output

  test "Atom accepts an unrelated type named Box":
    type
      Status = object
        rc: int

      Box[T] = object
        status: ptr Status
        value: T

    var a = initAtom(Box[int](value: 42))
    check a.load().value == 42
