; RUN: firtool -g -O=debug --emit-uhdi --uhdi-format=2 \
; RUN:   --uhdi-output-file=%t.json %s -o %t.sv \
; RUN:   && FileCheck %s --input-file=%t.json

; An enum carries its variants as one integer parameter each.

FIRRTL version 4.0.0
circuit Top:
  public module Top :
    input op : UInt<2>
    output out : UInt<2>
    intrinsic(circt_debug_var<typeName = "IO[AluOp]", name = "op", enumTypeName = "AluOp", enumFqn = "pkg.AluOp", variant_ADD = 0, variant_SUB = 1, variant_AND = 2, variant_OR = 3, width = 2>, op)
    connect out, op

; CHECK:      "pkg.AluOp": {
; CHECK-NEXT:   "base": "uint2",
; CHECK-NEXT:   "kind": "enum",
; CHECK-NEXT:   "name": "AluOp",
; CHECK-NEXT:   "values": {
; CHECK-NEXT:     "ADD": 0,
; CHECK-NEXT:     "AND": 2,
; CHECK-NEXT:     "OR": 3,
; CHECK-NEXT:     "SUB": 1
; CHECK-NEXT:   }
