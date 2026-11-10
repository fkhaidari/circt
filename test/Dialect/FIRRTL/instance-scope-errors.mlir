// RUN: circt-opt %s --split-input-file --verify-diagnostics

// A scope defined after the instance does not dominate it. Parsing the scope
// operand must not crash before the Debug dialect is loaded.
firrtl.circuit "Forward" {
  firrtl.module private @Leaf() {}
  firrtl.module @Forward() {
    // expected-error @below {{operand #0 does not dominate this use}}
    firrtl.instance l @Leaf() scope %s
    // expected-note @below {{operand defined here}}
    %s = dbg.scope "x", "X"
  }
}

// -----

firrtl.circuit "NotAScope" {
  firrtl.module private @Leaf() {}
  // expected-note @below {{prior use here}}
  firrtl.module @NotAScope(in %a: !firrtl.uint<1>) {
    // expected-error @below {{use of value '%a' expects different type than prior uses}}
    firrtl.instance l @Leaf() scope %a
  }
}
