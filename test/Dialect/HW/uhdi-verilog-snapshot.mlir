// RUN: circt-opt --pass-pipeline='builtin.module(hw.module(hw-uhdi-verilog-snapshot))' %s | FileCheck %s

// The pass only acts on dbg.* ops that already carry uhdi.stable_id
// (a stamp placed by firrtl-uhdi-init earlier in the pipeline). For each,
// it records the Verilog-side signal name as
// `uhdi.repr_entry = {verilog = {name = "..."}}`.

// CHECK-LABEL: hw.module @Ports
hw.module @Ports(in %a : i8, in %b : i4, out o : i12) {
  // Block argument -> port name; repr_entry gets stamped.
  // CHECK: dbg.variable "a", %a {uhdi.repr_entry = {verilog = {name = "a"}}, uhdi.stable_id = "var_aaaa_0000"}
  dbg.variable "a", %a {uhdi.stable_id = "var_aaaa_0000"} : i8

  // hw.wire with hw.verilogName -> that name.
  // CHECK: dbg.variable "myWire", %w_inner {uhdi.repr_entry = {verilog = {name = "w_rename"}}, uhdi.stable_id = "var_bbbb_0000"}
  %w_inner = hw.wire %a {hw.verilogName = "w_rename"} : i8
  dbg.variable "myWire", %w_inner {uhdi.stable_id = "var_bbbb_0000"} : i8

  // No stable_id -> pass is a no-op.
  // CHECK: dbg.variable "untagged", %b : i4
  dbg.variable "untagged", %b : i4

  // Intermediate signal (comb.concat result) whose value reaches
  // hw.output resolves to the destination port name -- matches the
  // output-port fallback in resolveVerilogName.
  // CHECK: dbg.variable "intermediate", %0 {uhdi.repr_entry = {verilog = {name = "o"}}, uhdi.stable_id = "var_cccc_0000"}
  %0 = comb.concat %a, %b : i8, i4
  dbg.variable "intermediate", %0 {uhdi.stable_id = "var_cccc_0000"} : i12

  hw.output %0 : i12
}

// CHECK-LABEL: hw.module @ChildScope
hw.module private @Child(in %x : i8, out y : i8) {
  hw.output %x : i8
}

hw.module @ChildScope(in %a : i8, out b : i8) {
  // dbg.scope resolves via the matching hw.instance's hw.verilogName.
  // CHECK: dbg.scope "c", "Child" {uhdi.repr_entry = {verilog = {name = "c_inst"}}, uhdi.stable_id = "scope_dddd_0000"}
  %s = dbg.scope "c", "Child" {uhdi.stable_id = "scope_dddd_0000"}
  %c.y = hw.instance "c" @Child(x: %a: i8) -> (y: i8) {hw.verilogName = "c_inst"}
  hw.output %c.y : i8
}

// CHECK-LABEL: hw.module @Idempotent
hw.module @Idempotent(in %p : i1) {
  // Pre-existing repr_entry is not rewritten.
  // CHECK: dbg.variable "p", %p {uhdi.repr_entry = {verilog = {name = "preset"}}, uhdi.stable_id = "var_eeee_0000"}
  dbg.variable "p", %p {
    uhdi.stable_id = "var_eeee_0000",
    uhdi.repr_entry = {verilog = {name = "preset"}}
  } : i1
  hw.output
}

// CHECK-LABEL: hw.module @PortRenames
hw.module @PortRenames(in %a : i1 {hw.verilogName = "a_0"}, out o : i1 {hw.verilogName = "o_0"}) {
  // Input block-arg with per-port hw.verilogName picks the legalized name,
  // not the type-level port name.
  // CHECK: dbg.variable "a", %a {uhdi.repr_entry = {verilog = {name = "a_0"}}, uhdi.stable_id = "var_ffff_0000"}
  dbg.variable "a", %a {uhdi.stable_id = "var_ffff_0000"} : i1

  // Output fallback picks the destination port's per-port hw.verilogName.
  // CHECK: dbg.variable "out", %0 {uhdi.repr_entry = {verilog = {name = "o_0"}}, uhdi.stable_id = "var_gggg_0000"}
  %0 = comb.or %a, %a : i1
  dbg.variable "out", %0 {uhdi.stable_id = "var_gggg_0000"} : i1
  hw.output %0 : i1
}

