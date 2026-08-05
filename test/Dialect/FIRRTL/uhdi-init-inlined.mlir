// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-uhdi-init),firrtl-inliner,firrtl.module(firrtl-uhdi-init)))' %s | FileCheck %s

// Inlining clones a module body once per instance, so the two copies of
// `Child` land in `Parent` describing different instances. Each copy must end
// up with its own id: the clones must neither keep the id stamped on the
// original before inlining nor hash onto a shared prefix, where only the
// walk-order counter would tell them apart.

firrtl.circuit "Parent" {

  // CHECK-LABEL: firrtl.module @Parent
  firrtl.module @Parent(in %a: !firrtl.uint<8>) {
    %c0_x = firrtl.instance c0 @Child(in x: !firrtl.uint<8>)
    %c1_x = firrtl.instance c1 @Child(in x: !firrtl.uint<8>)
    firrtl.matchingconnect %c0_x, %a : !firrtl.uint<8>
    firrtl.matchingconnect %c1_x, %a : !firrtl.uint<8>
  }

  firrtl.module private @Child(in %x: !firrtl.uint<8>) attributes {
      annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %st = dbg.struct {"f": %x} : !firrtl.uint<8>
    dbg.variable "x", %st : !dbg.struct
  }
}

// The scope of each inline site carries its own id ...
// CHECK: dbg.scope "c0", "Child" {uhdi.stable_id = "[[SCOPE0:scope_[0-9a-f]+_[0-9a-f]+]]"}
// ... and the variable cloned under it hashes on that scope, so its prefix
// differs from the other site's rather than only its counter.
// CHECK: dbg.variable "x", %{{.+}} scope %{{.+}} {uhdi.stable_id = "var_[[PREFIX:[0-9a-f]+]]_{{[0-9a-f]+}}"}
// CHECK: dbg.scope "c1", "Child" {uhdi.stable_id = "scope_{{[0-9a-f]+_[0-9a-f]+}}"}
// CHECK-NOT: uhdi.stable_id = "var_[[PREFIX]]_
// CHECK-NOT: uhdi.stable_id = "[[SCOPE0]]"

// The cloned aggregates carry no id at all. They have no scope operand, so a
// fingerprint could not tell the two copies apart even in principle; the
// emitter reads them structurally and never looks an id up for them.
// CHECK-NOT: dbg.struct {{.*}}uhdi.stable_id
