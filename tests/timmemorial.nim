import std/unittest

import immemorial

suite "immemorial":
  test "greets by name":
    check greet("Nim") == "hello, Nim"

