// RUN: circt-opt %s --pass-pipeline='builtin.module(firrtl.circuit(firrtl-inliner{emit-debug-info=true},symbol-dce))' | FileCheck %s --check-prefix=META
// META-DAG: dbg.module @{{[^ ]+}} type "EmptySource"
// RUN: circt-opt %s --pass-pipeline='builtin.module(firrtl.circuit(firrtl-inliner{emit-debug-info=true},symbol-dce))' | FileCheck %s

firrtl.circuit "Top" {
  dbg.module @ValueDefinition1 type "DeadChild"
  dbg.module @ValueDefinition0 type "EmptySource"
  hw.hierpath private @empty_path [@Top::@empty]
  hw.hierpath private @dead_path [@DeadParent::@child]
  firrtl.module @Top() {
    %description = dbg.value path @empty_path def @ValueDefinition0
    dbg.variable "sourceEmpty", %description : !dbg.value
    firrtl.instance empty sym @empty @Empty()
  }
  firrtl.module private @Empty() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {}
  firrtl.module private @DeadParent() {
    %description = dbg.value path @dead_path def @ValueDefinition1
    dbg.variable "unreachableChild", %description : !dbg.value
    firrtl.instance child sym @child @DeadChild()
  }
  firrtl.module private @DeadChild() {}
}
// CHECK-LABEL: firrtl.module @Top
// CHECK: dbg.scope "sourceEmpty"
// CHECK-NOT: firrtl.instance
// CHECK-NOT: @Empty
// CHECK-NOT: @DeadParent
// CHECK-NOT: @DeadChild
// CHECK-NOT: unreachableChild
