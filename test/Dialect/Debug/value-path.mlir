// RUN: circt-opt %s --verify-roundtrip | FileCheck %s


firrtl.circuit "Top" {
  hw.hierpath private @left_path [@Top::@left]
  hw.hierpath private @right_path [@Top::@right, @Leaf]
  firrtl.module @Top() {
    firrtl.instance left sym @left @Leaf()
    firrtl.instance right sym @right @Leaf()
    // CHECK: %[[LEFT:.*]] = dbg.value path @left_path type "Leaf" ext "{}"
    %left = dbg.value path @left_path type "Leaf" ext "{}"
    // CHECK: dbg.variable "left", %[[LEFT]] kind instance : !dbg.value
    dbg.variable "left", %left kind instance : !dbg.value
    // CHECK: dbg.value path @right_path type "Leaf"
    %right = dbg.value path @right_path type "Leaf"
    dbg.variable "right", %right kind instance : !dbg.value
  }
  firrtl.module private @Leaf() {}
}
