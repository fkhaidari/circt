; RUN: firtool -g --ir-verilog %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s

; Dedup merges A and B, but each keeps the name and language data of its port.
; BundleA carries its x-chisel data; BundleB has none.

; CHECK:      "types":[{"kind":"uint","width":8},
; CHECK-SAME: {"fields":[{"name":"a","type":0}],"kind":"struct","name":"BundleA","x-chisel":{"k":1}},
; CHECK-SAME: {"fields":[{"name":"a","type":0}],"kind":"struct","name":"BundleB"}

; Each port refers to its own entry: BundleA is 1, BundleB is 2.

; CHECK:      "original":{"A":{
; CHECK-SAME: "io":{"type":1,
; CHECK-SAME: "B":{
; CHECK-SAME: "io":{"type":2,

FIRRTL version 4.0.0
circuit Top :
  module A :
    input io : { a : UInt<8> }
    intrinsic(circt_debug_type<target = "io", name = "BundleA", ext_chisel = "{\"k\":1}">)
  module B :
    input io : { a : UInt<8> }
    intrinsic(circt_debug_type<target = "io", name = "BundleB">)
  public module Top :
    input x : { a : UInt<8> }
    inst a of A
    inst b of B
    connect a.io, x
    connect b.io, x
