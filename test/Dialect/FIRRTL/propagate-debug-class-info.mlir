// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl-propagate-debug-class-info))' \
// RUN:   --split-input-file %s | FileCheck %s

firrtl.circuit "Top" {
  // The record moves to the instantiation sites.
  // CHECK: firrtl.module private @Child
  // CHECK-NOT: dbg.moduleinfo
  firrtl.module private @Child(in %a: !firrtl.uint<8>)
      attributes {dbg.moduleinfo = {typeName = "MyChild"}} {}

  // Never instantiated: nowhere to move the record to, so it stays.
  // CHECK: firrtl.module private @Orphan
  // CHECK-SAME: dbg.moduleinfo = {typeName = "MyOrphan"}
  firrtl.module private @Orphan()
      attributes {dbg.moduleinfo = {typeName = "MyOrphan"}} {}

  // CHECK: firrtl.module @Top
  // CHECK-SAME: dbg.moduleinfo = {typeName = "MyTop"}
  firrtl.module @Top(in %a: !firrtl.uint<8>)
      attributes {dbg.moduleinfo = {typeName = "MyTop"}} {
    // CHECK: firrtl.instance c0
    // CHECK-SAME: dbg.moduleinfo = {typeName = "MyChild"}
    %c0_a = firrtl.instance c0 @Child(in a: !firrtl.uint<8>)
    // CHECK: firrtl.instance c1
    // CHECK-SAME: dbg.moduleinfo = {typeName = "MyChild"}
    %c1_a = firrtl.instance c1 @Child(in a: !firrtl.uint<8>)
    firrtl.matchingconnect %c0_a, %a : !firrtl.uint<8>
    firrtl.matchingconnect %c1_a, %a : !firrtl.uint<8>
  }
}

// -----

// An instance_choice names several modules. Only a record all of them agree on
// describes the instance; when they disagree it gets none, and the modules keep
// what they have.

// CHECK-LABEL: firrtl.circuit "Choice"
firrtl.circuit "Choice" {
  sv.macro.decl @targets$Opt$FPGA
  sv.macro.decl @targets$Opt$Choice$inst
  firrtl.option @Opt {
    firrtl.option_case @FPGA { case_macro = @targets$Opt$FPGA }
  }
  // CHECK: firrtl.module private @ModuleDefault
  // CHECK-SAME: dbg.moduleinfo = {typeName = "Default"}
  firrtl.module private @ModuleDefault(in %in: !firrtl.uint<8>)
      attributes {dbg.moduleinfo = {typeName = "Default"}} {}
  // CHECK: firrtl.module private @ModuleFPGA
  // CHECK-SAME: dbg.moduleinfo = {typeName = "Fpga"}
  firrtl.module private @ModuleFPGA(in %in: !firrtl.uint<8>)
      attributes {dbg.moduleinfo = {typeName = "Fpga"}} {}
  // CHECK: firrtl.module @Choice
  firrtl.module @Choice(in %in: !firrtl.uint<8>) {
    // CHECK: firrtl.instance_choice inst
    // CHECK-NOT: dbg.moduleinfo
    %inst_in = firrtl.instance_choice inst {
        instance_macro = @targets$Opt$Choice$inst}
        @ModuleDefault alternatives @Opt { @FPGA -> @ModuleFPGA }
        (in in: !firrtl.uint<8>)
    firrtl.matchingconnect %inst_in, %in : !firrtl.uint<8>
  }
}
