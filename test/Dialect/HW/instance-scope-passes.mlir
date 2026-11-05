// RUN: circt-opt --hw-flatten-io %s | FileCheck %s --check-prefix=FLATTEN
// RUN: circt-opt --hw-imdce %s | FileCheck %s --check-prefix=IMDCE
// RUN: circt-opt --hw-parameterize-constant-ports %s | FileCheck %s --check-prefix=PARAM
// RUN: circt-opt --hw-eliminate-inout-ports %s | FileCheck %s --check-prefix=INOUT
// RUN: circt-opt --externalize-registers %s | FileCheck %s --check-prefix=EXTREG
// RUN: circt-opt --cellift-instrument %s | FileCheck %s --check-prefix=CELLIFT

// Passes that rebuild an instance keep its debug scope operand. Every instance
// below gets a port added, removed or changed by the pass under test.

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

hw.module @Top(in %in: !S, in %d: i1, in %x: i8, in %clk: !seq.clock, out out: i1, out o1: i8, out o2: i42, out o3: i8, out o4: i8) {
  // FLATTEN: [[S:%.+]] = dbg.scope "s", "S"
  // FLATTEN: hw.instance "c" @Child(in.a: {{.*}}, in.b: {{.*}}, dead: {{.*}}) -> (out: i1) scope [[S]]
  // IMDCE: [[S:%.+]] = dbg.scope "s", "S"
  // IMDCE: hw.instance "c" @Child(in: %in: !hw.struct<a: i1, b: i2>) -> (out: i1) scope [[S]]
  // PARAM: [[S:%.+]] = dbg.scope "s", "S"
  // PARAM: hw.instance "k" @ConstPort<k: i8 = 5>(x: {{.*}}) -> (out: i8) scope [[S]]
  // INOUT: [[S:%.+]] = dbg.scope "s", "S"
  // INOUT: hw.instance "io" @InOut(a_rd: {{.*}}) -> (out: i42) scope [[S]]
  // EXTREG: [[S:%.+]] = dbg.scope "s", "S"
  // EXTREG: hw.instance "r" @Reg({{.*}}) -> (out: i8, r_next: i8) scope [[S]]
  // CELLIFT: [[S:%.+]] = dbg.scope "s", "S"
  // CELLIFT: hw.instance "t" @Taint(x: {{.*}}, x_t: {{.*}}) -> (y: i8, y_t: i8) scope [[S]]
  %s = dbg.scope "s", "S"
  %o = hw.instance "c" @Child(in: %in: !S, dead: %d: i1) -> (out: i1) scope %s
  %c5 = hw.constant 5 : i8
  %k = hw.instance "k" @ConstPort(k: %c5: i8, x: %x: i8) -> (out: i8) scope %s
  %w = sv.wire : !hw.inout<i42>
  %io = hw.instance "io" @InOut(a: %w: !hw.inout<i42>) -> (out: i42) scope %s
  %r = hw.instance "r" @Reg(clk: %clk: !seq.clock, in: %x: i8) -> (out: i8) scope %s
  %t = hw.instance "t" @Taint(x: %x: i8) -> (y: i8) scope %s
  hw.output %o, %k, %io, %r, %t : i1, i8, i42, i8, i8
}
