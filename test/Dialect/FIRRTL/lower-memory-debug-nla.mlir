// RUN: circt-opt %s --firrtl-lower-memory | FileCheck %s

firrtl.circuit "NonLocalAnnotation" {
  hw.hierpath private @memory_path [@DUT::@mem1]

// CHECK:  hw.hierpath private @[[nla_0:.+]] [@NonLocalAnnotation::@dut, @DUT::@[[MEM0:.+]], @mem0]
hw.hierpath private @nla0 [@NonLocalAnnotation::@dut, @DUT::@mem0]
// CHECK:  hw.hierpath private @[[nla_1:.+]] [@NonLocalAnnotation::@dut, @DUT::@[[MEM1:.+]], @mem1]
hw.hierpath private @nla1 [@NonLocalAnnotation::@dut, @DUT]

// CHECK: firrtl.module @NonLocalAnnotation()
firrtl.module @NonLocalAnnotation()  {
  firrtl.instance dut sym @dut @DUT()
}
// CHECK: firrtl.module private @mem0
// CHECK:   firrtl.instance mem0_ext sym @mem0_ext
// CHECK-SAME: {annotations = [{circt.nonlocal = @[[nla_0]], class = "test0"}]}
// CHECK-SAME:  @mem0_ext(
// CHECK: }

// CHECK: firrtl.module private @mem1
// CHECK:   firrtl.instance mem1_ext sym @mem0_ext
// CHECK-SAME:  {annotations = [{circt.nonlocal = @[[nla_1]], class = "test1"}]}
// CHECK-SAME:  @mem0_ext(

// CHECK: firrtl.module @DUT()
firrtl.module @DUT() {
  // This memory has a symbol and an NLA directly targetting it.
  // CHECK: firrtl.instance mem0 sym @[[MEM0]] @mem0
  %mem0_write = firrtl.mem sym @mem0 Undefined {annotations = [{circt.nonlocal = @nla0, class = "test0"}], depth = 12 : i64, name = "mem0", portNames = ["write"], readLatency = 1 : i32, writeLatency = 1 : i32} : !firrtl.bundle<addr: uint<4>, en: uint<1>, clk: clock, data: uint<42>, mask: uint<1>>

  // This memory shares its external module with mem0.
  // CHECK: %[[MEMV:.*]] = dbg.value path @debug_memory type "Memory"
  // CHECK: dbg.variable "mem1", %[[MEMV]] : !dbg.value
  // CHECK: firrtl.instance mem1 sym @[[MEM1]] @mem1
  %q = dbg.value path @memory_path type "Memory"
  dbg.variable "mem1", %q : !dbg.value
  %mem1_write = firrtl.mem sym @mem1 Undefined {annotations = [{circt.nonlocal = @nla1, class = "test1"}], depth = 12 : i64, name = "mem1", portNames = ["write"], readLatency = 1 : i32, writeLatency = 1 : i32} : !firrtl.bundle<addr: uint<4>, en: uint<1>, clk: clock, data: uint<42>, mask: uint<1>>

// LowerMemory should ignore MemOps that are not seqmems. The following memory is a combmem with readLatency=0.
  %MRead_read = firrtl.mem Undefined {depth = 12 : i64, name = "MRead", portNames = ["read"], readLatency = 0 : i32, writeLatency = 1 : i32} : !firrtl.bundle<addr: uint<4>, en: uint<1>, clk: clock, data flip: uint<42>>
// CHECK:   %MRead_read = firrtl.mem Undefined
}
}

// CHECK: hw.hierpath private @debug_memory [@DUT::@mem1, @mem1::@mem0_ext]
