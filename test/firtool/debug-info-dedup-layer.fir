; RUN: firtool -g --ir-hw %s | FileCheck %s
; RUN: firtool %s -o %t.sv
; RUN: grep -v circt_debug_ %s | firtool --format=fir -o %t.nodebug.sv
; RUN: diff %t.sv %t.nodebug.sv
; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.g.sv
; RUN: FileCheck %s --check-prefix=UHDI --implicit-check-not=Child_2 < %t.uhdi.json

; Trimmed Chisel output. Child, Child_1 and Child_2 have the same body. Under
; -g Child and Child_2 have the same class parameters and merge; Child_1 has a
; different `tag` and does not. `r` is widthless until InferWidths. Inlined is inlined into
; Top, so its variables and dbg.moduleinfo get a scope. `sum` lives in a layer
; block, so under -g its layer module is kept alive and bound into Top.
; Without -g all three children merge, and the Verilog must match the same
; input with the debug intrinsics removed.

; CHECK-LABEL: hw.module private @Child(
; CHECK:       dbg.moduleinfo "Child" params ["{\22x-chisel\22:{\22params\22:[{{.*}}\22value\22:\22a\22}]}}"]
; CHECK:       [[R:%.+]] = dbg.value %r typeName "UInt" : i8
; CHECK-NEXT:  dbg.variable "r", [[R]] kind reg
; CHECK:       dbg.variable "inc", {{%.+}} kind node

; CHECK-LABEL: hw.module private @Child_1(
; CHECK:       dbg.moduleinfo "Child" params ["{\22x-chisel\22:{\22params\22:[{{.*}}\22value\22:\22b\22}]}}"]

; CHECK-NOT:   hw.module private @Child_2(
; CHECK-LABEL: hw.module private @Top_Verification()
; CHECK:       [[SUM:%.+]] = comb.add {{.*}} {sv.namehint = "sum"} : i9
; CHECK-NEXT:  [[SUMV:%.+]] = dbg.value [[SUM]] typeName "UInt<9>"
; CHECK-NEXT:  dbg.variable "sum", [[SUMV]] kind node

; CHECK-LABEL: hw.module @Top(
; CHECK:       hw.instance "c0" @Child(
; CHECK:       hw.instance "c1" @Child_1(
; CHECK:       hw.instance "c2" @Child(
; CHECK:       [[INL:%.+]] = dbg.scope "inl", "Inlined"
; CHECK:       dbg.moduleinfo "Inlined" scope [[INL]]
; CHECK:       dbg.variable "mixed", {{%.+}} scope [[INL]] kind node
; CHECK:       dbg.moduleinfo "Top"{{$}}
; CHECK:       hw.instance "verification" sym @verification @Top_Verification() -> () {doNotPrint}

; UHDI-LABEL: "bindings": [
; UHDI:           "c0": {
; UHDI-NEXT:        "$inst": "c0",
; UHDI-NEXT:        "module": "Child"
; UHDI:           "c1": {
; UHDI-NEXT:        "$inst": "c1",
; UHDI-NEXT:        "module": "Child_1"
; UHDI:           "c2": {
; UHDI-NEXT:        "$inst": "c2",
; UHDI-NEXT:        "module": "Child"
; UHDI:           "a": "c2_out_layerCapture",

FIRRTL version 7.0.0
circuit Top :%[[
  {
    "class":"firrtl.transforms.DedupGroupAnnotation",
    "target":"~|Child",
    "group":"Child"
  },
  {
    "class":"firrtl.transforms.DedupGroupAnnotation",
    "target":"~|Child_1",
    "group":"Child"
  },
  {
    "class":"firrtl.transforms.DedupGroupAnnotation",
    "target":"~|Child_2",
    "group":"Child"
  },
  {
    "class":"firrtl.transforms.DedupGroupAnnotation",
    "target":"~|Inlined",
    "group":"Inlined"
  },
  {
    "class":"firrtl.transforms.DedupGroupAnnotation",
    "target":"~|Top",
    "group":"Top"
  },
  {
    "class":"firrtl.passes.InlineAnnotation",
    "target":"~|Inlined"
  },
  {
    "class":"firrtl.transforms.NoDedupAnnotation",
    "target":"~|Inlined"
  }
]]
  layer Verification, bind, "verification" :

  module Child : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input clock : Clock @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input reset : Reset @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input in : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    output out : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]

    regreset r : UInt, clock, reset, UInt<8>(0h0) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    connect r, in @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    node _inc_T = add(r, UInt<1>(0h1)) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    node inc = tail(_inc_T, 1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    connect out, inc @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 83:7]
    intrinsic(circt_debug_moduleinfo<typeName = "Child", params = "{\"x-chisel\":{\"params\":[{\"name\":\"width\",\"typeName\":\"Int\",\"value\":\"8\"},{\"name\":\"tag\",\"typeName\":\"String\",\"value\":\"a\"}]}}">) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    node in_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, in) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    intrinsic(circt_debug_var<name = "in">, in_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    node out_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, out) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]
    intrinsic(circt_debug_var<name = "out">, out_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]
    node r_h = intrinsic(circt_debug_value<typeName = "UInt"> : UInt<0>, r) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    intrinsic(circt_debug_var<name = "r">, r_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    node inc_h = intrinsic(circt_debug_value<typeName = "UInt"> : UInt<0>, inc) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    intrinsic(circt_debug_var<name = "inc">, inc_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]


  module Child_1 : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input clock : Clock @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input reset : Reset @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input in : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    output out : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]

    regreset r : UInt, clock, reset, UInt<8>(0h0) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    connect r, in @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    node _inc_T = add(r, UInt<1>(0h1)) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    node inc = tail(_inc_T, 1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    connect out, inc @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 83:7]
    intrinsic(circt_debug_moduleinfo<typeName = "Child", params = "{\"x-chisel\":{\"params\":[{\"name\":\"width\",\"typeName\":\"Int\",\"value\":\"8\"},{\"name\":\"tag\",\"typeName\":\"String\",\"value\":\"b\"}]}}">) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    node in_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, in) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    intrinsic(circt_debug_var<name = "in">, in_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    node out_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, out) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]
    intrinsic(circt_debug_var<name = "out">, out_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]
    node r_h = intrinsic(circt_debug_value<typeName = "UInt"> : UInt<0>, r) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    intrinsic(circt_debug_var<name = "r">, r_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    node inc_h = intrinsic(circt_debug_value<typeName = "UInt"> : UInt<0>, inc) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    intrinsic(circt_debug_var<name = "inc">, inc_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]


  module Child_2 : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input clock : Clock @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input reset : Reset @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    input in : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    output out : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]

    regreset r : UInt, clock, reset, UInt<8>(0h0) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    connect r, in @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    node _inc_T = add(r, UInt<1>(0h1)) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    node inc = tail(_inc_T, 1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    connect out, inc @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 83:7]
    intrinsic(circt_debug_moduleinfo<typeName = "Child", params = "{\"x-chisel\":{\"params\":[{\"name\":\"width\",\"typeName\":\"Int\",\"value\":\"8\"},{\"name\":\"tag\",\"typeName\":\"String\",\"value\":\"a\"}]}}">) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 77:7]
    node in_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, in) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    intrinsic(circt_debug_var<name = "in">, in_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 79:14]
    node out_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, out) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]
    intrinsic(circt_debug_var<name = "out">, out_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 80:15]
    node r_h = intrinsic(circt_debug_value<typeName = "UInt"> : UInt<0>, r) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    intrinsic(circt_debug_var<name = "r">, r_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 81:18]
    node inc_h = intrinsic(circt_debug_value<typeName = "UInt"> : UInt<0>, inc) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]
    intrinsic(circt_debug_var<name = "inc">, inc_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 82:15]


  module Inlined : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 86:7]
    input clock : Clock @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 86:7]
    input reset : Reset @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 86:7]
    input a : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 88:13]
    output y : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 89:13]

    node mixed = xor(a, UInt<7>(0h5a)) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 90:17]
    connect y, mixed @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 91:5]
    intrinsic(circt_debug_moduleinfo<typeName = "Inlined">) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 86:7]
    node a_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, a) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 88:13]
    intrinsic(circt_debug_var<name = "a">, a_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 88:13]
    node y_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, y) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 89:13]
    intrinsic(circt_debug_var<name = "y">, y_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 89:13]
    node mixed_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, mixed) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 90:17]
    intrinsic(circt_debug_var<name = "mixed">, mixed_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 90:17]


  public module Top : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 97:7]
    input clock : Clock @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 97:7]
    input reset : UInt<1> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 97:7]
    input in : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 99:14]
    output out : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 100:15]

    inst c0 of Child @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 101:18]
    connect c0.clock, clock
    connect c0.reset, reset
    inst c1 of Child_1 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 102:18]
    connect c1.clock, clock
    connect c1.reset, reset
    inst c2 of Child_2 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 103:18]
    connect c2.clock, clock
    connect c2.reset, reset
    inst inl of Inlined @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 104:19]
    connect inl.clock, clock
    connect inl.reset, reset
    connect c0.in, in @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 105:9]
    connect c1.in, c0.out @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 106:9]
    connect c2.in, c1.out @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 107:9]
    connect inl.a, c2.out @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 108:9]
    connect out, inl.y @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 109:7]
    skip
    layerblock Verification : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 110:36]
      node sum = add(c0.out, c2.out) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 111:22]
      node sum_h = intrinsic(circt_debug_value<typeName = "UInt<9>"> : UInt<0>, sum) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 111:22]
      intrinsic(circt_debug_var<name = "sum">, sum_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 111:22]
    intrinsic(circt_debug_moduleinfo<typeName = "Top">) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 97:7]
    node in_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, in) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 99:14]
    intrinsic(circt_debug_var<name = "in">, in_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 99:14]
    node out_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, out) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 100:15]
    intrinsic(circt_debug_var<name = "out">, out_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 100:15]

