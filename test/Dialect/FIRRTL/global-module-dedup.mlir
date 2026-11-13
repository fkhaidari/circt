// RUN: circt-opt %s --split-input-file --firrtl-dedup | FileCheck %s

firrtl.circuit "Top" {
  dbg.module @ADebug type "demo.Leaf" impl @A
  dbg.module @BDebug type "demo.Leaf" impl @B
  dbg.module @CDebug type "demo.Other" impl @C
  firrtl.module private @A() {}
  firrtl.module private @B() {}
  firrtl.module private @C() {}
  firrtl.module @Top() {
    firrtl.instance left @A()
    firrtl.instance right @B()
    firrtl.instance other @C()
    %scope = dbg.scope "previous" def @BDebug
  }
}

// CHECK: dbg.module @ADebug type "demo.Leaf" impl @A
// CHECK-NOT: dbg.module @BDebug
// CHECK: dbg.module @CDebug type "demo.Other" impl @C
// CHECK: firrtl.module private @A
// CHECK-NOT: firrtl.module private @B
// CHECK: firrtl.module private @C
// CHECK: firrtl.instance left @A
// CHECK: firrtl.instance right @A
// CHECK: firrtl.instance other @C
// CHECK: dbg.scope "previous" def @ADebug

// -----

firrtl.circuit "Top" {
  dbg.module @ADebug type "demo.External" impl @A
  dbg.module @BDebug type "demo.External" impl @B
  dbg.module @CDebug type "demo.OtherExternal" impl @C
  firrtl.extmodule private @A() attributes {defname = "BlackBox"}
  firrtl.extmodule private @B() attributes {defname = "BlackBox"}
  firrtl.extmodule private @C() attributes {defname = "BlackBox"}
  hw.hierpath private @rightPath [@Top::@right]
  firrtl.module @Top() {
    firrtl.instance left @A()
    firrtl.instance right sym @right @B()
    firrtl.instance other @C()
    %right = dbg.value path @rightPath def @BDebug
    dbg.variable "right", %right kind instance : !dbg.value
  }
}

// CHECK: dbg.module @ADebug type "demo.External" impl @A
// CHECK-NOT: dbg.module @BDebug
// CHECK: dbg.module @CDebug type "demo.OtherExternal" impl @C
// CHECK: firrtl.extmodule private @A
// CHECK-NOT: firrtl.extmodule private @B
// CHECK: firrtl.extmodule private @C
// CHECK: firrtl.instance left @A
// CHECK: firrtl.instance right sym @right @A
// CHECK: firrtl.instance other @C
// CHECK: dbg.value path @rightPath def @ADebug
