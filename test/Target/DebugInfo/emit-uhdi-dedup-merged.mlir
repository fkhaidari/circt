// RUN: circt-translate %s --emit-uhdi | FileCheck %s \
// RUN:   --implicit-check-not=B.scala --implicit-check-not=beta \
// RUN:   --implicit-check-not=deep --implicit-check-not='.1"'
// RUN: circt-translate %s --emit-hgldd | FileCheck %s --check-prefix=HGLDD \
// RUN:   --implicit-check-not=B.scala --implicit-check-not=beta \
// RUN:   --implicit-check-not=deep --implicit-check-not=p_0

// Dedup merged B into A and moved B's debug ops along: the root ops carry
// `dbg.origin`. Layout 1 and HGLDD have no place for B, so they describe A as
// if B's debug ops had been erased with it.

#locA = loc("A.scala":1:1)
#locB = loc("B.scala":1:1)
#locAlpha = loc("A.scala":5:10)
#locBeta = loc("B.scala":7:12)

hw.module private @A(in %p : i8, out q : i8) attributes {dbg.origins = {B = {loc = #locB, moduleinfo = {typeName = "ClassB"}}}} {
  %w = sv.wire {hw.verilogName = "w"} : !hw.inout<i8>
  sv.assign %w, %p : i8
  %0 = sv.read_inout %w : !hw.inout<i8>
  dbg.variable "p", %p : i8 loc(#locA)
  dbg.variable "alpha", %0 : i8 loc(#locAlpha)
  %s = dbg.scope "h", "H" loc(#locA)
  dbg.variable "inner", %0 scope %s : i8 loc(#locAlpha)
  dbg.variable "p", %p {dbg.origin = "B"} : i8 loc(#locB)
  dbg.variable "beta", %0 {dbg.origin = "B"} : i8 loc(#locBeta)
  %sb = dbg.scope "h", "H" {dbg.origin = "B"} loc(#locBeta)
  %sbn = dbg.scope "n", "N" scope %sb loc(#locBeta)
  dbg.variable "inner", %0 scope %sb {dbg.origin = "B"} : i8 loc(#locBeta)
  dbg.variable "deep", %0 scope %sbn {dbg.origin = "B"} : i8 loc(#locBeta)
  hw.output %p : i8
} loc(#locA)

// CHECK:      "modules": {
// CHECK-NEXT:   "A": {
// CHECK:          "variables": {
// CHECK-NEXT:       "alpha": {
// CHECK:            "p": {
// CHECK:            "q": {
// CHECK:          "scopes": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "kind": "inline",
// CHECK:                "name": "h"
// CHECK:              "variables": {
// CHECK-NEXT:           "inner": {
// CHECK-NOT:      "kind"
// CHECK:          {{^      \]$}}

// HGLDD:      "var_name": "p"
// HGLDD-NOT:  "var_name": "p"
// HGLDD:      "var_name": "alpha"
// HGLDD:      "name": "h"
// HGLDD:      "var_name": "inner"
// HGLDD-NOT:  "var_name"
// HGLDD:      "children": []
// HGLDD-NOT:  "name"
// HGLDD-NOT:  "var_name"
