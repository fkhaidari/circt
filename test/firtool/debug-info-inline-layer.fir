; RUN: firtool -g --ir-hw %s | FileCheck %s

; In an inlined layer block, the inliner attaches a dbg.scope to each debug op.
; Check that LowerLayers keeps them, one per instance.

; CHECK-LABEL: hw.module private @Top_Verification()
; CHECK-DAG:     [[X:%.+]] = dbg.scope "x", "Child"
; CHECK-DAG:     [[Y:%.+]] = dbg.scope "y", "Child"
; CHECK-DAG:     dbg.variable "n", {{%.+}} scope [[X]]
; CHECK-DAG:     dbg.variable "n", {{%.+}} scope [[Y]]
; CHECK-LABEL: hw.module @Top(

FIRRTL version 4.0.0
circuit Top : %[[
  {"class": "firrtl.passes.InlineAnnotation", "target": "~Top|Child"}
]]
  layer Verification, bind :
  module Child :
    input a : UInt<8>
    layerblock Verification :
      node n = a
  public module Top :
    input a : UInt<8>
    inst x of Child
    connect x.a, a
    inst y of Child
    connect y.a, a
