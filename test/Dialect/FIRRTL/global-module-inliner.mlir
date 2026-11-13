// RUN: circt-opt %s --split-input-file --firrtl-inliner='emit-debug-info=true' | FileCheck %s

firrtl.circuit "Top" {
  dbg.module @TopDebug type "demo.Top" impl @Top
  dbg.module @LeafDebug type "demo.Leaf" ext "{}" impl @Leaf
  firrtl.module @Top() {
    firrtl.instance left @Leaf()
    firrtl.instance right @Leaf()
  }
  firrtl.module private @Leaf() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %value = firrtl.wire : !firrtl.uint<8>
    dbg.variable "value", %value : !firrtl.uint<8>
  }
}

// CHECK: dbg.module @TopDebug type "demo.Top" impl @Top
// CHECK: dbg.module @LeafDebug type "demo.Leaf" ext "{}"{{$}}
// CHECK: firrtl.module @Top
// CHECK: %[[LEFT:.*]] = dbg.scope "left" def @LeafDebug
// CHECK: dbg.variable "value", {{.*}} scope %[[LEFT]]
// CHECK: %[[RIGHT:.*]] = dbg.scope "right" def @LeafDebug
// CHECK: dbg.variable "value", {{.*}} scope %[[RIGHT]]
// CHECK-NOT: firrtl.module private @Leaf

// -----

firrtl.circuit "Fallback" {
  firrtl.module @Fallback() {
    firrtl.instance left @Unannotated()
    firrtl.instance right @Unannotated()
  }
  firrtl.module private @Unannotated() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %data = firrtl.wire : !firrtl.uint<8>
    dbg.variable "data", %data : !firrtl.uint<8>
  }
}

// CHECK: dbg.scope "left" def @[[DEF:[a-zA-Z0-9_]+]]
// CHECK: dbg.scope "right" def @[[DEF]]
// CHECK: dbg.module @[[DEF]] type "Unannotated"{{$}}
