// RUN: circt-opt --arc-resolve-xmr %s | FileCheck %s

// Both sites that rebuild an instance keep its debug scope operand.

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
  hw.module @BoreTop(out out : i8) {
    // CHECK: [[S:%.+]] = dbg.scope "bore", "Bore"
    // CHECK: hw.instance "leaf_inst" sym @leaf_inst @BoreLeaf() -> (xmr_bored_sig_{{[0-9]+}}: i8) scope [[S]]
    %s = dbg.scope "bore", "Bore"
    hw.instance "leaf_inst" sym @leaf_inst @BoreLeaf() -> () scope %s
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
  hw.module @Host(in %src_in : i8 {hw.exportPort = #hw<innerSym@src>}, out out : i8) {
    // CHECK: [[S2:%.+]] = dbg.scope "bind", "Bind"
    // CHECK: hw.instance "payload" sym @payload @Payload(xmr_capture_src_{{[0-9]+}}: %src_in: i8) -> (o: i8) scope [[S2]] {doNotPrint}
    %s = dbg.scope "bind", "Bind"
    %p = hw.instance "payload" sym @payload @Payload() -> (o: i8) scope %s {doNotPrint}
    hw.output %p : i8
  }

  sv.bind <@Host::@payload>
}
