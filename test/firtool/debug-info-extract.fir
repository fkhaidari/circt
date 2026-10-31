; RUN: firtool -g --ir-hw %s | FileCheck %s --check-prefix=IR
; RUN: firtool -g --ir-hw %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s

; Known limitation: ExtractInstances moves `bb` from `Wrap` up to `Top` and
; leaves its `dbg.instance` behind. The instance is still in the debug info,
; under `Top`, but without its class, and `Wrap` no longer lists it.

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
  ; IR:         dbg.instance "bb", "BB" typeName "BBClass"
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
  ; IR-NOT:     dbg.instance "bb"
  ; IR:         hw.instance "bb" @BB
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    inst dut of Dut
    connect dut.a, a
    connect b, dut.b

; The class of the extracted instance is not in the debug info.
; CHECK:      "types":[
; CHECK-NOT:  "BBClass"
; CHECK-SAME: {"kind":"module","module":"BB"}],"original"

; `Wrap` no longer lists `bb`.
; CHECK:      "Wrap":{"loc":
; CHECK-NOT:  "bb"

; `Top` lists `bb`, typed as module `BB`.
; CHECK:      "Top":{"loc":
; CHECK-SAME: "bb":{"type":[[BB:[0-9]+]]
