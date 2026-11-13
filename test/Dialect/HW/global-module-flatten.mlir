// RUN: circt-opt %s --split-input-file --hw-flatten-modules | FileCheck %s

dbg.module @TopDebug type "demo.Top" impl @Top
dbg.module @LeafDebug type "demo.Leaf" ext "{}" impl @Leaf
hw.module @Top(in %value: i8) {
  hw.instance "left" @Leaf(value: %value: i8) -> ()
  hw.instance "right" @Leaf(value: %value: i8) -> ()
  hw.output
}
hw.module private @Leaf(in %value: i8) {
  dbg.variable "value", %value : i8
  hw.output
}

// CHECK: dbg.module @TopDebug type "demo.Top" impl @Top
// CHECK: dbg.module @LeafDebug type "demo.Leaf" ext "{}"{{$}}
// CHECK: hw.module @Top
// CHECK: %[[LEFT:.*]] = dbg.scope "left" def @LeafDebug
// CHECK: dbg.variable "value", {{.*}} scope %[[LEFT]]
// CHECK: %[[RIGHT:.*]] = dbg.scope "right" def @LeafDebug
// CHECK: dbg.variable "value", {{.*}} scope %[[RIGHT]]
// CHECK-NOT: hw.module private @Leaf

// -----

hw.module @Fallback(in %data: i8) {
  hw.instance "left" @Unannotated(data: %data: i8) -> ()
  hw.instance "right" @Unannotated(data: %data: i8) -> ()
  hw.output
}
hw.module private @Unannotated(in %data: i8) {
  dbg.variable "data", %data : i8
  hw.output
}

// CHECK: dbg.scope "left" def @[[DEF:[a-zA-Z0-9_]+]]
// CHECK: dbg.scope "right" def @[[DEF]]
// CHECK: dbg.module @[[DEF]] type "Unannotated"{{$}}
