// RUN: circt-translate %s --emit-uhdi --uhdi-format=2 2>/dev/null | FileCheck %s
// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s --check-prefix=V1

// Lowering makes every integer signless and a clock a plain bit; `dbg.ground`
// on the op that takes a leaf says what it was. A string covers all operands,
// an array names one kind per operand. A `dbg.value` wrapper takes the leaf
// itself, so the kind sits on it.

#loc = loc("G.scala":1:1)

hw.module @G(in %clk : i1, in %a : i8, in %b : i8, in %c : i8) {
  dbg.variable "clk", %clk {dbg.ground = "clock"} : i1 loc(#loc)
  %w = dbg.value %a typeName "SInt<8>" {dbg.ground = "sint"} : i8
  dbg.variable "s", %w : !dbg.value loc(#loc)
  %st = dbg.struct {"x": %a, "y": %b} {dbg.ground = ["sint", ""]} : i8, i8
  dbg.variable "st", %st : !dbg.struct loc(#loc)
  %arr = dbg.array [%b, %c] {dbg.ground = "sint"} : i8
  dbg.variable "arr", %arr : !dbg.array loc(#loc)
  dbg.variable "u", %c : i8 loc(#loc)
} loc(#loc)

// CHECK:      "types": [
// CHECK-NEXT:   {
// CHECK-NEXT:     "kind": "sint",
// CHECK-NEXT:     "name": "SInt<8>",
// CHECK-NEXT:     "width": 8
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "elem": 0,
// CHECK:        {
// CHECK-NEXT:     "kind": "clock"
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "kind": "uint",
// CHECK-NEXT:     "width": 8
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "fields": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "name": "x",
// CHECK-NEXT:         "type": 0
// CHECK-NEXT:       },
// CHECK-NEXT:       {
// CHECK-NEXT:         "name": "y",
// CHECK-NEXT:         "type": 3

// CHECK:      "vars": {
// CHECK-NEXT:   "arr": {
// CHECK:          "type": 1
// CHECK:        "clk": {
// CHECK:          "type": 2
// CHECK:        "s": {
// CHECK:          "type": 0
// CHECK:        "u": {
// CHECK:          "type": 3

// Layout 1 keeps the integer types.
// V1-NOT: "sint"
// V1-NOT: "clock"
