; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.g.sv
; RUN: FileCheck %s < %t.uhdi.json
; RUN: FileCheck %s --check-prefix=VERILOG < %t.g.sv
; RUN: firtool %s -o %t.sv
; RUN: FileCheck %s --check-prefix=VERILOG < %t.sv

; Child is inlined into Top. Its instance `leaf` moves into Top, but UHDI
; shows it under the inlined Child.

; CHECK-LABEL: "original": {
; CHECK:         "Top": {
; CHECK:           "child": {
; CHECK-NOT:       "child_leaf": {
; CHECK:         "Child": {
; CHECK:           "child_leaf": {
; CHECK-LABEL: "bindings": [
; CHECK:         "original": "Child",
; CHECK-NEXT:    "generated": "Top",
; CHECK-NEXT:    "inline_path": [
; CHECK-NEXT:      "child"
; CHECK-NEXT:    ],
; CHECK:           "child_leaf": {
; CHECK-NEXT:        "$inst": "child_leaf",
; CHECK-NEXT:        "module": "Leaf"

; The scope does not change the instance in Verilog.
; VERILOG-LABEL: module Top(
; VERILOG:         Leaf child_leaf (
; VERILOG-NEXT:      .a (a),
; VERILOG-NEXT:      .b ({{.+}})
; VERILOG-NEXT:    );

FIRRTL version 4.0.0
circuit Top : %[[
  {"class": "firrtl.passes.InlineAnnotation", "target": "~Top|Child"}
]]
  module Leaf :
    input a : UInt<8>
    output b : UInt<8>
    connect b, a
    intrinsic(circt_debug_moduleinfo<typeName = "Leaf">)
  module Child :
    input a : UInt<8>
    output b : UInt<8>
    inst leaf of Leaf
    connect leaf.a, a
    connect b, leaf.b
    intrinsic(circt_debug_moduleinfo<typeName = "Child">)
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    inst child of Child
    connect child.a, a
    connect b, child.b
    intrinsic(circt_debug_moduleinfo<typeName = "Top">)
