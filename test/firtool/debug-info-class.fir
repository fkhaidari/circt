; RUN: firtool -g --ir-hw %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s
; RUN: firtool --ir-hw %s | FileCheck %s --check-prefix=NODBG --implicit-check-not=dbg.

; The class of each instance survives lowering, also when the instance is
; inlined, and the top module keeps its own. A public module that is also
; instantiated has both: its own class and the class of its instance.

; The classes are module types, in the order of the instances. Extension
; data on a class goes under `x-chisel`.

; CHECK:      "profiles":["x-chisel"]
; CHECK-SAME: {"kind":"module","module":"Alu","name":"Alu","x-chisel":{"params":[{"name":"width","typeName":"Int","value":"8"}]}}
; CHECK-SAME: {"kind":"module","module":"Inl","name":"Inl"}
; CHECK-SAME: {"kind":"module","module":"Pub","name":"PubInstance"}

; The module keeps its own class as `name`.

; CHECK:      "original":{
; CHECK-SAME: "Pub":{"loc":{{\[[0-9,]*\]}},"name":"PubModule"
; CHECK-SAME: "Top":{"loc":{{\[[0-9,]*\]}},"name":"Top"

; A kept instance is bound as `$inst`, an inlined one as `$inline`.

; CHECK:      "bindings":[
; CHECK-SAME: "a":{"$inst":"a","module":"Alu"}
; CHECK-SAME: "i":{"$inline":["i"]}
; CHECK-SAME: "p":{"$inst":"p","module":"Pub"}

; Without debug info, the classes are dropped.
; NODBG:      hw.module private @Alu(
; NODBG:      hw.module @Top(
; NODBG-NEXT:   hw.instance "a" @Alu(

FIRRTL version 4.0.0
circuit Top : %[[{"class":"firrtl.passes.InlineAnnotation","target":"~Top|Inl"}]]
  module Alu :
    input clock : Clock
    input x : UInt<8>
    output y : UInt<8>
    reg r : UInt<8>, clock
    connect r, x
    connect y, r

  module Inl :
    input x : UInt<8>
    output y : UInt<8>
    connect y, x

  public module Pub :
    input x : UInt<8>
    output y : UInt<8>
    connect y, not(x)
    intrinsic(circt_debug_type<name = "PubModule">)

  public module Top :
    input clock : Clock
    input x : UInt<8>
    output y : UInt<8>
    output z : UInt<8>
    output w : UInt<8>
    inst a of Alu
    connect a.clock, clock
    connect a.x, x
    connect y, a.y
    inst i of Inl
    connect i.x, x
    connect z, i.y
    inst p of Pub
    connect p.x, x
    connect w, p.y
    intrinsic(circt_debug_type<target = "p", name = "PubInstance">)
    intrinsic(circt_debug_type<name = "Top">)
    intrinsic(circt_debug_type<target = "a", name = "Alu", ext_chisel = "{\"params\":[{\"name\":\"width\",\"typeName\":\"Int\",\"value\":\"8\"}]}">)
    intrinsic(circt_debug_type<target = "i", name = "Inl">)
