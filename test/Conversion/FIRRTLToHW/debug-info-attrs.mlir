// RUN: circt-opt --lower-firrtl-to-hw %s --split-input-file | FileCheck %s

// FIRRTL to HW builds a fresh hw.instance. It keeps the `dbg.instance`
// description the emitter reads.

// CHECK-LABEL: hw.module @Instance
// CHECK: hw.instance "sub"
// CHECK-SAME: dbg.instance = [#dbg.instance<name = "sub", typeName = "MySub">]
firrtl.circuit "Instance" {
  firrtl.module private @Sub(in %a: !firrtl.uint<8>) {}
  firrtl.module @Instance(in %a: !firrtl.uint<8>) {
    %sub_a = firrtl.instance sub {dbg.instance = [#dbg.instance<name = "sub", typeName = "MySub">]}
        @Sub(in a: !firrtl.uint<8>)
    firrtl.matchingconnect %sub_a, %a : !firrtl.uint<8>
  }
}

// -----

// An instance_choice lowers to one hw.instance per case. All of them keep
// `dbg.instance`: they are a single instance in the source.

// CHECK-LABEL: hw.module @Choice
// CHECK: hw.instance "inst_FPGA"
// CHECK-SAME: dbg.instance = [#dbg.instance<name = "inst", typeName = "MyChoice">]
// CHECK: hw.instance "inst_ASIC"
// CHECK-SAME: dbg.instance = [#dbg.instance<name = "inst", typeName = "MyChoice">]
firrtl.circuit "Choice" {
  sv.macro.decl @targets$Opt$FPGA
  sv.macro.decl @targets$Opt$ASIC
  sv.macro.decl @targets$Opt$Choice$inst
  firrtl.option @Opt {
    firrtl.option_case @FPGA { case_macro = @targets$Opt$FPGA }
    firrtl.option_case @ASIC { case_macro = @targets$Opt$ASIC }
  }
  firrtl.module private @ModuleDefault(in %in: !firrtl.uint<8>) {}
  firrtl.module private @ModuleFPGA(in %in: !firrtl.uint<8>) {}
  firrtl.module @Choice(in %in: !firrtl.uint<8>) {
    %inst_in = firrtl.instance_choice inst {
        dbg.instance = [#dbg.instance<name = "inst", typeName = "MyChoice">],
        instance_macro = @targets$Opt$Choice$inst}
        @ModuleDefault alternatives @Opt
        { @FPGA -> @ModuleFPGA, @ASIC -> @ModuleDefault }
        (in in: !firrtl.uint<8>)
    firrtl.matchingconnect %inst_in, %in : !firrtl.uint<8>
  }
}
