// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-uhdi-init)))' %s | FileCheck %s

// Every dbg.variable / dbg.scope / dbg.struct / dbg.array picks up a
// deterministic uhdi.stable_id attribute. The exact hash value is not
// asserted (it would lock us into an implementation detail); instead we
// match the shape `<kind>_<hex>_<hex>`.

// CHECK-LABEL: firrtl.circuit "Ports"
firrtl.circuit "Ports" {

  // CHECK-LABEL: firrtl.module @Ports
  firrtl.module @Ports(in %a: !firrtl.uint<8>, out %b: !firrtl.uint<8>) {
    // CHECK: dbg.variable "a", %a {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "a", %a : !firrtl.uint<8>
    // CHECK: dbg.variable "b", %b {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "b", %b : !firrtl.uint<8>
    firrtl.matchingconnect %b, %a : !firrtl.uint<8>
  }

  // CHECK-LABEL: firrtl.module @InlineScope
  firrtl.module @InlineScope(in %x: !firrtl.uint<8>, out %y: !firrtl.uint<8>) {
    // CHECK: [[S:%.+]] = dbg.scope "l", "Leaf" {uhdi.stable_id = "{{scope_[0-9a-f]+_[0-9a-f]+}}"}
    %s = dbg.scope "l", "Leaf"
    // CHECK: dbg.variable "x", %x scope [[S]] {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "x", %x scope %s : !firrtl.uint<8>
    firrtl.matchingconnect %y, %x : !firrtl.uint<8>
  }

  // CHECK-LABEL: firrtl.module @Aggregate
  firrtl.module @Aggregate(in %ia: !firrtl.uint<4>, in %ib: !firrtl.uint<4>, out %o: !firrtl.uint<8>) {
    // CHECK: [[ST:%.+]] = dbg.struct {"a": %ia, "b": %ib} {uhdi.stable_id = "{{struct_[0-9a-f]+_[0-9a-f]+}}"}
    %st = dbg.struct {"a": %ia, "b": %ib} : !firrtl.uint<4>, !firrtl.uint<4>
    // CHECK: dbg.variable "io", [[ST]] {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "io", %st : !dbg.struct
    firrtl.connect %o, %ia : !firrtl.uint<8>, !firrtl.uint<4>
  }

  // Idempotent: already-stamped ids survive a second run unchanged.
  // CHECK-LABEL: firrtl.module @Idempotent
  firrtl.module @Idempotent(in %p: !firrtl.uint<1>) {
    // CHECK: dbg.variable "p", %p {uhdi.stable_id = "preset_id"}
    dbg.variable "p", %p {uhdi.stable_id = "preset_id"} : !firrtl.uint<1>
  }
}
