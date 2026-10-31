; RUN: firtool -g --ir-verilog %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s --check-prefix=UHDI
; RUN: firtool -g --ir-verilog %s | circt-translate --emit-hgldd | FileCheck %s --check-prefix=HGLDD

; Dedup merges B into A, and Wrap is inlined into Top. Both A and B stay in
; the debug info, B on the module A that dedup kept.

; Every source module, including the deduped B and the inlined Wrap, keeps
; its own entry and variables. The inlined instance is not a variable of Top.
; UHDI:      "original":{"A":{
; UHDI-SAME: "a":{
; UHDI-SAME: "B":{
; UHDI-SAME: "b":{
; UHDI-SAME: "Top":{
; UHDI-NOT:  "q_w"
; UHDI-SAME: "Wrap":{"loc":
; UHDI-SAME: "w":{"type":

; Only A and Top survive as generated modules.
; UHDI: "generated":{"A":{},"Top":{}}

; B is bound to A. Wrap is bound to Top through its inline path, and its
; instance w is the inlined q_w.
; UHDI:      "bindings":[{"original":"A","generated":"A"
; UHDI-SAME: {"original":"B","generated":"A"
; UHDI-SAME: {"original":"Top","generated":"Top"
; UHDI-SAME: "q":{"$inline":["q"]}
; UHDI-SAME: {"original":"Wrap","generated":"Top","inline_path":["q"]
; UHDI-SAME: "w":{"$inst":"q_w"

; HGLDD:        "kind": "module",
; HGLDD-NEXT:   "obj_name": "A",
; HGLDD-NEXT:   "module_name": "A",
; HGLDD:          "var_name": "a",
; HGLDD:        "kind": "module",
; HGLDD-NEXT:   "obj_name": "B",
; HGLDD-NEXT:   "module_name": "A",
; HGLDD:          "var_name": "b",
; HGLDD:        "kind": "module",
; HGLDD-NEXT:   "obj_name": "Top",
; HGLDD-NEXT:   "module_name": "Top",
; HGLDD:          "name": "q",
; HGLDD:          "name": "w",
; HGLDD-NEXT:     "hdl_obj_name": "q_w",
; HGLDD-NEXT:     "obj_name": "B",

FIRRTL version 4.0.0
circuit Top: %[[
  {"class": "firrtl.passes.InlineAnnotation", "target": "~|Wrap"}
]]
  module A:
    input x: UInt<4>
    output y: UInt<4>
    node a = not(x)
    connect y, a

  module B:
    input x: UInt<4>
    output y: UInt<4>
    node b = not(x)
    connect y, b

  module Wrap:
    input x: UInt<4>
    output y: UInt<4>
    inst w of B
    connect w.x, x
    connect y, w.y

  public module Top:
    input x: UInt<4>
    output y: UInt<4>
    output z: UInt<4>
    inst p of A
    inst q of Wrap
    connect p.x, x
    connect q.x, x
    connect y, p.y
    connect z, q.y
