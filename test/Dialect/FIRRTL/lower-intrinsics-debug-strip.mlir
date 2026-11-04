// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-lower-intrinsics), firrtl.class(firrtl-lower-intrinsics)))' --verify-diagnostics %s | FileCheck %s --implicit-check-not=firrtl.int.generic --implicit-check-not=dbg. --implicit-check-not=firrtl.node

// Without emit-debug-info, every circt_debug_* intrinsic and its alias nodes
// are erased, old protocol and class bodies included, with no diagnostics.
// CHECK-LABEL: firrtl.circuit "Strip"
firrtl.circuit "Strip" {
  // CHECK: firrtl.module @Strip
  firrtl.module @Strip(out %io: !firrtl.bundle<a flip: uint<1>>) {
    // CHECK-NEXT: %w = firrtl.wire
    // CHECK-NEXT: %0 = firrtl.subfield %io[a]
    // CHECK-NEXT: }
    %w = firrtl.wire : !firrtl.uint<1>
    %a = firrtl.subfield %io[a] : !firrtl.bundle<a flip: uint<1>>
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "Strip"> : () -> ()
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "a", typeName: none = "Bool"> %a : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %a_h = firrtl.node %0 : !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_struct" %a_h : (!firrtl.uint<0>) -> !firrtl.uint<0>
    %io_s = firrtl.node %1 : !firrtl.uint<0>
    %io_s2 = firrtl.node %io_s : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "io"> %io_s2 : (!firrtl.uint<0>) -> ()
    // Memory variable.
    firrtl.int.generic "circt_debug_var" <name: none = "mem", typeName: none = "Mem"> : () -> ()
    // Old protocol.
    firrtl.int.generic "circt_debug_enumdef" <typeName: none = "E", variants: none = "{}", width: ui32 = 1> : () -> ()
    firrtl.int.generic "circt_debug_var" <name: none = "w", typeName: none = "Bool", enumTypeName: none = "E"> %w : (!firrtl.uint<1>) -> ()
    firrtl.int.generic "circt_debug_subfield" <name: none = "io.a", parent: none = "io"> %a : (!firrtl.uint<1>) -> ()
  }
  // CHECK: firrtl.class @C
  // CHECK-NEXT: }
  firrtl.class @C(in %s: !firrtl.string) {
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "C"> : () -> ()
  }
}
