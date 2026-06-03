// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-uhdi-init)))' %s | FileCheck %s
// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-uhdi-init,firrtl-uhdi-init)))' %s | FileCheck --check-prefix=IDEM %s

// Every dbg.variable / dbg.scope / dbg.struct / dbg.array picks up a
// deterministic uhdi.stable_id attribute. The exact hash value is not
// asserted (it would lock us into an implementation detail); instead we
// match the shape `<kind>_<hex>_<hex>`.
//
// (IDEM checks verify: ids issued by first run survive unchanged through second run.)

// CHECK-LABEL: firrtl.circuit "Ports"
// IDEM-LABEL: firrtl.circuit "Ports"
firrtl.circuit "Ports" {

  // CHECK-LABEL: firrtl.module @Ports
  // IDEM-LABEL: firrtl.module @Ports
  firrtl.module @Ports(in %a: !firrtl.uint<8>, out %b: !firrtl.uint<8>) {
    // CHECK: dbg.variable "a", %a {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    // IDEM:  dbg.variable "a", %a {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "a", %a : !firrtl.uint<8>
    // CHECK: dbg.variable "b", %b {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    // IDEM:  dbg.variable "b", %b {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "b", %b : !firrtl.uint<8>
    firrtl.matchingconnect %b, %a : !firrtl.uint<8>
  }

  // CHECK-LABEL: firrtl.module @InlineScope
  // IDEM-LABEL: firrtl.module @InlineScope
  firrtl.module @InlineScope(in %x: !firrtl.uint<8>, out %y: !firrtl.uint<8>) {
    // CHECK: [[S:%.+]] = dbg.scope "l", "Leaf" {uhdi.stable_id = "{{scope_[0-9a-f]+_[0-9a-f]+}}"}
    // IDEM:  {{%.+}} = dbg.scope "l", "Leaf" {uhdi.stable_id = "{{scope_[0-9a-f]+_[0-9a-f]+}}"}
    %s = dbg.scope "l", "Leaf"
    // CHECK: dbg.variable "x", %x scope [[S]] {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    // IDEM:  dbg.variable "x", %x scope {{%.+}} {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "x", %x scope %s : !firrtl.uint<8>
    firrtl.matchingconnect %y, %x : !firrtl.uint<8>
  }

  // CHECK-LABEL: firrtl.module @Aggregate
  // IDEM-LABEL: firrtl.module @Aggregate
  firrtl.module @Aggregate(in %ia: !firrtl.uint<4>, in %ib: !firrtl.uint<4>, out %o: !firrtl.uint<8>) {
    // Aggregates are anonymous value constructors, not addressable entities:
    // the emitter walks into their operands per field and never looks up an
    // id for them. Stamping one would only add an attribute nothing reads.
    // CHECK: [[ST:%.+]] = dbg.struct {"a": %ia, "b": %ib} :
    // IDEM:  {{%.+}} = dbg.struct {"a": %ia, "b": %ib} :
    %st = dbg.struct {"a": %ia, "b": %ib} : !firrtl.uint<4>, !firrtl.uint<4>
    // CHECK: dbg.variable "io", [[ST]] {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    // IDEM:  dbg.variable "io", {{%.+}} {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "io", %st : !dbg.struct
    firrtl.connect %o, %ia : !firrtl.uint<8>, !firrtl.uint<4>
  }

  // Idempotent: already-stamped ids survive a second run unchanged.
  // CHECK-LABEL: firrtl.module @Idempotent
  // IDEM-LABEL: firrtl.module @Idempotent
  firrtl.module @Idempotent(in %p: !firrtl.uint<1>) {
    // CHECK: dbg.variable "p", %p {uhdi.stable_id = "preset_id"}
    // IDEM:  dbg.variable "p", %p {uhdi.stable_id = "preset_id"}
    dbg.variable "p", %p {uhdi.stable_id = "preset_id"} : !firrtl.uint<1>
  }

  // Two aggregates in one module stay unstamped, while the variables that name
  // them still get distinct ids. An id on the aggregate would have no consumer
  // and, once the inliner clones the body, no way to stay unique either: a
  // dbg.struct has no scope operand for the fingerprint to hash.
  // CHECK-LABEL: firrtl.module @DistinctStructs
  firrtl.module @DistinctStructs(in %x: !firrtl.uint<4>, in %y: !firrtl.uint<4>, out %o: !firrtl.uint<4>) {
    // CHECK: [[S1:%.+]] = dbg.struct {"foo": %x} :
    %s1 = dbg.struct {"foo": %x} : !firrtl.uint<4>
    // CHECK: [[S2:%.+]] = dbg.struct {"bar": %y} :
    %s2 = dbg.struct {"bar": %y} : !firrtl.uint<4>
    // CHECK: dbg.variable "v1", [[S1]] {uhdi.stable_id = "[[ID1:var_[0-9a-f]+_[0-9a-f]+]]"}
    dbg.variable "v1", %s1 : !dbg.struct
    // CHECK-NOT: uhdi.stable_id = "[[ID1]]"
    // CHECK: dbg.variable "v2", [[S2]] {uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"}
    dbg.variable "v2", %s2 : !dbg.struct
    firrtl.matchingconnect %o, %x : !firrtl.uint<4>
  }
}
