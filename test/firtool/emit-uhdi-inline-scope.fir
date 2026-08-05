; RUN: firtool -g -O=debug --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv \
; RUN:   && FileCheck %s --input-file=%t.uhdi.json
;
; RUN: FileCheck %s --input-file=%t.uhdi.json --check-prefix=VAR

; An inlined module leaves a `dbg.scope` behind but no `hw.instance`, so the
; scope carries a Chisel name only -- there is no Verilog-side instance left to
; name it after. Variables lifted out of the inlined body keep their Verilog
; names, which come from resolving the live value, not from the scope.

FIRRTL version 4.0.0
circuit Top: %[[
  { "class": "firrtl.passes.InlineAnnotation", "target": "~Top|Child" }
]]
  module Child :
    input p : UInt<8>
    output q : UInt<8>

    intrinsic(circt_debug_moduleinfo<typeName = "Child">) @[Child.scala 3:7]
    node w = add(p, UInt<8>(1)) @[Child.scala 5:11]
    intrinsic(circt_debug_var<typeName = "Wire[UInt<8>]", name = "w">, w) @[Child.scala 5:11]
    connect q, tail(w, 1)

  public module Top :
    input a : UInt<8>
    output b : UInt<8>

    inst c0 of Child @[Top.scala 9:20]
    connect c0.p, a
    connect b, c0.q

; The inline scope names itself in Chisel and nowhere else.
; CHECK:      "kind": "inline"
; CHECK-NEXT: "name": "Child"
; CHECK-NEXT: "representations": {
; CHECK-NEXT:   "chisel": {
; CHECK-NOT:    "verilog"
; CHECK:      "variableRefs": [

; The node lifted out of the inlined body carries the prefixed wire name.
; VAR:      "name": "w",
; VAR:      "verilog": {
; VAR-NEXT:   "name": "c0_w"
