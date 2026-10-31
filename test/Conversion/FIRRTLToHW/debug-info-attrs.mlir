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

// -----

// A memory keeps its description on the `seq.firmem` it lowers to.

// CHECK-LABEL: hw.module @Memory
// CHECK: seq.firmem
// CHECK-SAME: dbg.instance = [#dbg.instance<name = "mem">]
firrtl.circuit "Memory" {
  firrtl.module @Memory(in %clk: !firrtl.clock, in %addr: !firrtl.uint<2>,
                        in %en: !firrtl.uint<1>, out %data: !firrtl.uint<8>) {
    %mem_r = firrtl.mem Undefined {dbg.instance = [#dbg.instance<name = "mem">], depth = 4 : i64, name = "mem", portNames = ["r"], readLatency = 0 : i32, writeLatency = 1 : i32} : !firrtl.bundle<addr: uint<2>, en: uint<1>, clk: clock, data flip: uint<8>>
    %0 = firrtl.subfield %mem_r[addr] : !firrtl.bundle<addr: uint<2>, en: uint<1>, clk: clock, data flip: uint<8>>
    firrtl.matchingconnect %0, %addr : !firrtl.uint<2>
    %1 = firrtl.subfield %mem_r[en] : !firrtl.bundle<addr: uint<2>, en: uint<1>, clk: clock, data flip: uint<8>>
    firrtl.matchingconnect %1, %en : !firrtl.uint<1>
    %2 = firrtl.subfield %mem_r[clk] : !firrtl.bundle<addr: uint<2>, en: uint<1>, clk: clock, data flip: uint<8>>
    firrtl.matchingconnect %2, %clk : !firrtl.clock
    %3 = firrtl.subfield %mem_r[data] : !firrtl.bundle<addr: uint<2>, en: uint<1>, clk: clock, data flip: uint<8>>
    firrtl.matchingconnect %data, %3 : !firrtl.uint<8>
  }
}
