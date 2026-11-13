// RUN: circt-opt %s --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-dedup,firrtl-inliner{emit-debug-info=true}))' | FileCheck %s --check-prefix=META
// META-DAG: dbg.module @{{[^ ]+}} type "SourceClass"
// RUN: circt-opt %s --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-dedup,firrtl-inliner{emit-debug-info=true}))' | FileCheck %s
// RUN: circt-opt %s --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-dedup,firrtl-inliner{emit-debug-info=true},firrtl-dedup))' | FileCheck %s

firrtl.circuit "Top" {
  hw.hierpath private @leftChild [@Top::@left, @Wrapper::@child, @Child]
  hw.hierpath private @unrelated [@Top::@left, @Wrapper::@child, @Child::@value]
  hw.hierpath private @rightChild [@Top::@right, @Wrapper::@child, @Child]
  firrtl.module @Top() {
    %left = dbg.value path @leftChild type "LeftSource" ext "{\22x-test\22:1}"
    dbg.variable "leftChild", %left : !dbg.value
    %right = dbg.value path @rightChild type "RightSource" ext "{\22x-test\22:2}"
    dbg.variable "rightChild", %right : !dbg.value
    firrtl.instance left sym @left @Wrapper()
    firrtl.instance right sym @right @Wrapper()
  }
  firrtl.module private @Wrapper() {
    firrtl.instance child sym @child @Child()
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire sym @value : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}
// CHECK: hw.hierpath private @leftChild [@Top::@left, @Wrapper::@child]
// CHECK: hw.hierpath private @unrelated [@Top::@left, @Wrapper::@value]
// CHECK: hw.hierpath private @rightChild [@Top::@right, @Wrapper::@child]
// CHECK-LABEL: firrtl.module @Top
// CHECK: %[[LEFT:.*]] = dbg.value path @leftChild type "LeftSource" ext "{\22x-test\22:1}"
// CHECK: dbg.variable "leftChild", %[[LEFT]]
// CHECK: %[[RIGHT:.*]] = dbg.value path @rightChild type "RightSource" ext "{\22x-test\22:2}"
// CHECK: dbg.variable "rightChild", %[[RIGHT]]
// CHECK: firrtl.instance left sym @left @Wrapper
// CHECK: firrtl.instance right sym @right @Wrapper
// CHECK-LABEL: firrtl.module private @Wrapper()
// CHECK: %[[CHILD:.*]] = dbg.scope "child" sym @child
// CHECK: dbg.variable "value", {{.*}} scope %[[CHILD]]
// CHECK-NOT: firrtl.module private @Child

// -----

firrtl.circuit "Forward" {
  dbg.module @ValueDefinition0 type "SourceClass"
  hw.hierpath private @inliner_desc_0 [@Wrapper::@child]
  firrtl.module @Forward() {
    firrtl.instance wrapper @Wrapper()
  }
  firrtl.module private @Wrapper() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    firrtl.instance child sym @child @Child()
    %parent = dbg.scope "lexical"
    %description = dbg.value path @inliner_desc_0 def @ValueDefinition0
    dbg.variable "sourceChild", %description scope %parent : !dbg.value
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}
// CHECK-LABEL: firrtl.circuit "Forward"
// CHECK: %[[WRAPPER:.*]] = dbg.scope "wrapper"
// CHECK: %[[PARENT:.*]] = dbg.scope "lexical" scope %[[WRAPPER]]
// CHECK: %[[DESCRIPTION:.*]] = dbg.scope "sourceChild" scope %[[PARENT]]
// CHECK: dbg.variable "value", {{.*}} scope %[[DESCRIPTION]]
// CHECK-NOT: dbg.scope

// -----

firrtl.circuit "Repeated" {
  dbg.module @ValueDefinition1 type "SourceChild"
  hw.hierpath private @nested [@Container::@mid, @Mid::@child]
  firrtl.module @Repeated() {
    firrtl.instance left @Container()
    firrtl.instance right @Container()
  }
  firrtl.module private @Container() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %description = dbg.value path @nested def @ValueDefinition1
    dbg.variable "sourceChild", %description : !dbg.value
    firrtl.instance mid sym @mid @Mid()
  }
  firrtl.module private @Mid() {
    firrtl.instance child sym @child @Child()
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}
// CHECK-LABEL: firrtl.circuit "Repeated"
// CHECK-DAG: hw.hierpath private @[[LEFTPATH:[a-zA-Z0-9_]+]] [@Repeated::@mid, @Mid::@child]
// CHECK-DAG: hw.hierpath private @[[RIGHTPATH:[a-zA-Z0-9_]+]] [@Repeated::@mid_0, @Mid::@child]
// CHECK: %[[LEFTOWNER:.*]] = dbg.scope "left"
// CHECK: %[[LV:.*]] = dbg.value path @[[LEFTPATH]] def @ValueDefinition1
// CHECK: dbg.variable "sourceChild", %[[LV]] scope %[[LEFTOWNER]]
// CHECK: %[[RIGHTOWNER:.*]] = dbg.scope "right"
// CHECK: %[[RV:.*]] = dbg.value path @[[RIGHTPATH]] def @ValueDefinition1
// CHECK: dbg.variable "sourceChild", %[[RV]] scope %[[RIGHTOWNER]]

// -----

firrtl.circuit "LateTop" {
  dbg.module @ValueDefinition2 type "SourceChild"
  hw.hierpath private @inliner_desc_0 [@LateTop::@child]
  firrtl.module @LateTop() {
    firrtl.instance child sym @child @Child()
    %description = dbg.value path @inliner_desc_0 def @ValueDefinition2
    dbg.variable "sourceChild", %description : !dbg.value
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}
// CHECK-LABEL: firrtl.circuit "LateTop"
// CHECK: %[[BODY:.*]] = dbg.scope "sourceChild" sym @child
// CHECK: dbg.variable "value", {{.*}} scope %[[BODY]]

// -----

firrtl.circuit "SharedPath" {
  dbg.module @ValueDefinition3 type "SourceChild"
  hw.hierpath private @shared [@SharedPath::@wrapper, @Wrapper::@child, @Child]
  firrtl.module @SharedPath() {
    %description = dbg.value path @shared def @ValueDefinition3
    dbg.variable "sourceChild", %description : !dbg.value
    firrtl.instance wrapper sym @wrapper @Wrapper()
  }
  firrtl.module private @Wrapper() {
    firrtl.instance child sym @child @Child()
  }
  firrtl.module private @Child() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire {annotations = [{class = "test.annotation", circt.nonlocal = @shared}]} : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}
// CHECK-LABEL: firrtl.circuit "SharedPath"
// CHECK: hw.hierpath private @shared_debug [@SharedPath::@wrapper, @Wrapper::@child]
// CHECK: hw.hierpath private @shared [@SharedPath::@wrapper, @Wrapper]
// CHECK: dbg.value path @shared_debug def @ValueDefinition3
// CHECK: dbg.variable "sourceChild"
// CHECK: circt.nonlocal = @shared
