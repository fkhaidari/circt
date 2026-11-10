// RUN: circt-opt %s -verify-diagnostics | circt-opt -verify-diagnostics | FileCheck %s

hw.module @Leaf(in %a: i1) {}

// The scope may be used before it is defined, with no Debug op before it.
// CHECK-LABEL: hw.module @ForwardRef
hw.module @ForwardRef(in %a: i1) {
  // CHECK-NEXT: hw.instance "x" @Leaf(a: %a: i1) -> () scope [[SCOPE:%.+]]{{$}}
  // CHECK-NEXT: [[SCOPE]] = dbg.scope "c", "C"
  hw.instance "x" @Leaf(a: %a: i1) -> () scope %0
  %0 = dbg.scope "c", "C"
}

// The scope is printed before the attributes. An instance without a scope
// prints none.
// CHECK-LABEL: hw.module @Scope
hw.module @Scope(in %a: i1) {
  // CHECK-NEXT: [[SCOPE:%.+]] = dbg.scope "c", "C"
  // CHECK-NEXT: hw.instance "x" @Leaf(a: %a: i1) -> () scope [[SCOPE]] {sv.namehint = "x"}
  // CHECK-NEXT: hw.instance "y" @Leaf(a: %a: i1) -> (){{$}}
  %0 = dbg.scope "c", "C"
  hw.instance "x" @Leaf(a: %a: i1) -> () scope %0 {sv.namehint = "x"}
  hw.instance "y" @Leaf(a: %a: i1) -> ()
}
