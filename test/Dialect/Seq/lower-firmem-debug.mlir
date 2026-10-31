// RUN: circt-opt --lower-seq-firmem %s | FileCheck %s

// The description of a memory moves to the instance that lowering makes, and
// the module stays in the debug info. A memory without a description keeps
// its module out of it.

// CHECK: hw.module.generated @mem_12x42, {{.+}} attributes {dbg.memory,
// CHECK: hw.module.generated @other_8x42, {{.+}} attributes {dbg.lowered,

// CHECK-LABEL: hw.module @Foo
hw.module @Foo(in %clk: !seq.clock, in %addr: i4, in %addr3: i3) {
  // CHECK: hw.instance "mem_ext" @mem_12x42
  // CHECK-SAME: dbg.instance = [#dbg.instance<name = "mem">]
  %mem = seq.firmem 0, 1, undefined, port_order {dbg.instance = [#dbg.instance<name = "mem">], dbg.lowered} : <12 x 42>
  %0 = seq.firmem.read_port %mem[%addr], clock %clk : <12 x 42>
  %other = seq.firmem 0, 1, undefined, port_order {dbg.lowered} : <8 x 42>
  %1 = seq.firmem.read_port %other[%addr3], clock %clk : <8 x 42>
}

// A config shared by a described and an undescribed memory gets `dbg.memory`.

// CHECK: hw.module.generated @n_4x8, {{.+}} attributes {dbg.memory,
// CHECK-LABEL: hw.module @Described
hw.module @Described(in %clk: !seq.clock, in %addr: i2) {
  // CHECK: hw.instance "n_ext" @n_4x8
  // CHECK-SAME: dbg.instance = [#dbg.instance<name = "n">]
  %n = seq.firmem 0, 1, undefined, port_order {dbg.instance = [#dbg.instance<name = "n">], dbg.lowered} : <4 x 8>
  %0 = seq.firmem.read_port %n[%addr], clock %clk : <4 x 8>
}

// CHECK-LABEL: hw.module @Undescribed
// CHECK: hw.instance "n_ext" @n_4x8
// CHECK-NOT: dbg.instance
hw.module @Undescribed(in %clk: !seq.clock, in %addr: i2) {
  %n = seq.firmem 0, 1, undefined, port_order {dbg.lowered} : <4 x 8>
  %0 = seq.firmem.read_port %n[%addr], clock %clk : <4 x 8>
}
