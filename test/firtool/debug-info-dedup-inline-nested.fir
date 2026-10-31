; RUN: firtool -g --ir-verilog %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s

; Dedup merges Mid2 into Mid1, and both are inlined with the W inside them.
; Through m2, W is the instance v of Mid2, and K stays an instance in it.

; CHECK:      "bindings":[
; CHECK-SAME: {"original":"Mid1","generated":"Top","inline_path":["m1"],"vars":{"x":"x","y":"_m1_w_k_y","w":{"$inline":["m1","w"]}}}
; CHECK-SAME: {"original":"W","generated":"Top","inline_path":["m1","w"],{{.*}}"k":{"$inst":"m1_w_k","module":"K"}}}
; CHECK-SAME: {"original":"Mid2","generated":"Top","inline_path":["m2"],"vars":{"x":"x","y":"_m2_w_k_y","v":{"$inline":["m2","v"]}}}
; CHECK-SAME: {"original":"W","generated":"Top","inline_path":["m2","v"],{{.*}}"k":{"$inst":"m2_w_k","module":"K"}}}

FIRRTL version 4.0.0
circuit Top: %[[
  {"class": "firrtl.passes.InlineAnnotation", "target": "~|W"},
  {"class": "firrtl.passes.InlineAnnotation", "target": "~|Mid1"}
]]
  module K:
    input x: UInt<4>
    output y: UInt<4>
    node kv = not(x)
    connect y, kv

  module W:
    input x: UInt<4>
    output y: UInt<4>
    node wv = not(x)
    inst k of K
    connect k.x, wv
    connect y, k.y

  module Mid1:
    input x: UInt<4>
    output y: UInt<4>
    inst w of W
    connect w.x, x
    connect y, w.y

  module Mid2:
    input x: UInt<4>
    output y: UInt<4>
    inst v of W
    connect v.x, x
    connect y, v.y

  public module Top:
    input x: UInt<4>
    output y: UInt<4>
    output z: UInt<4>
    inst m1 of Mid1
    inst m2 of Mid2
    connect m1.x, x
    connect m2.x, x
    connect y, m1.y
    connect z, m2.y
