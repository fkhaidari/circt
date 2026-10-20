; RUN: firtool -g --emit-uhdi --uhdi-stmts --uhdi-format=2 --uhdi-output-file=%t.json %s -o %t.sv
; RUN: FileCheck %s --input-file=%t.json
; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.nostmts.json %s -o %t.nostmts.sv
; RUN: FileCheck %s --check-prefix=NOSTMTS --input-file=%t.nostmts.json

; Source statements form a tree under the module; the binding maps each
; conditional block to the hardware value of its condition. Deduplicated
; modules share the statements of the kept module, and an inlined module keeps
; its statements under its own source entry.

; NOSTMTS-NOT: "stmts"
; NOSTMTS-NOT: "stmt"

FIRRTL version 4.0.0
circuit M : %[[{"class": "firrtl.passes.InlineAnnotation", "target": "~M|Inl"}]]
  module Inl :
    input clock : Clock
    input a : UInt<1>
    output b : UInt<1>
    connect b, UInt<1>(0)
    when a : @[I.scala 4:10]
      connect b, a @[I.scala 5:9]
    intrinsic(circt_debug_var<typeName = "IO[Bool]", name = "a">, a) @[I.scala 2:7]
    intrinsic(circt_debug_var<typeName = "IO[Bool]", name = "b">, b) @[I.scala 3:7]
  module Kid :
    input clock : Clock
    input en : UInt<1>
    output q : UInt<4>
    reg r : UInt<4>, clock @[K.scala 2:16]
    when en : @[K.scala 3:12]
      connect r, add(r, UInt<4>(1)) @[K.scala 3:20]
    connect q, r @[K.scala 4:5]
    intrinsic(circt_debug_var<typeName = "IO[Bool]", name = "en">, en) @[K.scala 1:7]
    intrinsic(circt_debug_var<typeName = "IO[UInt<4>]", name = "q">, q) @[K.scala 1:7]
    intrinsic(circt_debug_var<typeName = "Reg[UInt<4>]", name = "r">, r) @[K.scala 2:16]
  module Kid_1 :
    input clock : Clock
    input en : UInt<1>
    output q : UInt<4>
    reg r : UInt<4>, clock @[K.scala 2:16]
    when en : @[K.scala 3:12]
      connect r, add(r, UInt<4>(1)) @[K.scala 3:20]
    connect q, r @[K.scala 4:5]
    intrinsic(circt_debug_var<typeName = "IO[Bool]", name = "en">, en) @[K.scala 1:7]
    intrinsic(circt_debug_var<typeName = "IO[UInt<4>]", name = "q">, q) @[K.scala 1:7]
    intrinsic(circt_debug_var<typeName = "Reg[UInt<4>]", name = "r">, r) @[K.scala 2:16]
  public module M :
    input clock : Clock
    input reset : UInt<1>
    input sel : UInt<1>
    input d : UInt<8>
    output o : UInt<8>
    output k : UInt<4>
    regreset cnt : UInt<2>, clock, reset, UInt<1>(1) @[M.scala 3:20]
    reg v : UInt<8>[2], clock @[M.scala 4:16]
    wire w : UInt<8> @[M.scala 5:15]
    node t = and(d, UInt<8>(15)) @[M.scala 6:13]
    connect w, t @[M.scala 6:5]
    when sel : @[M.scala 7:12]
      connect cnt, add(cnt, UInt<2>(1)) @[M.scala 8:9]
    else :
      when eq(cnt, UInt<2>(3)) : @[M.scala 9:20]
        connect v[cnt], w @[M.scala 10:14]
    connect o, v[sel] @[M.scala 11:5]
    inst i of Inl @[M.scala 12:17]
    connect i.clock, clock
    connect i.a, sel @[M.scala 13:7]
    inst k0 of Kid @[M.scala 14:18]
    connect k0.clock, clock
    connect k0.en, sel @[M.scala 15:8]
    inst k1 of Kid_1 @[M.scala 16:18]
    connect k1.clock, clock
    connect k1.en, i.b @[M.scala 17:8]
    connect k, xor(k0.q, k1.q) @[M.scala 18:5]
    intrinsic(circt_debug_var<typeName = "IO[Bool]", name = "sel">, sel) @[M.scala 1:7]
    intrinsic(circt_debug_var<typeName = "IO[UInt<8>]", name = "d">, d) @[M.scala 1:7]
    intrinsic(circt_debug_var<typeName = "IO[UInt<8>]", name = "o">, o) @[M.scala 1:7]
    intrinsic(circt_debug_var<typeName = "Reg[UInt<2>]", name = "cnt">, cnt) @[M.scala 3:20]
    intrinsic(circt_debug_subfield<typeName = "Reg[UInt<8>]", name = "v[0]", parent = "v">, v[0]) @[M.scala 4:16]
    intrinsic(circt_debug_subfield<typeName = "Reg[UInt<8>]", name = "v[1]", parent = "v">, v[1]) @[M.scala 4:16]
    intrinsic(circt_debug_var<typeName = "Reg[UInt<8>[2]]", name = "v">, v) @[M.scala 4:16]
    intrinsic(circt_debug_var<typeName = "Wire[UInt<8>]", name = "w">, w) @[M.scala 5:15]

