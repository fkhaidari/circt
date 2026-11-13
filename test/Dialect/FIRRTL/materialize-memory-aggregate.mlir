// RUN: circt-opt %s --pass-pipeline='builtin.module(firrtl.circuit(firrtl-materialize-debug-info,firrtl-lower-types,firrtl-materialize-debug-info{memories-only=true}))' | FileCheck %s

firrtl.circuit "Top" {
  firrtl.module @Top() {
    %r = firrtl.mem Undefined {depth = 16 : i64, name = "memory", portNames = ["r"], readLatency = 1 : i32, writeLatency = 1 : i32} : !firrtl.bundle<addr: uint<4>, en: uint<1>, clk: clock, data flip: bundle<a: uint<8>, b: uint<8>>>
  }
}
// CHECK: firrtl.mem sym @[[A:[a-zA-Z0-9_]+]]
// CHECK: %[[AV:.*]] = dbg.value path @[[AP:.*]]
// CHECK: dbg.variable "memory_a_ext", %[[AV]] kind instance : !dbg.value
// CHECK: firrtl.mem sym @[[B:[a-zA-Z0-9_]+]]
// CHECK: %[[BV:.*]] = dbg.value path @[[BP:.*]]
// CHECK: dbg.variable "memory_b_ext", %[[BV]] kind instance : !dbg.value
// CHECK: hw.hierpath private @[[AP]] [@Top::@[[A]]]
// CHECK: hw.hierpath private @[[BP]] [@Top::@[[B]]]
