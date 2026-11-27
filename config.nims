
import std/[os, strutils]

--mm:atomicArc
--threads:on

proc testFiles(): seq[string] =
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
      result.add testFile

# Suites that do not need threads or Atom, rerun with -d:thetosSingleThread.
const singleThreadTests = ["tests/ttriemap.nim", "tests/ttrieset.nim", "tests/ttrievec.nim",
  "tests/tbox.nim"]

task test, "run unit tests":
  for testFile in testFiles():
    exec("nim c -r " & quoteShell(testFile))

task testAll, "run unit tests under arc, orc and atomicArc, debug and release":
  # --skipParentCfg keeps this file from forcing --mm:atomicArc.
  for mm in ["arc", "orc", "atomicArc"]:
    for mode in ["", "-d:release"]:
      for testFile in testFiles():
        exec("nim c -r --hints:off --skipParentCfg --threads:on --mm:" & mm & " " &
          mode & " " & quoteShell(testFile))
      for testFile in singleThreadTests:
        exec("nim c -r --hints:off --skipParentCfg --threads:on --mm:" & mm & " " &
          mode & " -d:thetosSingleThread " & quoteShell(testFile))

task testSingleThread, "run container tests with -d:thetosSingleThread":
  for testFile in singleThreadTests:
    exec("nim c -r -d:thetosSingleThread " & quoteShell(testFile))
