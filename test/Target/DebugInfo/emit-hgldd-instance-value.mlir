// RUN: circt-translate %s --emit-hgldd | FileCheck %s

hw.hierpath private @child [@Top::@child]
hw.module @Leaf() {}
hw.module @Top(in %a: i8 loc("Top.scala":1:1)) {
  hw.instance "child" sym @child @Leaf() -> ()
  %value = dbg.value path @child type "Leaf"
  dbg.variable "child", %value : !dbg.value
}

// CHECK: "module_name": "Top"
// CHECK: "var_name": "a"
