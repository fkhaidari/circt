// RUN: circt-opt %s --symbol-dce | FileCheck %s

// CHECK: dbg.module @DeadDebug type "SourceDead" impl @Dead
// CHECK: dbg.module @TopDebug type "SourceTop" impl @Top
// CHECK: dbg.module @ExtDebug type "SourceExt" impl @Ext
// CHECK: dbg.module @BoundDebug type "SourceBound" impl @Bound
// CHECK: hw.module @Top
// CHECK: dbg.scope "former" def @DeadDebug
// CHECK: hw.module.extern private @Ext
// CHECK: hw.module private @Bound
// CHECK: hw.module private @Dead()
// CHECK: hw.module private @DeadChild()

dbg.module @DeadDebug type "SourceDead" impl @Dead
dbg.module @TopDebug type "SourceTop" impl @Top
dbg.module @ExtDebug type "SourceExt" impl @Ext
dbg.module @BoundDebug type "SourceBound" impl @Bound
hw.module @Top() attributes {real_reference = @Bound} {
  %scope = dbg.scope "former" def @DeadDebug
  hw.instance "ext" @Ext() -> ()
  hw.output
}
hw.module.extern private @Ext()
hw.module private @Bound() {
  hw.output
}
hw.module private @Dead() {
  hw.instance "child" @DeadChild() -> ()
  hw.output
}
hw.module private @DeadChild() {
  hw.output
}
