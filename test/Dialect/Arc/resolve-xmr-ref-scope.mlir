// RUN: circt-opt --arc-resolve-xmr %s | FileCheck %s

// Both sites that rebuild an instance preserve its debug description target.

module {
  hw.hierpath @borePath [@BoreTop::@leaf_inst, @BoreLeaf::@sig]
  hw.hierpath @bindPath [@Host::@src]

  // Boring a port out of BoreLeaf rebuilds its instance.
  hw.module @BoreLeaf() {
    %c = hw.constant 7 : i8
    %s = hw.wire %c sym @sig : i8
    hw.output
  }

  // CHECK-LABEL: hw.module @BoreTop
  hw.hierpath private @debug_BoreTop_leaf_inst [@BoreTop::@leaf_inst]
  hw.module @BoreTop(out out : i8) {
    // CHECK: [[S:%.+]] = dbg.value path @debug_BoreTop_leaf_inst type "Bore"
    // CHECK: dbg.variable "bore", [[S]] : !dbg.value
    // CHECK: hw.instance "leaf_inst" sym @leaf_inst @BoreLeaf() -> (xmr_bored_sig_{{[0-9]+}}: i8)
    %s = dbg.value path @debug_BoreTop_leaf_inst type "Bore"
    dbg.variable "bore", %s : !dbg.value
    hw.instance "leaf_inst" sym @leaf_inst @BoreLeaf() -> ()
    %x = sv.xmr.ref @borePath : !hw.inout<i8>
    %r = sv.read_inout %x : !hw.inout<i8>
    hw.output %r : i8
  }

  // Capturing a host value into a bound payload rebuilds the bind instance.
  hw.module @Payload(out o : i8) {
    %x = sv.xmr.ref @bindPath : !hw.inout<i8>
    %r = sv.read_inout %x : !hw.inout<i8>
    hw.output %r : i8
  }

  // CHECK-LABEL: hw.module @Host
  hw.hierpath private @debug_Host_payload [@Host::@payload]
  hw.module @Host(in %src_in : i8 {hw.exportPort = #hw<innerSym@src>}, out out : i8) {
    // CHECK: [[S2:%.+]] = dbg.value path @debug_Host_payload type "Bind"
    // CHECK: dbg.variable "bind", [[S2]] : !dbg.value
    // CHECK: hw.instance "payload" sym @payload @Payload(xmr_capture_src_{{[0-9]+}}: %src_in: i8) -> (o: i8) {doNotPrint}
    %s = dbg.value path @debug_Host_payload type "Bind"
    dbg.variable "bind", %s : !dbg.value
    %p = hw.instance "payload" sym @payload @Payload() -> (o: i8) {doNotPrint}
    hw.output %p : i8
  }

  sv.bind <@Host::@payload>
}
