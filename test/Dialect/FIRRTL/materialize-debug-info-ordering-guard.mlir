// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-materialize-debug-info,firrtl-lower-intrinsics)))' %s --verify-diagnostics

// Two `circt_debug_var` intrinsics with the same name must produce exactly
// ONE duplicate-name warning across the pipeline. MaterializeDebugInfo runs
// first but defers duplicate detection to the LowerIntrinsics converter, which
// owns the canonical warning; MaterializeDebugInfo must not emit a second one.
// `--verify-diagnostics` fails the test if a second (materialize-side) warning
// reappears, since it would be an unmatched diagnostic.
firrtl.circuit "DupWarn" {
  firrtl.module @DupWarn() {
    %w1 = firrtl.wire : !firrtl.uint<8>
    firrtl.int.generic "circt_debug_var"
      <name: none = "dup", typeName: none = "UInt">
      %w1 : (!firrtl.uint<8>) -> ()

    %w2 = firrtl.wire : !firrtl.uint<8>
    // expected-warning @below {{duplicate circt_debug_var with name 'dup'}}
    firrtl.int.generic "circt_debug_var"
      <name: none = "dup", typeName: none = "UInt">
      %w2 : (!firrtl.uint<8>) -> ()
  }
}