; CHECK:      "profiles": [
; CHECK-NEXT:   "x-chisel",
; CHECK-NEXT:   "stmt",
; CHECK-NEXT:   "deps"
; CHECK-NEXT: ],

; CHECK-LABEL: "Inl": {
; CHECK:      "stmts": [
; CHECK:        "id": "s1",
; CHECK-NEXT:   "kind": "when",
; CHECK:        "reads": [
; CHECK-NEXT:     "a"
; CHECK-NEXT:   ],
; CHECK-NEXT:   "then": [
; CHECK:          "id": "s2",
; CHECK-NEXT:     "kind": "connect",
; CHECK-NEXT:     "lhs": "b",

; CHECK-LABEL: "Kid": {
; CHECK:      "stmts": [
; CHECK:        "clock": "clock",
; CHECK-NEXT:   "id": "s0",
; CHECK-NEXT:   "kind": "reg",
; CHECK:        "var": "r"
; CHECK:        "id": "s2",
; CHECK-NEXT:   "kind": "connect",
; CHECK-NEXT:   "lhs": "r",
; CHECK:        "reads": [
; CHECK-NEXT:     "r"
; CHECK-NEXT:   ]

; CHECK-LABEL: "M": {
; CHECK:      "stmts": [
; CHECK:        "clock": "clock",
; CHECK-NEXT:   "id": "s0",
; CHECK-NEXT:   "init": {
; CHECK-NEXT:     "$const": "0b01"
; CHECK-NEXT:   },
; CHECK-NEXT:   "kind": "reg",
; CHECK:        "reset": "reset",
; CHECK-NEXT:   "var": "cnt"
; CHECK:        "id": "s2",
; CHECK-NEXT:   "kind": "wire",
; CHECK:        "var": "w"
; CHECK:        "id": "s3",
; CHECK-NEXT:   "kind": "node",
; CHECK:        "reads": [
; CHECK-NEXT:     "d"
; CHECK-NEXT:   ],
; CHECK-NEXT:   "var": "t"
; CHECK:        "else": [
; CHECK:          "id": "s7",
; CHECK-NEXT:     "kind": "when",
; CHECK:          "reads": [
; CHECK-NEXT:       "cnt"
; CHECK-NEXT:     ],
; CHECK-NEXT:     "then": [
; CHECK:            "id": "s8",
; CHECK-NEXT:       "kind": "connect",
; CHECK-NEXT:       "lhs": "v[cnt]",
; CHECK:            "reads": [
; CHECK-NEXT:         "w",
; CHECK-NEXT:         "cnt"
; CHECK-NEXT:       ]
; CHECK:        "id": "s5",
; CHECK-NEXT:   "kind": "when",
; CHECK:        "reads": [
; CHECK-NEXT:     "sel"
; CHECK-NEXT:   ],
; CHECK-NEXT:   "then": [
; CHECK:          "id": "s6",
; CHECK-NEXT:     "kind": "connect",
; CHECK-NEXT:     "lhs": "cnt",
; CHECK:        "id": "s9",
; CHECK-NEXT:   "kind": "connect",
; CHECK-NEXT:   "lhs": "o",
; CHECK:        "reads": [
; CHECK-NEXT:     "v[sel]",
; CHECK-NEXT:     "sel"
; CHECK-NEXT:   ]
; CHECK:        "id": "s10",
; CHECK-NEXT:   "kind": "inst",
; CHECK:        "var": "i"
; CHECK:        "id": "s12",
; CHECK-NEXT:   "kind": "connect",
; CHECK-NEXT:   "lhs": "i.a",
; CHECK:        "id": "s18",
; CHECK-NEXT:   "kind": "connect",
; CHECK-NEXT:   "lhs": "k1.en",
; CHECK:        "reads": [
; CHECK-NEXT:     "i.b"
; CHECK-NEXT:   ]

; CHECK-LABEL: "bindings": [
; CHECK:        "source": "Kid",
; CHECK-NEXT:   "stmts": {
; CHECK-NEXT:     "s1": "en"
; CHECK-NEXT:   },
; CHECK-NEXT:   "target": "Kid",
; CHECK:        "source": "Kid_1",
; CHECK-NEXT:   "stmts": {
; CHECK-NEXT:     "s1": "en"
; CHECK-NEXT:   },
; CHECK-NEXT:   "target": "Kid",
; CHECK:        "source": "M",
; CHECK-NEXT:   "stmts": {
; CHECK-NEXT:     "s5": "sel",
; CHECK-NEXT:     "s7": "_GEN"
; CHECK-NEXT:   },
; CHECK-NEXT:   "target": "M",
; CHECK:        "scope": "i",
; CHECK-NEXT:   "source": "Inl",
; CHECK-NEXT:   "stmts": {
; CHECK-NEXT:     "s1": "sel"
; CHECK-NEXT:   },
; CHECK-NEXT:   "target": "M",
