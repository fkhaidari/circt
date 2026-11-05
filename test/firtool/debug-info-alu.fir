; RUN: firtool -g --ir-hw %s | FileCheck %s --implicit-check-not=dbg.variable
; RUN: firtool %s -o %t.sv
; RUN: grep -v circt_debug_ %s | firtool --format=fir -o %t.nodebug.sv
; RUN: diff %t.sv %t.nodebug.sv
; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.g.sv
; RUN: FileCheck %s --check-prefix=UHDI < %t.uhdi.json

; Chisel output. The `io` bundle holds a probe, so its leaves are
; `opensubfield`s until LowerOpenAggs. `next` is declared under a `when`.
; Every root gets exactly one variable. Without -g the Verilog must match the
; same input with the debug intrinsics removed.

; CHECK-LABEL: hw.module @Alu
; CHECK:      [[NEXT:%.+]] = dbg.value {{%.+}} typeName "UInt<8>"
; CHECK-NEXT: dbg.variable "next", [[NEXT]] kind wire
; CHECK:      dbg.moduleinfo "Alu" params ["{\22x-chisel\22:{\22params\22:[{\22name\22:\22width\22,\22typeName\22:\22Int\22,\22value\22:\228\22}]}}"]
; CHECK:      dbg.variable "clock", {{%.+}} kind input
; CHECK:      dbg.variable "reset", {{%.+}} kind input
; CHECK:      [[OP:%.+]] = dbg.enum %io_op, "DebugE2eAluOp", {ADD = 0 : i64, AND = 2 : i64, OR = 3 : i64, SUB = 1 : i64} fqn "chisel3.debug.DebugE2eAluOp" : i2
; CHECK:      [[A:%.+]] = dbg.value %io_a typeName "UInt<8>"
; CHECK:      [[CFG:%.+]] = dbg.struct {"enable": {{%.+}}, "clear": {{%.+}}} :
; CHECK:      [[LANE0:%.+]] = dbg.value {{%.+}} typeName "DebugE2eLane"
; CHECK:      [[LANE1:%.+]] = dbg.value {{%.+}} typeName "DebugE2eLane"
; CHECK:      [[LANES:%.+]] = dbg.array [[[LANE0]], [[LANE1]]]
; CHECK:      [[READY:%.+]] = dbg.value %io_result_ready typeName "Bool"
; CHECK-NEXT: dbg.struct {"data": {{%.+}}, "valid": {{%.+}}, "ready": [[READY]]} {flips = array<i1: false, false, true>}
; CHECK:      [[IO:%.+]] = dbg.struct {"op": [[OP]], "a": [[A]], "b": {{%.+}}, "cfg": {{%.+}}, "lanes": {{%.+}}, "result": {{%.+}}} {flips = array<i1: true, true, true, true, false, false>}
; CHECK-NEXT: [[IOV:%.+]] = dbg.value [[IO]] typeName "DebugE2eAluIO"
; CHECK-NEXT: dbg.variable "io", [[IOV]] kind output
; CHECK:      [[ACC:%.+]] = dbg.value %acc typeName "UInt<8>"
; CHECK-NEXT: dbg.variable "acc", [[ACC]] kind reg
; CHECK:      [[LAST:%.+]] = dbg.enum %lastOp, "DebugE2eAluOp"
; CHECK-NEXT: dbg.variable "lastOp", [[LAST]] kind reg : !dbg.enum
; CHECK:      dbg.variable "result", {{%.+}} kind wire
; CHECK:      [[SEL:%.+]] = dbg.enum {{%.+}}, "DebugE2eAluOp"
; CHECK-NEXT: dbg.variable "selOp", [[SEL]] kind node : !dbg.enum

