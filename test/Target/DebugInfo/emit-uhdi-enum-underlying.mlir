// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// The integer under an enum has no source name, and nothing could have given
// it one. It must not join an entry of the same width that the frontend did
// name, or it would carry that name.

hw.module @Top(in %op : i2, in %raw : i2) {
  %enum = dbg.enum %op, "Op", {ADD = 0 : i2, SUB = 1 : i2} fqn "Op" : i2
  %op_v = dbg.value %enum typeName "IO[Op]" : !dbg.enum
  dbg.variable "op", %op_v : !dbg.value
  %raw_v = dbg.value %raw typeName "IO[UInt<2>]" : i2
  dbg.variable "raw", %raw_v : !dbg.value
}

// CHECK:      "types": {
// CHECK:        "Op": {
// CHECK:          "underlyingTypeRef": "[[UNDER:uint2[^"]*]]"
// CHECK:        "[[UNDER]]": {
// CHECK-NEXT:     "kind": "uint",
// CHECK-NEXT:     "width": 2
// CHECK-NEXT:   },
// CHECK-NEXT:   "[[NAMED:uint2[^"]*]]": {
// CHECK-NEXT:     "kind": "uint",
// CHECK-NEXT:     "source": {
// CHECK-NEXT:       "name": "UInt<2>"

// CHECK:        "raw": {
// CHECK:          "typeRef": "[[NAMED]]"
