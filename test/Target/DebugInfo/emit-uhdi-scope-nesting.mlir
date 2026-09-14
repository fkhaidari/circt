// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// A scope nested in another one is emitted inside that scope, not alongside it
// in the hardware module both sit in.

hw.module @Top(in %en : i1, out o : i1) {
  %outer = dbg.scope "c0", "Child"
  %inner = dbg.scope "g0", "Grandchild" scope %outer
  dbg.variable "en", %en scope %inner : i1
  dbg.variable "o", %en scope %inner : i1
  hw.output %en : i1
}

// CHECK:      "modules":
// CHECK:        "Top":

// The outer scope hangs off the module and owns no variables of its own; the
// nested one hangs off the outer scope and owns both.
// CHECK:          "scopes": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "kind": "inline",
// CHECK:              "name": "c0"
// CHECK:              "variables": {}
// CHECK:              "scopes": [
// CHECK-NEXT:           {
// CHECK-NEXT:             "kind": "inline",
// CHECK:                  "name": "g0"
// CHECK:                  "variables": {
// CHECK-NEXT:               "en": {
// CHECK:                    "o": {
