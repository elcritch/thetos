
import std/[os, strutils]

--mm:atomicArc
--threads:on

proc testFiles(): seq[string] =
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
      result.add testFile

# Container suites that do not need threads or Atom. They are rerun with
# -d:thetosSingleThread and, with -d:thetosTestLocal, against thetos/local.
const singleThreadTests = ["tests/ttriemap.nim", "tests/ttrieset.nim", "tests/ttrievec.nim",
  "tests/tflexvec.nim", "tests/tbox.nim"]

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
        exec("nim c -r --hints:off --skipParentCfg --threads:on --mm:" & mm & " " &
          mode & " -d:thetosTestLocal " & quoteShell(testFile))

task testSingleThread, "run container tests with -d:thetosSingleThread":
  for testFile in singleThreadTests:
    exec("nim c -r -d:thetosSingleThread " & quoteShell(testFile))

task testLocal, "run container tests against thetos/local":
  for testFile in singleThreadTests:
    exec("nim c -r -d:thetosTestLocal " & quoteShell(testFile))
