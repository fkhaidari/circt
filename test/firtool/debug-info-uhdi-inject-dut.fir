; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.sv
; RUN: %python %S/check-uhdi-hierarchy.py inject %t.uhdi.json

; The source dut instance retains its class and ports across injected hardware.

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
