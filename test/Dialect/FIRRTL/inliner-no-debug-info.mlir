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
