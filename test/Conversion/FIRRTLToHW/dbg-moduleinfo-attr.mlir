// RUN: circt-opt --lower-firrtl-to-hw %s | FileCheck %s

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
