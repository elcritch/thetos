## Benchmark persistent JSON text and typed conversions on the same payload.
##
## Run all operations with `nim r -d:release benchmarks/bjsonutils.nim`.
## Pass an operation and iteration count to isolate it for a profiler.

import std/[json, monotimes, os, strutils, times]
import std/jsonutils as stdJsonUtils
import thetos/jsonutils as persistent

type
  Row = object
    id: int
    label: string
    active: bool
    score: float
    tags: seq[string]

  Document = object
    rows: seq[Row]

proc makeDocument(): Document =
  for i in 0 ..< 256:
    result.rows.add Row(
      id: i,
      label: "row " & $i & " with \"quotes\" and 🌍",
      active: i mod 3 == 0,
      score: float(i) / 7,
      tags: @["persistent", "json"],
    )

let operation =
  if paramCount() >= 1:
    paramStr(1)
  else:
    "all"
let iterations =
  if paramCount() >= 2:
    parseInt(paramStr(2))
  else:
    500
const Operations = [
  "all", "parse", "render", "encode", "decode", "edit", "history", "std-parse",
  "std-render", "std-encode", "std-decode", "std-edit", "std-history",
]
if operation notin Operations or iterations <= 0:
  quit "Usage: bjsonutils [" & Operations.join("|") & "] [iterations]"
let source = makeDocument()
let text = $stdJsonUtils.toJson(source)
let stdValue = json.parseJson(text)
let value = parseJsonValue(text)
echo text.len, " bytes, ", source.rows.len, " rows"

var checksum: int
template selected(name: string): bool =
  operation == "all" or operation == name

template bench(name: string, body: untyped) =
  if selected(name):
    var best = high(int64)
    for run in 0 ..< (if operation == "all": 7 else: 1):
      GC_fullCollect()
      let start = getMonoTime()
      block:
        body
      # Release the round's locals and charge any pending cycles to this round.
      GC_fullCollect()
      best = min(best, (getMonoTime() - start).inNanoseconds)
    echo name,
      " ", formatFloat(best.float / iterations.float / 1_000, ffDecimal, 2), " µs/op"

template repeatBench(name: string, measure: untyped) =
  bench(name):
    for i in 0 ..< iterations:
      checksum = checksum +% measure

repeatBench("std-parse", json.parseJson(text)["rows"].len)
repeatBench("parse", parseJsonValue(text)["rows"].len)
repeatBench("std-render", ($stdValue).len)
repeatBench("render", ($value).len)
repeatBench("std-encode", stdJsonUtils.toJson(source)["rows"].len)
repeatBench("encode", persistent.toJson(source)["rows"].len)
repeatBench("std-decode", stdJsonUtils.jsonTo(stdValue, Document).rows.len)
repeatBench("decode", persistent.jsonTo(value, Document).rows.len)

proc editRow(document: json.JsonNode, rowIndex, id: int) =
  document["rows"][rowIndex]["id"] = json.newJInt(id)

proc editRow(document: var JsonValue, rowIndex, id: int) =
  let rows = document["rows"]
  let row = rows[rowIndex].put("id", persistent.toJson(id))
  document["rows"] = rows.put(rowIndex, row)

template benchEdit(name: string, freshDocument: untyped) =
  if selected(name):
    var current = freshDocument
    var id = 0
    bench(name):
      for i in 0 ..< iterations:
        dec id
        current.editRow((i * 73) mod source.rows.len, id)
    let lastRow = ((iterations - 1) * 73) mod source.rows.len
    let actual = current["rows"][lastRow]["id"].getInt
    doAssert actual == id
    checksum = checksum +% int(actual)

benchEdit("std-edit", json.parseJson(text))
benchEdit("edit", parseJsonValue(text))

template benchHistory(name: string, initial, edit: untyped) =
  if selected(name):
    var retainedBytes: int
    bench(name):
      let before = getOccupiedMem()
      var history = newSeqOfCap[typeof(initial)](iterations + 1)
      history.add(initial)
      for i in 0 ..< iterations:
        let previous {.inject.} = history[^1]
        let rowIndex {.inject.} = (i * 73) mod source.rows.len
        let id {.inject.} = -(i + 1)
        history.add(edit)
      GC_fullCollect()
      retainedBytes = getOccupiedMem() - before
      checksum = checksum +% history.len
    echo name,
      "-retained ",
      formatFloat(retainedBytes.float / (1024 * 1024), ffDecimal, 2),
      " MiB"

benchHistory("std-history", stdValue):
  let changed = previous.copy()
  changed.editRow(rowIndex, id)
  changed

benchHistory("history", value):
  var changed = previous
  changed.editRow(rowIndex, id)
  changed

echo "Checksum ", checksum
