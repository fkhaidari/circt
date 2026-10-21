; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.json %s \
; RUN:   -o %t.sv && FileCheck %s --input-file=%t.json

; Inlining `Neg` leaves `~x` to drive `out` directly. ExportVerilog clones the
; expression for each user, so the `out` variable reads a copy of the
; `hw.output` operand. It is still the port, not a second variable next to it.

FIRRTL version 4.0.0
circuit Top: %[[
  { "class": "firrtl.passes.InlineAnnotation", "target": "~Top|Neg" }
]]
  module Neg :
    input x : UInt<4>
    output y : UInt<4>
    connect y, not(x)
    intrinsic(circt_debug_var<typeName = "IO[UInt<4>]", name = "x">, x)
    intrinsic(circt_debug_var<typeName = "IO[UInt<4>]", name = "y">, y)

  public module Top :
    input a : UInt<4>
    output out : UInt<4>
    inst neg of Neg
    connect neg.x, a
    connect out, neg.y
    intrinsic(circt_debug_var<typeName = "IO[UInt<4>]", name = "out">, out) @[Top.scala 4:15]

; CHECK-LABEL: "original": {
; CHECK:       "Top": {
; CHECK:         "out": {
; CHECK-NEXT:      "dir": "out",
; CHECK-NEXT:      "loc":
; CHECK-NOT:     "out.1"
; CHECK-LABEL: "bindings": [
; CHECK:         "original": "Top",
; CHECK-NEXT:    "vars": {
; CHECK-NOT:       "out.1"
; CHECK:           "out": "out"
; CHECK-NOT:       "out.1"
; CHECK:         "original": "Neg",
