// RUN: circt-opt %s --split-input-file --verify-diagnostics

// A scope defined after its child does not dominate the child.
firrtl.circuit "Forward" {
  firrtl.module private @Leaf() {}
  firrtl.module @Forward() {
    // expected-error @below {{operand #0 does not dominate this use}}
    %child = dbg.scope "l" scope %s
    // expected-note @below {{operand defined here}}
    %s = dbg.scope "x"
  }
}

// -----

firrtl.circuit "NotAScope" {
  firrtl.module private @Leaf() {}
  // expected-note @below {{prior use here}}
  firrtl.module @NotAScope(in %a: !firrtl.uint<1>) {
    // expected-error @below {{use of value '%a' expects different type than prior uses}}
    %child = dbg.scope "l" scope %a
  }
}
