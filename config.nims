
import std/[os, strutils]

--mm:atomicArc
--threads:on

proc testFiles(): seq[string] =
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
      result.add testFile

# Container suites that do not need threads. They are rerun with
# --threads:off (plain reference counts) and, with -d:thetosTestLocal,
# against thetos/local.
const containerTests = ["tests/ttriemap.nim", "tests/ttrieset.nim", "tests/ttrievec.nim",
  "tests/tflexvec.nim", "tests/tbox.nim", "tests/timmstr.nim", "tests/tflexstr.nim"]

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
      for testFile in containerTests:
        exec("nim c -r --hints:off --skipParentCfg --threads:on --mm:" & mm & " " &
          mode & " --threads:off " & quoteShell(testFile))
        exec("nim c -r --hints:off --skipParentCfg --threads:on --mm:" & mm & " " &
          mode & " -d:thetosTestLocal " & quoteShell(testFile))

task testThreadsOff, "run container tests with --threads:off":
  for testFile in containerTests:
    exec("nim c -r --threads:off " & quoteShell(testFile))

task testLocal, "run container tests against thetos/local":
  for testFile in containerTests:
    exec("nim c -r -d:thetosTestLocal " & quoteShell(testFile))
