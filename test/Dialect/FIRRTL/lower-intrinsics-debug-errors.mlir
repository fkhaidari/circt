// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-lower-intrinsics{emit-debug-info=true}), firrtl.class(firrtl-lower-intrinsics{emit-debug-info=true})))' --verify-diagnostics --split-input-file %s

firrtl.circuit "NonDebugUser" {
  firrtl.module @NonDebugUser() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-error @below {{has a debug handle used by a non-debug op}}
    %h = firrtl.node %0 : !firrtl.uint<0>
    %x = firrtl.wire : !firrtl.uint<0>
    // expected-note @below {{used here}}
    firrtl.matchingconnect %x, %h : !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "UsedTwice" {
  firrtl.module @UsedTwice() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-note @below {{first used here}}
    firrtl.int.generic "circt_debug_var" <name: none = "a"> %0 : (!firrtl.uint<0>) -> ()
    // expected-error @below {{uses a debug handle that is already used}}
    firrtl.int.generic "circt_debug_var" <name: none = "b"> %0 : (!firrtl.uint<0>) -> ()
  }
}

// -----

firrtl.circuit "Aggregate" {
  firrtl.module @Aggregate() {
    %w = firrtl.wire : !firrtl.bundle<a: uint<1>>
    // expected-error @below {{operand must be a debug handle or a ground hardware value, got '!firrtl.bundle<a: uint<1>>'}}
    firrtl.int.generic "circt_debug_var" <name: none = "w"> %w : (!firrtl.bundle<a: uint<1>>) -> ()
  }
}

// -----

