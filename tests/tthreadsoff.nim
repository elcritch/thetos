## Reference counts follow `--threads`: atomic with threads, plain without.
## The fixture is built with `--threads:off` here because the suite itself
## normally runs with threads on. CI also runs the container suites with
## `--threads:off`.

import std/[unittest, os, strutils]
import thetos/private/core

const
  testDir = currentSourcePath().parentDir()
  src = testDir.parentDir() / "src"
  fixture = testDir / "fixtures" / "threadsoff.nim"

suite "reference counts follow --threads":
  test "this build":
    check thetosAtomicRc == compileOption("threads")

  test "a --threads:off build uses plain counts, frees everything and has Atom":
    const res = gorgeEx(
      quoteShell(getCurrentCompilerExe()) & " r --hints:off --skipParentCfg" &
        " --threads:off -d:thetosTrackAllocs --path:" & quoteShell(src) & " " &
        quoteShell(fixture)
    )
    check res.exitCode == 0
    check "threads-off ok" in res.output
    if res.exitCode != 0:
      echo res.output
