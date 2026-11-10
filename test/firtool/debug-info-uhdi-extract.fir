; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.sv
; RUN: FileCheck %s < %t.uhdi.json

; ExtractInstances moves the blackbox `bb` out of Child up to Top. UHDI shows
; it under Top, not under Child where the source has it.

; CHECK-LABEL: "original": {
; CHECK:         "Child": {
; CHECK-NOT:       "bb": {
; CHECK:         "DUT": {
; CHECK:         "Top": {
; CHECK:             "bb": {
; CHECK-LABEL: "bindings": [
; CHECK:         "original": "Top",
; CHECK:           "bb": {
; CHECK-NEXT:        "$inst": "bb",
; CHECK-NEXT:        "module": "BB"

FIRRTL version 4.0.0
circuit Top : %[[
  {"class": "sifive.enterprise.firrtl.MarkDUTAnnotation", "target": "~Top|DUT"},
  {"class": "sifive.enterprise.firrtl.ExtractBlackBoxAnnotation", "target": "~Top|BB", "filename": "BlackBoxes.txt", "prefix": "bb"}
]]
  extmodule BB :
    input in : UInt<8>
    output out : UInt<8>
    defname = BB
  module Child :
    input a : UInt<8>
    output b : UInt<8>
    inst bb of BB
    connect bb.in, a
    connect b, bb.out
    intrinsic(circt_debug_moduleinfo<typeName = "Child">)
  module DUT :
    input a : UInt<8>
    output b : UInt<8>
    inst child of Child
    connect child.a, a
    connect b, child.b
    intrinsic(circt_debug_moduleinfo<typeName = "DUT">)
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    inst dut of DUT
    connect dut.a, a
    connect b, dut.b
    intrinsic(circt_debug_moduleinfo<typeName = "Top">)