// CHECK-LABEL: hw.module @InstanceResult
hw.module @InstanceResult(in %a : i8) {
  // dbg.variable referencing an hw.instance result resolves to
  // <inst-vname>.<port-name>.
  // CHECK: dbg.variable "child.y", %c.y {uhdi.repr_entry = {verilog = {name = "c_inst.y"}}, uhdi.stable_id = "var_hhhh_0000"}
  %c.y = hw.instance "c" @Child(x: %a: i8) -> (y: i8) {hw.verilogName = "c_inst"}
  dbg.variable "child.y", %c.y {uhdi.stable_id = "var_hhhh_0000"} : i8
  hw.output
}

// CHECK-LABEL: hw.module @InstanceResultNoLegalize
hw.module @InstanceResultNoLegalize(in %a : i8) {
  // No hw.verilogName on the instance: fall back to source-level instance name.
  // CHECK: dbg.variable "child2.y", %c2.y {uhdi.repr_entry = {verilog = {name = "c2.y"}}, uhdi.stable_id = "var_iiii_0000"}
  %c2.y = hw.instance "c2" @Child(x: %a: i8) -> (y: i8)
  dbg.variable "child2.y", %c2.y {uhdi.stable_id = "var_iiii_0000"} : i8
  hw.output
}

// CHECK-LABEL: hw.module @SvWireRead
hw.module @SvWireRead(in %a : i8) {
  // sv.read_inout walks into sv.wire, helper picks the wire name attr.
  %w = sv.wire {name = "myw"} : !hw.inout<i8>
  sv.assign %w, %a : i8
  %v = sv.read_inout %w : !hw.inout<i8>
  // CHECK: dbg.variable "x", %{{[0-9]+}} {uhdi.repr_entry = {verilog = {name = "myw"}}, uhdi.stable_id = "var_jjjj_0000"}
  dbg.variable "x", %v {uhdi.stable_id = "var_jjjj_0000"} : i8
  hw.output
}

// CHECK-LABEL: hw.module @AggregateInoutLeaf
hw.module @AggregateInoutLeaf(in %a : i8) {
  // Aggregate inout indexing returns {} from the helper: no uhdi.repr_entry
  // is stamped (only the existing uhdi.stable_id remains).
  %s = sv.wire {name = "mystruct"} : !hw.inout<struct<f1: i8>>
  %f = sv.struct_field_inout %s["f1"] : !hw.inout<struct<f1: i8>>
  %v = sv.read_inout %f : !hw.inout<i8>
  // CHECK: dbg.variable "field", %{{[0-9]+}} {uhdi.stable_id = "var_kkkk_0000"} : i8
  dbg.variable "field", %v {uhdi.stable_id = "var_kkkk_0000"} : i8
  hw.output
}

hw.module.extern private @ExtChild(in %x : i8, out y : i8)

// CHECK-LABEL: hw.module @ExternInstanceResult
hw.module @ExternInstanceResult(in %a : i8) {
  // FG4.8 branch also works for hw.module.extern instances.
  // CHECK: dbg.variable "ext.y", %c.y {uhdi.repr_entry = {verilog = {name = "c_ext.y"}}, uhdi.stable_id = "var_llll_0000"}
  %c.y = hw.instance "c" @ExtChild(x: %a: i8) -> (y: i8) {hw.verilogName = "c_ext"}
  dbg.variable "ext.y", %c.y {uhdi.stable_id = "var_llll_0000"} : i8
  hw.output
}
