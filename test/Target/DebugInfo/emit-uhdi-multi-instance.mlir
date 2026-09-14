// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s
// RUN: circt-translate %s --emit-uhdi 2>&1 >/dev/null | FileCheck %s --check-prefix=DIAG --allow-empty

// Two instances of one module, each with its own scope. The variables under
// them must stay apart: sharing a name across instances is the normal case,
// and merging them would make the document describe one instance twice.

hw.module @Parent(in %en : i1, in %valid : i1, out o : i1) {
  %sc0 = dbg.scope "c0", "Child"
  dbg.variable "en", %en scope %sc0 : i1

  %sc1 = dbg.scope "c1", "Child"
  dbg.variable "en", %valid scope %sc1 : i1

  dbg.variable "en", %en : i1
  dbg.variable "o", %en : i1

  hw.output %en : i1
}

// CHECK:      "modules":
// CHECK:        "Parent":

// The module keeps its own pair; each instance scope is a sibling entry under
// it holding one `en` bound to a different signal.
// CHECK:          "variables": {
// CHECK-NEXT:       "en": {
// CHECK:            "o": {

// CHECK:          "scopes": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "kind": "inline",
// CHECK:              "name": "c0"
// CHECK:              "variables": {
// CHECK-NEXT:           "en": {
// CHECK:                  "target": {
// CHECK-NEXT:               "verilog": "en"
// CHECK:              "kind": "inline",
// CHECK:              "name": "c1"
// CHECK:              "variables": {
// CHECK-NEXT:           "en": {
// CHECK:                  "target": {
// CHECK-NEXT:               "verilog": "valid"

// Same name in three scopes is not a collision.
// DIAG-NOT: warning:
