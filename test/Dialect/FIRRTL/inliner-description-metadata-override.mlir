// RUN: circt-opt %s --firrtl-inliner | FileCheck %s
firrtl.circuit "Top" {
  hw.hierpath private @childPath [@Top::@child]
  firrtl.module @Top() {
    %parent = dbg.scope "lexical"
    %description = dbg.value path @childPath type "Override"
    dbg.variable "sourceChild", %description scope %parent : !dbg.value
    firrtl.instance child sym @child @Child()
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %data = firrtl.wire : !firrtl.uint<8>
    dbg.variable "data", %data : !firrtl.uint<8>
  }
}
// CHECK: %[[PARENT:.*]] = dbg.scope "lexical"
// CHECK: %[[DESCRIPTION:.*]] = dbg.value path @childPath type "Override"
// CHECK: dbg.variable "sourceChild", %[[DESCRIPTION]] scope %[[PARENT]]
// CHECK: %[[CHILD:.*]] = dbg.scope "sourceChild" scope %[[PARENT]] sym @child
// CHECK: dbg.variable "data", {{.*}} scope %[[CHILD]]
// CHECK-NOT: firrtl.module private @Child
