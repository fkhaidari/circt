// RUN: circt-opt %s -verify-diagnostics | circt-opt -verify-diagnostics | FileCheck %s

hw.module @Leaf(in %a: i1) {}

// Descriptions can appear before or after their target instance.
// CHECK-LABEL: hw.module @ForwardRef
hw.hierpath private @debug_ForwardRef_x [@ForwardRef::@x]
hw.module @ForwardRef(in %a: i1) {
  // CHECK-NEXT: hw.instance "x" sym @x @Leaf(a: %a: i1) -> (){{$}}
  // CHECK-NEXT: [[SCOPE:%.+]] = dbg.value path @debug_ForwardRef_x type "C"
  // CHECK-NEXT: dbg.variable "c", [[SCOPE]] : !dbg.value
  hw.instance "x" sym @x @Leaf(a: %a: i1) -> ()
  %0 = dbg.value path @debug_ForwardRef_x type "C"
  dbg.variable "c", %0 : !dbg.value
}

// Instance attributes are independent of its debug description.
// CHECK-LABEL: hw.module @Scope
hw.hierpath private @debug_Scope_x [@Scope::@x]
hw.module @Scope(in %a: i1) {
  // CHECK-NEXT: [[SCOPE:%.+]] = dbg.value path @debug_Scope_x type "C"
  // CHECK-NEXT: dbg.variable "c", [[SCOPE]] : !dbg.value
  // CHECK-NEXT: hw.instance "x" sym @x @Leaf(a: %a: i1) -> () {sv.namehint = "x"}
  // CHECK-NEXT: hw.instance "y" @Leaf(a: %a: i1) -> (){{$}}
  %0 = dbg.value path @debug_Scope_x type "C"
  dbg.variable "c", %0 : !dbg.value
  hw.instance "x" sym @x @Leaf(a: %a: i1) -> () {sv.namehint = "x"}
  hw.instance "y" @Leaf(a: %a: i1) -> ()
}
