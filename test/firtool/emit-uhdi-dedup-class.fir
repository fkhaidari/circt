; RUN: firtool --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv \
; RUN:   && FileCheck %s --input-file=%t.uhdi.json

; A and B are the same hardware and different source classes. They deduplicate,
; and each instantiation site still names the class it was written as. The
; surviving definition names neither: it stands for both.

FIRRTL version 4.0.0
circuit Top:
  module A :
    input p : UInt<8>
    output q : UInt<8>
    connect q, p

  module B :
    input p : UInt<8>
    output q : UInt<8>
    connect q, p

  public module Top :
    input a : UInt<8>
    output x : UInt<8>
    output y : UInt<8>

    inst ia of A
    intrinsic(circt_debug_moduleinfo<typeName = "ClassA", instance = "ia">)
    inst ib of B
    intrinsic(circt_debug_moduleinfo<typeName = "ClassB", instance = "ib">)
    connect ia.p, a
    connect ib.p, a
    connect x, ia.q
    connect y, ib.q

; Only one definition survives, and it carries no class name.
; CHECK:      "modules":
; CHECK-NEXT:   "A":
; CHECK-NOT:      "typeName"

; CHECK:        "Top":
; CHECK:          "instances":
; CHECK:            "ia":
; CHECK-NEXT:         "moduleRef": "A"
; CHECK:                "x-chisel":
; CHECK-NEXT:             "typeName": "ClassA"
; CHECK:            "ib":
; CHECK-NEXT:         "moduleRef": "A"
; CHECK:                "x-chisel":
; CHECK-NEXT:             "typeName": "ClassB"
