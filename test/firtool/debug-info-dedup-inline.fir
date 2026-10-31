; RUN: firtool -g --ir-verilog %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s

; Dedup merges B into A, whose instances of W have different names. W is
; inlined once into A, and both A and B see its variables under their own
; instance name.

; CHECK:      "bindings":[
; CHECK-SAME: {"original":"W","generated":"A","inline_path":["foo"],"vars":{"x":"x","y":{"$optimized_out":true},"wv":{"$optimized_out":true}}}
; CHECK-SAME: {"original":"W","generated":"A","inline_path":["bar"],"vars":{"x":"x","y":{"$optimized_out":true},"wv":{"$optimized_out":true}}}

FIRRTL version 4.0.0
circuit Top: %[[
  {"class": "firrtl.passes.InlineAnnotation", "target": "~|W"}
]]
  module W:
    input x: UInt<4>
    output y: UInt<4>
    node wv = not(x)
    connect y, wv

  module A:
    input x: UInt<4>
    output y: UInt<4>
    inst foo of W
    connect foo.x, x
    connect y, foo.y

  module B:
    input x: UInt<4>
    output y: UInt<4>
    inst bar of W
    connect bar.x, x
    connect y, bar.y

  public module Top:
    input x: UInt<4>
    output y: UInt<4>
    output z: UInt<4>
    inst p of A
    inst q of B
    connect p.x, x
    connect q.x, x
    connect y, p.y
    connect z, q.y