; UHDI-LABEL: "bindings": [
; UHDI:             "lanes": [
; UHDI-NEXT:          {
; UHDI-NEXT:            "data": "io_lanes_0_data",
; UHDI-NEXT:            "valid": {
; UHDI-NEXT:              "$const": "0b1"
; UHDI:                 "data": "acc",
; UHDI-NEXT:            "valid": "io_lanes_1_valid"
; UHDI:             "op": "io_op",
; UHDI:               "ready": "io_result_ready",

FIRRTL version 7.0.0
circuit Alu :%[[
  {
    "class":"firrtl.transforms.DedupGroupAnnotation",
    "target":"~|Alu",
    "group":"Alu"
  }
]]
  layer Verification, bind, "verification" :
    layer Assert, bind, "verification/assert" :
      layer Temporal, inline :
    layer Assume, bind, "verification/assume" :
      layer Temporal, inline :
    layer Cover, bind, "verification/cover" :
      layer Temporal, inline :

  public module Alu : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    input clock : Clock @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    input reset : UInt<1> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    output io : { flip op : UInt<2>, flip a : UInt<8>, flip b : UInt<8>, flip cfg : { enable : UInt<1>, clear : UInt<1>}, lanes : { data : UInt<8>, valid : UInt<1>}[2], result : { data : UInt<8>, valid : UInt<1>, flip ready : UInt<1>}, accProbe : Probe<UInt<8>>} @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]

    regreset acc : UInt<8>, clock, reset, UInt<8>(0h0) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 50:20]
    regreset lastOp : UInt<2>, clock, reset, UInt<1>(0h0) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 51:23]
    wire result : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 52:20]
    connect result, UInt<1>(0h0) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 53:10]
    node _T = asUInt(io.op) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
    node _T_1 = eq(UInt<2>(0h0), _T) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
    when _T_1 : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
      node _result_T = add(io.a, io.b) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 55:44]
      node _result_T_1 = tail(_result_T, 1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 55:44]
      connect result, _result_T_1 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 55:36]
    else :
      node _T_2 = asUInt(io.op) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
      node _T_3 = eq(UInt<2>(0h1), _T_2) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
      when _T_3 : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
        node _result_T_2 = sub(io.a, io.b) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 56:44]
        node _result_T_3 = tail(_result_T_2, 1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 56:44]
        connect result, _result_T_3 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 56:36]
      else :
        node _T_4 = asUInt(io.op) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
        node _T_5 = eq(UInt<2>(0h2), _T_4) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
        when _T_5 : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
          node _result_T_4 = and(io.a, io.b) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 57:44]
          connect result, _result_T_4 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 57:36]
        else :
          node _T_6 = asUInt(io.op) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
          node _T_7 = eq(UInt<2>(0h3), _T_6) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
          when _T_7 : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 54:17]
            node _result_T_5 = or(io.a, io.b) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 58:43]
            connect result, _result_T_5 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 58:35]
    when io.cfg.enable : @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 60:23]
      wire next : UInt<8> @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 61:20]
      node _next_T = add(acc, result) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 62:40]
      node _next_T_1 = tail(_next_T, 1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 62:40]
      node _next_T_2 = mux(io.cfg.clear, UInt<1>(0h0), _next_T_1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 62:16]
      connect next, _next_T_2 @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 62:10]
      connect acc, next @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 63:9]
      connect lastOp, io.op @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 64:12]
      node next_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, next) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 61:20]
      intrinsic(circt_debug_var<name = "next">, next_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 61:20]
    node selOp = mux(io.cfg.enable, io.op, lastOp) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 66:18]
    connect io.lanes[0].data, result @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 67:20]
    connect io.lanes[0].valid, UInt<1>(0h1) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 68:21]
    connect io.lanes[1].data, acc @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 69:20]
    node _io_lanes_1_valid_T = eq(selOp, UInt<1>(0h0)) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 70:30]
    connect io.lanes[1].valid, _io_lanes_1_valid_T @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 70:21]
    connect io.result.data, acc @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 71:18]
    node _io_result_valid_T = and(io.result.ready, io.cfg.enable) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 72:38]
    connect io.result.valid, _io_result_valid_T @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 72:19]
    define io.accProbe = probe(acc) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 73:9]
    intrinsic(circt_debug_moduleinfo<typeName = "Alu", params = "{\"x-chisel\":{\"params\":[{\"name\":\"width\",\"typeName\":\"Int\",\"value\":\"8\"}]}}">) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    node clock_h = intrinsic(circt_debug_value<typeName = "Clock"> : UInt<0>, clock) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    intrinsic(circt_debug_var<name = "clock">, clock_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    node reset_h = intrinsic(circt_debug_value<typeName = "Bool"> : UInt<0>, reset) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    intrinsic(circt_debug_var<name = "reset">, reset_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 47:7]
    node io_op_h = intrinsic(circt_debug_enum<typeName = "DebugE2eAluOp", fqn = "chisel3.debug.DebugE2eAluOp", variant_ADD = 0, variant_SUB = 1, variant_AND = 2, variant_OR = 3, name = "op", flip = 1> : UInt<0>, io.op) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_a_h = intrinsic(circt_debug_value<name = "a", flip = 1, typeName = "UInt<8>"> : UInt<0>, io.a) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_b_h = intrinsic(circt_debug_value<name = "b", flip = 1, typeName = "UInt<8>"> : UInt<0>, io.b) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_cfg_enable_h = intrinsic(circt_debug_value<name = "enable", typeName = "Bool"> : UInt<0>, io.cfg.enable) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_cfg_clear_h = intrinsic(circt_debug_value<name = "clear", typeName = "Bool"> : UInt<0>, io.cfg.clear) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_cfg_s = intrinsic(circt_debug_struct : UInt<0>, io_cfg_enable_h, io_cfg_clear_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_cfg_h = intrinsic(circt_debug_value<name = "cfg", flip = 1, typeName = "DebugE2eAluCfg"> : UInt<0>, io_cfg_s) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_0_data_h = intrinsic(circt_debug_value<name = "data", typeName = "UInt<8>"> : UInt<0>, io.lanes[0].data) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_0_valid_h = intrinsic(circt_debug_value<name = "valid", typeName = "Bool"> : UInt<0>, io.lanes[0].valid) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_0_s = intrinsic(circt_debug_struct : UInt<0>, io_lanes_0_data_h, io_lanes_0_valid_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_0_h = intrinsic(circt_debug_value<typeName = "DebugE2eLane", params = "{\"x-chisel\":{\"params\":[{\"name\":\"w\",\"typeName\":\"Int\",\"value\":\"8\"}]}}"> : UInt<0>, io_lanes_0_s) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_1_data_h = intrinsic(circt_debug_value<name = "data", typeName = "UInt<8>"> : UInt<0>, io.lanes[1].data) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_1_valid_h = intrinsic(circt_debug_value<name = "valid", typeName = "Bool"> : UInt<0>, io.lanes[1].valid) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_1_s = intrinsic(circt_debug_struct : UInt<0>, io_lanes_1_data_h, io_lanes_1_valid_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_1_h = intrinsic(circt_debug_value<typeName = "DebugE2eLane", params = "{\"x-chisel\":{\"params\":[{\"name\":\"w\",\"typeName\":\"Int\",\"value\":\"8\"}]}}"> : UInt<0>, io_lanes_1_s) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_a = intrinsic(circt_debug_array : UInt<0>, io_lanes_0_h, io_lanes_1_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_lanes_h = intrinsic(circt_debug_value<name = "lanes", typeName = "DebugE2eLane[2]"> : UInt<0>, io_lanes_a) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_result_data_h = intrinsic(circt_debug_value<name = "data", typeName = "UInt<8>"> : UInt<0>, io.result.data) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_result_valid_h = intrinsic(circt_debug_value<name = "valid", typeName = "Bool"> : UInt<0>, io.result.valid) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_result_ready_h = intrinsic(circt_debug_value<name = "ready", flip = 1, typeName = "Bool"> : UInt<0>, io.result.ready) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_result_s = intrinsic(circt_debug_struct : UInt<0>, io_result_data_h, io_result_valid_h, io_result_ready_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_result_h = intrinsic(circt_debug_value<name = "result", typeName = "DebugE2eResult", params = "{\"x-chisel\":{\"params\":[{\"name\":\"w\",\"typeName\":\"Int\",\"value\":\"8\"}]}}"> : UInt<0>, io_result_s) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_s = intrinsic(circt_debug_struct : UInt<0>, io_op_h, io_a_h, io_b_h, io_cfg_h, io_lanes_h, io_result_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node io_h = intrinsic(circt_debug_value<typeName = "DebugE2eAluIO", params = "{\"x-chisel\":{\"params\":[{\"name\":\"w\",\"typeName\":\"Int\",\"value\":\"8\"}]}}"> : UInt<0>, io_s) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    intrinsic(circt_debug_var<name = "io">, io_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 49:14]
    node acc_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, acc) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 50:20]
    intrinsic(circt_debug_var<name = "acc">, acc_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 50:20]
    node lastOp_h = intrinsic(circt_debug_enum<typeName = "DebugE2eAluOp", fqn = "chisel3.debug.DebugE2eAluOp", variant_ADD = 0, variant_SUB = 1, variant_AND = 2, variant_OR = 3> : UInt<0>, lastOp) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 51:23]
    intrinsic(circt_debug_var<name = "lastOp">, lastOp_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 51:23]
    node result_h = intrinsic(circt_debug_value<typeName = "UInt<8>"> : UInt<0>, result) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 52:20]
    intrinsic(circt_debug_var<name = "result">, result_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 52:20]
    node selOp_h = intrinsic(circt_debug_enum<typeName = "DebugE2eAluOp", fqn = "chisel3.debug.DebugE2eAluOp", variant_ADD = 0, variant_SUB = 1, variant_AND = 2, variant_OR = 3> : UInt<0>, selOp) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 66:18]
    intrinsic(circt_debug_var<name = "selOp">, selOp_h) @[src/test/scala/chisel3/debug/DebugE2eFixtures.scala 66:18]

