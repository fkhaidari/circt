// RUN: circt-translate %s --emit-uhdi --uhdi-format=2 2>/dev/null | FileCheck %s

// Dedup merged B into A: the variables it moved carry `dbg.origin`, and
// `dbg.origins` keeps B's location and class. Each source module binds into
// A on its own. Each instance is typed by the module it stood for and bound
// to the module that replaced it.

#locA = loc("A.scala":1:1)
#locB = loc("B.scala":1:1)
#locAlpha = loc("A.scala":5:10)
#locBeta = loc("B.scala":7:12)

hw.module private @A(in %p : i8, out q : i8) attributes {dbg.origins = {B = {loc = #locB, moduleinfo = {typeName = "ClassB"}}}} {
  %sum = comb.add %p, %p : i8
  %w = sv.wire {hw.verilogName = "w"} : !hw.inout<i8>
  sv.assign %w, %sum : i8
  %0 = sv.read_inout %w : !hw.inout<i8>
  %1 = sv.read_inout %w : !hw.inout<i8>
  dbg.variable "alpha", %0 : i8 loc(#locAlpha)
  dbg.variable "beta", %1 {dbg.origin = "B"} : i8 loc(#locBeta)
  hw.output %p : i8
} loc(#locA)

hw.module @Top(in %a : i8, out x : i8, out y : i8) {
  %ia.q = hw.instance "ia" @A(p: %a: i8) -> (q: i8) {dbg.moduleinfo = {typeName = "ClassA"}}
  %ib.q = hw.instance "ib" @A(p: %a: i8) -> (q: i8) {dbg.moduleinfo = {typeName = "ClassB"}, dbg.origin = "B"}
  hw.output %ia.q, %ib.q : i8, i8
}

// CHECK:      "types": [
// CHECK:          "kind": "module",
// CHECK-NEXT:     "module": "A"
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "kind": "module",
// CHECK-NEXT:     "module": "B"
// CHECK-NEXT:   }
// CHECK-NEXT: ],

// The class B claims is left over for A.
// CHECK:      "original": {
// CHECK-NEXT:   "A": {
// CHECK-NEXT:     "loc": [
// CHECK-NEXT:       0,
// CHECK-NEXT:       1,
// CHECK-NEXT:       1
// CHECK-NEXT:     ],
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "alpha": {
// CHECK:            "p": {
// CHECK:            "q": {
// CHECK:          "x-chisel": {
// CHECK-NEXT:       "typeName": "ClassA"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   "B": {
// CHECK-NEXT:     "loc": [
// CHECK-NEXT:       {{[0-9]+}},
// CHECK-NEXT:       1,
// CHECK-NEXT:       1
// CHECK-NEXT:     ],
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "beta": {
// CHECK:            "p": {
// CHECK:            "q": {
// CHECK:          "x-chisel": {
// CHECK-NEXT:       "typeName": "ClassB"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   "Top": {
// CHECK:            "ia": {
// CHECK:              "type": 1
// CHECK:            "ib": {
// CHECK:              "type": 2

// CHECK:      "generated": {
// CHECK-NEXT:   "A": {},
// CHECK-NEXT:   "Top": {}
// CHECK-NEXT: },

// CHECK:      "bindings": [
// CHECK-NEXT:   {
// CHECK-NEXT:     "generated": "A",
// CHECK-NEXT:     "original": "A",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "alpha": "w",
// CHECK-NEXT:       "p": "p",
// CHECK-NEXT:       "q": "q"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "generated": "A",
// CHECK-NEXT:     "original": "B",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "beta": "w",
// CHECK-NEXT:       "p": "p",
// CHECK-NEXT:       "q": "q"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "generated": "Top",
// CHECK-NEXT:     "original": "Top",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "a": "a",
// CHECK-NEXT:       "ia": {
// CHECK-NEXT:         "$inst": "ia",
// CHECK-NEXT:         "module": "A"
// CHECK-NEXT:       },
// CHECK-NEXT:       "ib": {
// CHECK-NEXT:         "$inst": "ib",
// CHECK-NEXT:         "module": "A"
// CHECK-NEXT:       },
// CHECK-NEXT:       "x": "x",
// CHECK-NEXT:       "y": "y"
// CHECK-NEXT:     }
// CHECK-NEXT:   }
// CHECK-NEXT: ]
