; RUN: firtool -g --ir-hw %s | FileCheck %s
; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.g.sv
; RUN: FileCheck %s --check-prefix=UHDI < %t.uhdi.json
; RUN: firtool --ir-hw %s | FileCheck %s --check-prefix=NODEBUG --implicit-check-not=sourceName
; RUN: firtool %s --strip-debug-info -o %t.sv
; RUN: sed '/DebugSourceNameAnnotation/d' %s | firtool --format=fir --strip-debug-info -o %t.noanno.sv
; RUN: diff %t.sv %t.noanno.sv

; DebugSourceNameAnnotation gives a black box a source class. BB0 and BB1 share
; a Verilog module but have different classes, so under -g they do not merge.
; Without -g the class names are dropped before Dedup, the two merge, and the
; Verilog matches the same input without the annotations.

; CHECK: hw.module.extern private @BB0({{.*}}) attributes {sourceName = "my.pkg.Adder", verilogName = "BB"}
; CHECK: hw.module.extern private @BB1({{.*}}) attributes {sourceName = "my.pkg.Other", verilogName = "BB"}

; An inline black box becomes sv.verbatim.module and keeps its class too.
; CHECK: sv.verbatim.module private @Xor({{.*}}sourceName = "my.pkg.Xor"

; NODEBUG:     hw.module.extern private @BB0(
; NODEBUG-NOT: hw.module.extern private @BB1(

; EmitUHDI reads the class of an sv.verbatim.module too.
; UHDI-LABEL: "types": [
; UHDI:         "module": "Xor",
; UHDI-NEXT:    "name": "my.pkg.Xor"

FIRRTL version 4.0.0
circuit Top : %[[
  {"class": "circt.DebugSourceNameAnnotation", "target": "~Top|BB0", "name": "my.pkg.Adder"},
  {"class": "circt.DebugSourceNameAnnotation", "target": "~Top|BB1", "name": "my.pkg.Other"},
  {"class": "circt.DebugSourceNameAnnotation", "target": "~Top|Xor", "name": "my.pkg.Xor"},
  {"class": "firrtl.transforms.BlackBoxInlineAnno", "target": "~Top|Xor", "name": "Xor.sv",
   "text": "module Xor(input [7:0] in, output [7:0] out); assign out = ~in; endmodule\n"}
]]
  extmodule BB0 :
    input in : UInt<8>
    output out : UInt<8>
    defname = BB
  extmodule BB1 :
    input in : UInt<8>
    output out : UInt<8>
    defname = BB
  extmodule Xor :
    input in : UInt<8>
    output out : UInt<8>
    defname = Xor
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    output c : UInt<8>
    output d : UInt<8>
    inst b0 of BB0
    inst b1 of BB1
    inst x of Xor
    connect x.in, a
    connect d, x.out
    connect b0.in, a
    connect b1.in, a
    connect b, b0.out
    connect c, b1.out
    intrinsic(circt_debug_moduleinfo<typeName = "Top">)
