// RUN: circt-opt --hw-flatten-io %s | FileCheck %s --check-prefix=FLATTEN
// RUN: circt-opt --hw-imdce %s | FileCheck %s --check-prefix=IMDCE
// RUN: circt-opt --hw-parameterize-constant-ports %s | FileCheck %s --check-prefix=PARAM
// RUN: circt-opt --hw-eliminate-inout-ports %s | FileCheck %s --check-prefix=INOUT
// RUN: circt-opt --externalize-registers %s | FileCheck %s --check-prefix=EXTREG
// RUN: circt-opt --cellift-instrument %s | FileCheck %s --check-prefix=CELLIFT

// Rebuilding instance ports preserves debug description targets.

!S = !hw.struct<a: i1, b: i2>

// flatten-io: the struct port is split.
// imdce: the unused `dead` port is removed.
hw.module private @Child(in %in: !S, in %dead: i1, out out: i1) {
  %a, %b = hw.struct_explode %in : !S
  hw.output %a : i1
}

// parameterize-constant-ports: `k` is constant at the only instance.
hw.module private @ConstPort(in %k: i8, in %x: i8, out out: i8) {
  %0 = comb.add %k, %x : i8
  hw.output %0 : i8
}

// eliminate-inout-ports: PortConverter replaces the inout port.
hw.module private @InOut(in %a: !hw.inout<i42>, out out: i42) {
  %0 = sv.read_inout %a : !hw.inout<i42>
  hw.output %0 : i42
}

// externalize-registers: the register becomes an extra input and output.
hw.module private @Reg(in %clk: !seq.clock, in %in: i8, out out: i8) {
  %r = seq.compreg %in, %clk : i8
  hw.output %r : i8
}

// cellift-instrument: taint ports are added.
hw.module private @Taint(in %x: i8, out y: i8) {
  hw.output %x : i8
}

hw.hierpath private @debug_Top_c [@Top::@c]
hw.hierpath private @debug_Top_k [@Top::@k]
hw.hierpath private @debug_Top_io [@Top::@io]
hw.hierpath private @debug_Top_r [@Top::@r]
hw.hierpath private @debug_Top_t [@Top::@t]
hw.module @Top(in %in: !S, in %d: i1, in %x: i8, in %clk: !seq.clock, out out: i1, out o1: i8, out o2: i42, out o3: i8, out o4: i8) {
  // FLATTEN: [[S:%.+]] = dbg.scope "s"
  // FLATTEN: dbg.value path @debug_Top_c type "Child"
  // FLATTEN: dbg.variable "c", {{%.*}} scope [[S]] : !dbg.value
  // FLATTEN: hw.instance "c" sym @c @Child(in.a: {{.*}}, in.b: {{.*}}, dead: {{.*}}) -> (out: i1)
  // IMDCE: [[S:%.+]] = dbg.scope "s"
  // IMDCE: dbg.value path @debug_Top_c type "Child"
  // IMDCE: dbg.variable "c", {{%.*}} scope [[S]] : !dbg.value
  // IMDCE: hw.instance "c" sym @c @Child(in: %in: !hw.struct<a: i1, b: i2>) -> (out: i1)
  // PARAM: [[S:%.+]] = dbg.scope "s"
  // PARAM: dbg.value path @debug_Top_k type "ConstPort"
  // PARAM: dbg.variable "k", {{%.*}} scope [[S]] : !dbg.value
  // PARAM: hw.instance "k" sym @k @ConstPort<k: i8 = 5>(x: {{.*}}) -> (out: i8)
  // INOUT: [[S:%.+]] = dbg.scope "s"
  // INOUT: dbg.value path @debug_Top_io type "InOut"
  // INOUT: dbg.variable "io", {{%.*}} scope [[S]] : !dbg.value
  // INOUT: hw.instance "io" sym @io @InOut(a_rd: {{.*}}) -> (out: i42)
  // EXTREG: [[S:%.+]] = dbg.scope "s"
  // EXTREG: dbg.value path @debug_Top_r type "Reg"
  // EXTREG: dbg.variable "r", {{%.*}} scope [[S]] : !dbg.value
  // EXTREG: hw.instance "r" sym @r @Reg({{.*}}) -> (out: i8, r_next: i8)
  // CELLIFT: [[S:%.+]] = dbg.scope "s"
  // CELLIFT: dbg.value path @debug_Top_t type "Taint"
  // CELLIFT: dbg.variable "t", {{%.*}} scope [[S]] : !dbg.value
  // CELLIFT: hw.instance "t" sym @t @Taint(x: {{.*}}, x_t: {{.*}}) -> (y: i8, y_t: i8)
  %s = dbg.scope "s"
  %desc_c = dbg.value path @debug_Top_c type "Child"
  dbg.variable "c", %desc_c scope %s : !dbg.value
  %o = hw.instance "c" sym @c @Child(in: %in: !S, dead: %d: i1) -> (out: i1)
  %c5 = hw.constant 5 : i8
  %desc_k = dbg.value path @debug_Top_k type "ConstPort"
  dbg.variable "k", %desc_k scope %s : !dbg.value
  %k = hw.instance "k" sym @k @ConstPort(k: %c5: i8, x: %x: i8) -> (out: i8)
  %w = sv.wire : !hw.inout<i42>
  %desc_io = dbg.value path @debug_Top_io type "InOut"
  dbg.variable "io", %desc_io scope %s : !dbg.value
  %io = hw.instance "io" sym @io @InOut(a: %w: !hw.inout<i42>) -> (out: i42)
  %desc_r = dbg.value path @debug_Top_r type "Reg"
  dbg.variable "r", %desc_r scope %s : !dbg.value
  %r = hw.instance "r" sym @r @Reg(clk: %clk: !seq.clock, in: %x: i8) -> (out: i8)
  %desc_t = dbg.value path @debug_Top_t type "Taint"
  dbg.variable "t", %desc_t scope %s : !dbg.value
  %t = hw.instance "t" sym @t @Taint(x: %x: i8) -> (y: i8)
  hw.output %o, %k, %io, %r, %t : i1, i8, i42, i8, i8
}
