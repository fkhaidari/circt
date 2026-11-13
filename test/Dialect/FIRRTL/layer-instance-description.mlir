// RUN: circt-opt %s --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-lower-layers,firrtl-inliner{emit-debug-info=true}))' | FileCheck %s --check-prefix=META
// META-DAG: dbg.module @{{[^ ]+}} type "SourceOwner" ext "{\22x-test\22:1}"
// RUN: circt-opt %s --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-lower-layers,firrtl-inliner{emit-debug-info=true}))' | FileCheck %s

firrtl.circuit "Top" {
  hw.hierpath private @debug_Top_child [@Top::@child]
  firrtl.layer @A bind {}
  dbg.module @debug1 type "TopSource" impl @Top
  dbg.module @debug2 type "SourceOwner" ext "{\22x-test\22:1}"
  firrtl.module @Top(in %x: !firrtl.uint<8>) {

    %owner = dbg.scope "owner" def @debug2

    dbg.variable "outside", %x scope %owner : !firrtl.uint<8>
    %description = dbg.value path @debug_Top_child type "SourceChild"
    dbg.variable "sourceChild", %description scope %owner : !dbg.value
    firrtl.layerblock @A {
      dbg.variable "inside", %x scope %owner : !firrtl.uint<8>
      firrtl.instance child sym @child @Child()
    }
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}
// CHECK: hw.hierpath {{.*}}@debug_Top_child [@Top::@{{.*}}, @Top_A::@child]
// CHECK-LABEL: firrtl.module private @Top_A
// CHECK: %[[OWNER:.*]] = dbg.scope "owner"
// CHECK: dbg.variable "inside", {{.*}} scope %[[OWNER]]
// CHECK: %[[CHILD:.*]] = dbg.scope "child" sym @child
// CHECK: dbg.variable "value", {{.*}} scope %[[CHILD]]
// CHECK-LABEL: firrtl.module @Top
// CHECK: dbg.scope "owner"
// CHECK: dbg.variable "outside"
// CHECK: %[[DESC:.*]] = dbg.value path @debug_Top_child type "SourceChild"
// CHECK: dbg.variable "sourceChild", %[[DESC]] scope
