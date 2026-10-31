; RUN: firtool -g --ir-hw %s | FileCheck %s --check-prefix=IR
; RUN: firtool -g --ir-hw %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s

; ExtractInstances moves `bb` from `Wrap` up to `Top`, and its `#dbg.instance`
; moves with it. The debug info lists `bb` under `Top` with its class.

FIRRTL version 4.0.0
circuit Top : %[[
  {"class":"sifive.enterprise.firrtl.ExtractBlackBoxAnnotation","target":"~Top|BB","filename":"BlackBoxes.txt","prefix":"bb"},
  {"class":"sifive.enterprise.firrtl.MarkDUTAnnotation","target":"~Top|Dut"}
]]
  extmodule BB :
    input in : UInt<8>
    output out : UInt<8>
    defname = BB

  ; IR-LABEL: hw.module private @Wrap
  ; IR-NOT:     hw.instance "bb"
  module Wrap :
    input a : UInt<8>
    output b : UInt<8>
    inst bb of BB
    connect bb.in, a
    connect b, bb.out
    intrinsic(circt_debug_type<target = "bb", name = "BBClass">)

  module Dut :
    input a : UInt<8>
    output b : UInt<8>
    inst w of Wrap
    connect w.a, a
    connect b, w.b

  ; IR-LABEL: hw.module @Top
  ; IR:         hw.instance "bb" @BB
  ; IR-SAME:      {dbg.instance = [#dbg.instance<name = "bb", typeName = "BBClass">]}
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    inst dut of Dut
    connect dut.a, a
    connect b, dut.b

; The extracted instance keeps its class.
; CHECK:      "types":[
; CHECK-SAME: {"kind":"module","module":"BB","name":"BBClass"}],"original"

; `Wrap` no longer lists `bb`.
; CHECK:      "Wrap":{"loc":
; CHECK-NOT:  "bb"

; `Top` lists `bb`.
; CHECK:      "Top":{"loc":
; CHECK-SAME: "bb":{"type":3
