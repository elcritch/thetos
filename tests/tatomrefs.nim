## `Atom[T]` refuses `T` holding Nim refs or closures when their reference
## counts are not atomic (`--mm:arc`/`--mm:orc` with threads).

import std/[unittest, os, strutils]

const
  testDir = currentSourcePath().parentDir()
  src = testDir.parentDir() / "src"
  fixture = testDir / "fixtures" / "refatom.nim"
  message = "holds Nim refs or closures"

template compileFixture(flags: static string): untyped =
  gorgeEx(
    quoteShell(getCurrentCompilerExe()) & " check --hints:off --skipParentCfg " & flags &
      " --path:" & quoteShell(src) & " " & quoteShell(fixture)
  )

suite "Atom rejects non-atomic refs":
  test "arc with threads":
    const res = compileFixture("--threads:on --mm:arc")
    check res.exitCode != 0
    check message in res.output

  test "orc with threads":
    const res = compileFixture("--threads:on --mm:orc")
    check res.exitCode != 0
    check message in res.output

  test "atomicArc is allowed":
    const res = compileFixture("--threads:on --mm:atomicArc")
    check res.exitCode == 0

  test "arc without threads is allowed":
    const res = compileFixture("--threads:off --mm:arc")
    check res.exitCode == 0

  test "opt-out define":
    const res = compileFixture("--threads:on --mm:arc -d:thetosUnsafeRefAtom")
    check res.exitCode == 0
