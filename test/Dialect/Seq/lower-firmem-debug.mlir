// RUN: circt-opt --lower-seq-firmem %s | FileCheck %s

// The debug scope of a memory gets the module and the instance that lowering
// makes, and the module stays in the debug info. A memory without a scope
// keeps its module out of it.

// CHECK: hw.module.generated @mem_12x42, {{.+}} attributes {dbg.memory,
// CHECK: hw.module.generated @other_8x42, {{.+}} attributes {dbg.lowered,

// CHECK-LABEL: hw.module @Foo
hw.module @Foo(in %clk: !seq.clock, in %addr: i4, in %addr3: i3) {
  // CHECK: dbg.instance "mem", "mem_12x42" linkage "mem_ext"
  // CHECK: hw.instance "mem_ext" @mem_12x42
  dbg.instance "mem"
  %mem = seq.firmem 0, 1, undefined, port_order {dbg.lowered} : <12 x 42>
  %0 = seq.firmem.read_port %mem[%addr], clock %clk : <12 x 42>
  %other = seq.firmem 0, 1, undefined, port_order {dbg.lowered} : <8 x 42>
  %1 = seq.firmem.read_port %other[%addr3], clock %clk : <8 x 42>
}

// Memories of one config in different modules all get their instance.

// CHECK-LABEL: hw.module @Bar
hw.module @Bar(in %clk: !seq.clock, in %addr: i4) {
  // CHECK: dbg.instance "m", "m_16x8" linkage "m_ext"
  dbg.instance "m"
  %m = seq.firmem 0, 1, undefined, port_order : <16 x 8>
  %0 = seq.firmem.read_port %m[%addr], clock %clk : <16 x 8>
}

// CHECK-LABEL: hw.module @Baz
hw.module @Baz(in %clk: !seq.clock, in %addr: i4) {
  // CHECK: dbg.instance "m", "m_16x8" linkage "m_ext"
  dbg.instance "m"
  %m = seq.firmem 0, 1, undefined, port_order : <16 x 8>
  %0 = seq.firmem.read_port %m[%addr], clock %clk : <16 x 8>
}

// A config shared by a described and an undescribed memory gets `dbg.memory`.

// CHECK: hw.module.generated @n_4x8, {{.+}} attributes {dbg.memory,
// CHECK-LABEL: hw.module @Described
hw.module @Described(in %clk: !seq.clock, in %addr: i2) {
  // CHECK: dbg.instance "n", "n_4x8" linkage "n_ext"
  dbg.instance "n"
  %n = seq.firmem 0, 1, undefined, port_order {dbg.lowered} : <4 x 8>
  %0 = seq.firmem.read_port %n[%addr], clock %clk : <4 x 8>
}

// CHECK-LABEL: hw.module @Undescribed
hw.module @Undescribed(in %clk: !seq.clock, in %addr: i2) {
  // CHECK-NOT: dbg.scope
  // CHECK: hw.instance "n_ext" @n_4x8
  %n = seq.firmem 0, 1, undefined, port_order {dbg.lowered} : <4 x 8>
  %0 = seq.firmem.read_port %n[%addr], clock %clk : <4 x 8>
}
