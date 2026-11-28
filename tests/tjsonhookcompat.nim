## Run with -d:thetosTestStdJson to check the same hooks against std/jsonutils.
import std/unittest
when defined(thetosTestStdJson):
  import std/[json, jsonutils]
else:
  import thetos/jsonutils

type Identifier = distinct string

proc toJsonHook(value: Identifier, opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["identifier"] = newJString(string(value))

proc fromJsonHook(value: var Identifier, node: JsonNode, opt: Joptions) =
  value = Identifier(node["identifier"].getStr)

suite "Hook source compatibility":
  test "nested hooks can switch JSON modules":
    let node = toJson(@[Identifier("example")])
    check node[0]["identifier"].getStr == "example"
    check string(jsonTo(node, seq[Identifier])[0]) == "example"