firrtl.circuit "FEnum" {
  firrtl.module @FEnum() {
    %w = firrtl.wire : !firrtl.enum<A: uint<0>, B: uint<0>>
    // expected-error @below {{FIRRTL enum operands are not supported}}
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "E"> %w : (!firrtl.enum<A: uint<0>, B: uint<0>>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "FEnumOnEnum" {
  firrtl.module @FEnumOnEnum() {
    %w = firrtl.wire : !firrtl.enum<A: uint<0>, B: uint<0>>
    // expected-error @below {{FIRRTL enum operands are not supported}}
    %0 = firrtl.int.generic "circt_debug_enum" <typeName: none = "E", variant_A: ui32 = 0> %w : (!firrtl.enum<A: uint<0>, B: uint<0>>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "EnumNotUInt" {
  firrtl.module @EnumNotUInt() {
    %w = firrtl.wire : !firrtl.sint<2>
    // expected-error @below {{operand must be a UInt, got '!firrtl.sint<2>'}}
    %0 = firrtl.int.generic "circt_debug_enum" <typeName: none = "E", variant_A: ui32 = 0> %w : (!firrtl.sint<2>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "EnumOfHandle" {
  firrtl.module @EnumOfHandle() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-error @below {{operand must be a hardware value, not a debug handle}}
    %1 = firrtl.int.generic "circt_debug_enum" <typeName: none = "E", variant_A: ui32 = 0> %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "ValueOfValue" {
  firrtl.module @ValueOfValue() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-error @below {{must not wrap another non-empty circt_debug_value}}
    %1 = firrtl.int.generic "circt_debug_value" <typeName: none = "Other"> %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "DifferentRoots" {
  firrtl.module @DifferentRoots() {
    // expected-note @below {{first root here}}
    %a = firrtl.wire : !firrtl.uint<1>
    // expected-note @below {{other root here}}
    %b = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "a"> %a : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_value" <name: none = "b"> %b : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %2 = firrtl.int.generic "circt_debug_struct" %0, %1 : (!firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
    // expected-error @below {{has leaves with different roots}}
    firrtl.int.generic "circt_debug_var" <name: none = "ab"> %2 : (!firrtl.uint<0>) -> ()
  }
}

// -----

firrtl.circuit "FlipMismatch" {
  firrtl.module @FlipMismatch(out %io: !firrtl.bundle<a flip: uint<1>>) {
    // expected-note @below {{leaf here}}
    %a = firrtl.subfield %io[a] : !firrtl.bundle<a flip: uint<1>>
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "a"> %a : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_struct" %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
    // expected-error @below {{has a 'flip' that does not match the FIRRTL type of a leaf}}
    firrtl.int.generic "circt_debug_var" <name: none = "io"> %1 : (!firrtl.uint<0>) -> ()
  }
}

// -----

firrtl.circuit "LabelOnArrayElement" {
  firrtl.module @LabelOnArrayElement() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{must not have 'name' or 'flip' on an array element}}
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "e", typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_array" %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "LabelOnRoot" {
  firrtl.module @LabelOnRoot() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{must not have 'name' or 'flip' on a variable root}}
    %0 = firrtl.int.generic "circt_debug_value" <flip: ui32 = 1, typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "w"> %0 : (!firrtl.uint<0>) -> ()
  }
}

// -----

firrtl.circuit "LabelOnWrapped" {
  firrtl.module @LabelOnWrapped() {
    // expected-error @below {{must not have 'name' or 'flip' on a wrapped handle}}
    %0 = firrtl.int.generic "circt_debug_struct" <name: none = "s"> : () -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_value" <typeName: none = "S"> %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "FieldWithoutName" {
  firrtl.module @FieldWithoutName() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{must have a 'name' as a struct field}}
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_struct" %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "StructOfLeaf" {
  firrtl.module @StructOfLeaf() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{operand must be a debug handle}}
    %0 = firrtl.int.generic "circt_debug_struct" %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "ArrayTypes" {
  firrtl.module @ArrayTypes() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_value" %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-error @below {{has elements of different types: '!dbg.value' and '!firrtl.uint<1>'}}
    %2 = firrtl.int.generic "circt_debug_array" %0, %1 : (!firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "NegativeTag" {
  firrtl.module @NegativeTag() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{has tag -1 : si32 for variant 'A' that is negative or does not fit in i64}}
    %0 = firrtl.int.generic "circt_debug_enum" <typeName: none = "E", variant_A: si32 = -1> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "WideTag" {
  firrtl.module @WideTag() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{for variant 'A' that is negative or does not fit in i64}}
    %0 = firrtl.int.generic "circt_debug_enum" <typeName: none = "E", variant_A: ui64 = 9223372036854775808> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "NoVariants" {
  firrtl.module @NoVariants() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{must have at least one 'variant_' parameter}}
    %0 = firrtl.int.generic "circt_debug_enum" <typeName: none = "E"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "NestedModuleInfo" {
  firrtl.module @NestedModuleInfo(in %c: !firrtl.uint<1>) {
    firrtl.when %c : !firrtl.uint<1> {
      // expected-error @below {{must be directly in the module body}}
      firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "M"> : () -> ()
    }
  }
}

// -----

firrtl.circuit "DuplicateModuleInfo" {
  firrtl.module @DuplicateModuleInfo() {
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "M"> : () -> ()
    // expected-error @below {{must appear at most once per module}}
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "M"> : () -> ()
  }
}

// -----

firrtl.circuit "AliasWithSymbol" {
  firrtl.module @AliasWithSymbol() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-error @below {{aliases a debug handle and must not carry annotations, a symbol or a probe}}
    %h = firrtl.node sym @h %0 : !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "AliasWithAnnotation" {
  firrtl.module @AliasWithAnnotation() {
    %w = firrtl.wire : !firrtl.uint<1>
    %0 = firrtl.int.generic "circt_debug_value" %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    // expected-error @below {{aliases a debug handle and must not carry annotations, a symbol or a probe}}
    %h = firrtl.node %0 {annotations = [{class = "circt.test"}]} : !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "OldProtocolIntrinsic" {
  firrtl.module @OldProtocolIntrinsic() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{'circt_debug_subfield' is not a known debug intrinsic; the FIRRTL may use an older Chisel debug protocol, update Chisel or compile without debug info}}
    firrtl.int.generic "circt_debug_subfield" <name: none = "io.a", parent: none = "io"> %w : (!firrtl.uint<1>) -> ()
  }
}

// -----

firrtl.circuit "OldProtocolParam" {
  firrtl.module @OldProtocolParam() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{has unknown parameter 'typeName'; the FIRRTL may use an older Chisel debug protocol}}
    firrtl.int.generic "circt_debug_var" <name: none = "w", typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> ()
  }
}

// -----

firrtl.circuit "ParamType" {
  firrtl.module @ParamType() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{parameter 'flip' must be an integer}}
    %0 = firrtl.int.generic "circt_debug_value" <flip: none = "yes"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
  }
}

// -----

// A memory variable has no operand; it is dropped with a warning.
firrtl.circuit "MemoryVar" {
  firrtl.module @MemoryVar() {
    // expected-warning @below {{debug info for memories is not supported yet, dropped}}
    firrtl.int.generic "circt_debug_var" <name: none = "mem", typeName: none = "SyncReadMem[UInt<8>]"> : () -> ()
  }
}

// -----

firrtl.circuit "UnusedHandle" {
  firrtl.module @UnusedHandle() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{has a debug handle that nothing uses}}
    %0 = firrtl.int.generic "circt_debug_value" <typeName: none = "Bool"> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
  }
}

// -----

firrtl.circuit "BadFlip" {
  firrtl.module @BadFlip() {
    %w = firrtl.wire : !firrtl.uint<1>
    // expected-error @below {{has 'flip' 2 : ui32 that is neither 0 nor 1}}
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "a", flip: ui32 = 2> %w : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_struct" %0 : (!firrtl.uint<0>) -> !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "w"> %1 : (!firrtl.uint<0>) -> ()
  }
}

// -----

// Class bodies hold no hardware; their debug intrinsics are dropped.
firrtl.circuit "ClassBody" {
  firrtl.module @ClassBody() {}
  firrtl.class @C(in %s: !firrtl.string) {
    // expected-warning @below {{debug intrinsics in a class body are dropped}}
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "C"> : () -> ()
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "C"> : () -> ()
  }
}
