# Persistent JSON benchmarks

The benchmark uses a 31,129-byte document with 256 records containing
strings, booleans, integers, floats, and arrays. It measures parsing into
`JsonValue`, rendering that value, and conversions between `JsonValue`
and a typed Nim record containing a `FlexVec`.

Measured with Nim 2.2.12 on an Apple M3 Pro using `-d:release` and the
repository's atomic ARC configuration. Each result is the median of three
invocations, with each invocation reporting the best of seven runs of
500 operations.

| Operation | Baseline `3d2041c` | Direct text I/O |
|---|---:|---:|
| Parse JSON text | 398.9 µs | 238.7 µs |
| Render JSON text | 256.2 µs | 84.1 µs |
| Encode a typed Nim value | 212.7 µs | 214.9 µs |
| Decode into a typed Nim value | 198.8 µs | 205.0 µs |

Sampling the baseline with macOS `sample` showed both text operations
spending time constructing and traversing intermediate `JsonNode`
trees. The parser now uses the stdlib tokenizer to fill the persistent
tree directly. The renderer writes the persistent tree to one output
buffer and appends unescaped runs of bytes together. Typed conversions
use the stdlib engine for its options and hook support.

```sh
nim r -d:release benchmarks/bjsonutils.nim
nim c -d:release --debugger:native -o:/tmp/bjsonutils benchmarks/bjsonutils.nim
/tmp/bjsonutils parse 30000 &
sample "$!" 2 1 -file /tmp/json-parse-sample.txt
```
