## Benchmark persistent JSON text and typed conversions on the same payload.
##
## Run all operations with `nim r -d:release benchmarks/bjsonutils.nim`.
## Pass an operation and iteration count to isolate it for a profiler.

import std/[json, monotimes, os, strutils, times]
import std/jsonutils as stdJsonUtils
import thetos/flexvec
import thetos/jsonutils as persistent

type
  Row = object
    id: int
    label: string
    active: bool
    score: float
    tags: seq[string]

  Document = object
    rows: FlexVec[Row]

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
if operation notin ["all", "parse", "render", "encode", "decode"] or iterations <= 0:
  quit "Usage: bjsonutils [all|parse|render|encode|decode] [iterations]"
let source = makeDocument()
let text = $stdJsonUtils.toJson(source)
let value = parseJsonValue(text)
echo text.len, " bytes, ", source.rows.len, " rows"

var checksum: int
template bench(name: string, body: untyped) =
  if operation == "all" or operation == name:
    var best = high(int64)
    for run in 0 ..< (if operation == "all": 7 else: 1):
      let start = getMonoTime()
      for i in 0 ..< iterations:
        checksum = checksum +% body
      best = min(best, (getMonoTime() - start).inNanoseconds)
    echo name,
      " ", formatFloat(best.float / iterations.float / 1_000, ffDecimal, 2), " µs/op"

bench("parse", parseJsonValue(text)["rows"].len)
bench("render", ($value).len)
bench("encode", persistent.toJson(source)["rows"].len)
bench("decode", persistent.jsonTo(value, Document).rows.len)
echo "Checksum ", checksum
