// RUN: circt-translate %s --emit-uhdi --uhdi-format=2 2>/dev/null | FileCheck %s

// A variable whose value has no signal of its own is bound to the expression
// that computes it, in HGLDD's operator names. Constants inside an expression
// keep their full width.

#loc = loc("E.scala":1:1)

hw.module @E(in %a : i8, in %b : i8, in %s : i1, out o : i8) {
  %c1_i1 = hw.constant 1 : i1
  %c3_i4 = hw.constant 3 : i4
  %notS = comb.xor %s, %c1_i1 : i1
  dbg.variable "notS", %notS : i1 loc(#loc)
  %lo = comb.extract %a from 0 : (i8) -> i4
  %cat = comb.concat %lo, %c3_i4 : i4, i4
  dbg.variable "cat", %cat : i8 loc(#loc)
  %rep = comb.replicate %s : (i1) -> i4
  dbg.variable "rep", %rep : i4 loc(#loc)
  %eq = comb.icmp eq %a, %b : i8
  %sel = comb.mux %eq, %a, %b : i8
  dbg.variable "sel", %sel : i8 loc(#loc)
  hw.output %a : i8
} loc(#loc)

// The profile is listed only because an expression is used.
// CHECK:      "profiles": [
// CHECK-NEXT:   "x-chisel",
// CHECK-NEXT:   "expr"
// CHECK-NEXT: ],

// CHECK:      "bindings": [
// CHECK:        "vars": {
// CHECK:          "cat": {
// CHECK-NEXT:       "$op": "{}",
// CHECK-NEXT:       "args": [
// CHECK-NEXT:         {
// CHECK-NEXT:           "$op": "[]",
// CHECK-NEXT:           "args": [
// CHECK-NEXT:             "a",
// CHECK-NEXT:             3,
// CHECK-NEXT:             0
// CHECK-NEXT:           ]
// CHECK-NEXT:         },
// CHECK-NEXT:         {
// CHECK-NEXT:           "$const": "0b0011"
// CHECK-NEXT:         }
// CHECK-NEXT:       ]
// CHECK-NEXT:     },
// CHECK-NEXT:     "notS": {
// CHECK-NEXT:       "$op": "^",
// CHECK-NEXT:       "args": [
// CHECK-NEXT:         "s",
// CHECK-NEXT:         {
// CHECK-NEXT:           "$const": "0b1"
// CHECK-NEXT:         }
// CHECK-NEXT:       ]
// CHECK-NEXT:     },
// CHECK-NEXT:     "o": "o",
// CHECK-NEXT:     "rep": {
// CHECK-NEXT:       "$op": "R{}",
// CHECK-NEXT:       "args": [
// CHECK-NEXT:         4,
// CHECK-NEXT:         "s"
// CHECK-NEXT:       ]
// CHECK-NEXT:     },
// CHECK-NEXT:     "s": "s",
// CHECK-NEXT:     "sel": {
// CHECK-NEXT:       "$op": "?:",
// CHECK-NEXT:       "args": [
// CHECK-NEXT:         {
// CHECK-NEXT:           "$op": "==",
// CHECK-NEXT:           "args": [
// CHECK-NEXT:             "a",
// CHECK-NEXT:             "b"
// CHECK-NEXT:           ]
// CHECK-NEXT:         },
// CHECK-NEXT:         "a",
// CHECK-NEXT:         "b"
// CHECK-NEXT:       ]
// CHECK-NEXT:     }
