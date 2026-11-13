// RUN: circt-opt %s --pass-pipeline='builtin.module(firrtl.circuit(firrtl-materialize-debug-info))' | FileCheck %s

firrtl.circuit "Top" {
  hw.hierpath private @child [@Top::@child]
  firrtl.module private @Child() {}
  firrtl.module @Top() {
    %q = dbg.value path @child type "Child"
    dbg.variable "sourceChild", %q : !dbg.value
    firrtl.instance child sym @child @Child()
    firrtl.instance other @Child()
  }
}
// CHECK-LABEL: firrtl.module @Top
// CHECK-NEXT: %[[Q:.*]] = dbg.value path @child type "Child"
// CHECK-NEXT: dbg.variable "sourceChild", %[[Q]] : !dbg.value
// CHECK-NEXT: firrtl.instance child sym @child @Child()
// CHECK-NEXT: firrtl.instance other
// CHECK-NEXT: %[[OTHER:.*]] = dbg.value path @{{.*}} type "Child"
// CHECK-NEXT: dbg.variable "other", %[[OTHER]] kind instance : !dbg.value
// CHECK-NEXT: }
