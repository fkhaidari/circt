// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl-inliner{emit-debug-info=false}))' %s | FileCheck %s --check-prefix=OFF

// Without debug info, no dbg.scope is created for the inlined instance and
// the inlined debug variable keeps no scope.

// OFF-LABEL: firrtl.circuit "NoScopes"
firrtl.circuit "NoScopes" {
  // OFF: firrtl.module @NoScopes
  // OFF-NOT: dbg.scope
  // OFF: dbg.variable "a", {{%.+}} :
  firrtl.module @NoScopes() {
    firrtl.instance foo @Foo()
  }
  firrtl.module private @Foo() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    %wire = firrtl.wire : !firrtl.uint<1>
    dbg.variable "a", %wire : !firrtl.uint<1>
  }
}

// Without debug info, the instances of an inlined module get no scope.

// OFF-LABEL: firrtl.circuit "NoInstanceScopes"
firrtl.circuit "NoInstanceScopes" {
  // OFF: firrtl.module @NoInstanceScopes
  // OFF-NEXT: firrtl.instance foo_leaf @Leaf(){{$}}
  firrtl.module @NoInstanceScopes() {
    firrtl.instance foo @Foo()
  }
  firrtl.module private @Foo() attributes {annotations = [{class = "firrtl.passes.InlineAnnotation"}]} {
    firrtl.instance leaf @Leaf()
  }
  firrtl.module private @Leaf() {}
}
