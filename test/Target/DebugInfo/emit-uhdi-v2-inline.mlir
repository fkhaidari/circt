// RUN: circt-translate %s --emit-uhdi --uhdi-format=2 2>/dev/null | FileCheck %s

// An inlined instance binds the module it inlined into the module it was
// inlined into, at its dotted instance path. A scope nested in another one
// extends the path.

#locMid = loc("Top.scala":3:5)
#locLeaf = loc("Mid.scala":7:9)
#locX = loc("Leaf.scala":2:3)
#locY = loc("Mid.scala":2:3)

hw.module @Top(in %a : i8, out o : i8) {
  %mid = dbg.scope "m", "Mid" loc(#locMid)
  %leaf = dbg.scope "h", "Leaf" scope %mid loc(#locLeaf)
  dbg.variable "y", %a scope %mid : i8 loc(#locY)
  dbg.variable "x", %a scope %leaf : i8 loc(#locX)
  hw.output %a : i8
}

// CHECK:      "source": {
// CHECK-NEXT:   "Leaf": {
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "x": {
// CHECK:          "Mid": {
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "y": {
// CHECK:          "Top": {

// CHECK:      "bindings": [
// CHECK-NEXT:   {
// CHECK-NEXT:     "source": "Top",
// CHECK-NEXT:     "target": "Top",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "a": "a",
// CHECK-NEXT:       "o": "o"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "at": [
// CHECK-NEXT:       {{[0-9]+}},
// CHECK-NEXT:       3,
// CHECK-NEXT:       5
// CHECK-NEXT:     ],
// CHECK-NEXT:     "scope": "m",
// CHECK-NEXT:     "source": "Mid",
// CHECK-NEXT:     "target": "Top",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "y": "a"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "at": [
// CHECK-NEXT:       {{[0-9]+}},
// CHECK-NEXT:       7,
// CHECK-NEXT:       9
// CHECK-NEXT:     ],
// CHECK-NEXT:     "scope": "m.h",
// CHECK-NEXT:     "source": "Leaf",
// CHECK-NEXT:     "target": "Top",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "x": "a"
// CHECK-NEXT:     }
// CHECK-NEXT:   }
// CHECK-NEXT: ]
