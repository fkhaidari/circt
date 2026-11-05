; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.sv
; RUN: FileCheck %s < %t.uhdi.json

; InjectDUTHierarchy moves the body of DUT, with its dbg.moduleinfo, into
; Wrapper and builds a new DUT around it. The new DUT has no class, so it is
; hoisted. The source instance `dut` shows up as Wrapper's instance name,
; reached through `dut`.

; CHECK-LABEL: "original": {
; CHECK:         "Wrapper": {
; CHECK-NEXT:      "name": "DUT",
; CHECK:         "Top": {
; CHECK-NOT:     "DUT": {
; CHECK-LABEL: "generated": {
; CHECK-LABEL: "bindings": [
; CHECK:           "Wrapper": {
; CHECK-NEXT:        "$inst": "dut.Wrapper",
; CHECK-NEXT:        "module": "Wrapper"

FIRRTL version 4.0.0
circuit Top : %[[
  {"class": "sifive.enterprise.firrtl.MarkDUTAnnotation", "target": "~Top|DUT"},
  {"class": "sifive.enterprise.firrtl.InjectDUTHierarchyAnnotation", "name": "Wrapper"}
]]
  module DUT :
    input a : UInt<8>
    output b : UInt<8>
    connect b, a
    intrinsic(circt_debug_moduleinfo<typeName = "DUT">)
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    inst dut of DUT
    connect dut.a, a
    connect b, dut.b
    intrinsic(circt_debug_moduleinfo<typeName = "Top">)
