// RUN: circt-opt %s --pass-pipeline='builtin.module(firrtl.circuit(firrtl-inject-dut-hier))' | FileCheck %s

firrtl.circuit "Top" attributes {annotations = [{class = "sifive.enterprise.firrtl.InjectDUTHierarchyAnnotation", name = "Wrapper"}]} {
  hw.hierpath private @child [@DUT::@child]
  hw.hierpath private @dut_module [@Top::@dut, @DUT]
  hw.hierpath private @local_module [@DUT]
  firrtl.module private @Leaf() {}
  firrtl.module private @DUT() attributes {annotations = [{class = "sifive.enterprise.firrtl.MarkDUTAnnotation"}]} {
    %q = dbg.value path @child type "Leaf"
    dbg.variable "sourceChild", %q : !dbg.value
    firrtl.instance child sym @child @Leaf()
  }
  firrtl.module @Top() {
    %d = dbg.value path @dut_module type "SourceDUT"
    dbg.variable "dut", %d : !dbg.value
    firrtl.instance dut sym @dut @DUT()
  }
}
// CHECK: hw.hierpath private @child [@Wrapper::@child]
// CHECK: hw.hierpath private @dut_module [@Top::@dut, @DUT::@Wrapper, @Wrapper]
// CHECK: hw.hierpath private @local_module [@Wrapper]
// CHECK: firrtl.module private @Wrapper
// CHECK: %[[Q:.*]] = dbg.value path @child type "Leaf"
// CHECK: dbg.variable "sourceChild", %[[Q]]
// CHECK: firrtl.instance child sym @child @Leaf()
