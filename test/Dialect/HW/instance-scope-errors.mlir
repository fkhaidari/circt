// RUN: circt-opt %s --split-input-file --verify-diagnostics

hw.module @Leaf(in %a: i1) {}

// expected-note @below {{prior use here}}
hw.module @NotAScope(in %a: i1) {
  // expected-error @below {{use of value '%a' expects different type than prior uses}}
  %s = dbg.scope "x" scope %a
}
