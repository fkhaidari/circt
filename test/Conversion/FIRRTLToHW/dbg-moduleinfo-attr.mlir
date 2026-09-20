// RUN: circt-opt --lower-firrtl-to-hw %s --split-input-file | FileCheck %s

// The `dbg.moduleinfo` discardable attribute carrying source-language type
// info must survive FIRRTL->HW lowering: it is set on the FIRRTL module by
// the intrinsic lowering and read off the HW module by the UHDI emitter.
// Lowering creates a fresh hw.module, so this guards the allow-by-default
// attribute copy in FIRRTLModuleLowering::lowerModule.

// CHECK-LABEL: hw.module @Top
// CHECK-SAME: attributes {dbg.moduleinfo = {params = [{name = "width", value = "8"}], typeName = "MySourceType"}}
firrtl.circuit "Top" {
  firrtl.module @Top(in %a: !firrtl.uint<8>, out %b: !firrtl.uint<8>)
      attributes {dbg.moduleinfo = {params = [{name = "width", value = "8"}],
                                    typeName = "MySourceType"}} {
    firrtl.connect %b, %a : !firrtl.uint<8>, !firrtl.uint<8>
  }
}

// -----

// The same record on an instance must survive as well: FIRRTL->HW lowering
// builds a fresh hw.instance, and the emitter reads the record off it.

// CHECK-LABEL: hw.module @Instance
// CHECK: hw.instance "sub"
// CHECK-SAME: dbg.moduleinfo = {typeName = "MySub"}
firrtl.circuit "Instance" {
  firrtl.module private @Sub(in %a: !firrtl.uint<8>) {}
  firrtl.module @Instance(in %a: !firrtl.uint<8>) {
    %sub_a = firrtl.instance sub {dbg.moduleinfo = {typeName = "MySub"}}
        @Sub(in a: !firrtl.uint<8>)
    firrtl.matchingconnect %sub_a, %a : !firrtl.uint<8>
  }
}

// -----

// An instance_choice lowers to one hw.instance per case. All of them carry the
// record: they describe a single instance in the source.

// CHECK-LABEL: hw.module @Choice
// CHECK: hw.instance "inst_FPGA"
// CHECK-SAME: dbg.moduleinfo = {typeName = "MyChoice"}
// CHECK: hw.instance "inst_ASIC"
// CHECK-SAME: dbg.moduleinfo = {typeName = "MyChoice"}
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
        dbg.moduleinfo = {typeName = "MyChoice"},
        instance_macro = @targets$Opt$Choice$inst}
        @ModuleDefault alternatives @Opt
        { @FPGA -> @ModuleFPGA, @ASIC -> @ModuleDefault }
        (in in: !firrtl.uint<8>)
    firrtl.matchingconnect %inst_in, %in : !firrtl.uint<8>
  }
}
