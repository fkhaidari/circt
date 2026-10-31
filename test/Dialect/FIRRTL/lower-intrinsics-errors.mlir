// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-lower-intrinsics)))' -verify-diagnostics --split-input-file %s

firrtl.circuit "UnknownIntrinsic" {
  firrtl.module @UnknownIntrinsic(in %data: !firrtl.uint<32>) {
    %0 = firrtl.wire : !firrtl.uint<32>
    // expected-error @below {{unknown intrinsic}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "unknown_intrinsic" %0 : (!firrtl.uint<32>) -> ()
    firrtl.matchingconnect %0, %data : !firrtl.uint<32>
  }
}

// -----

firrtl.circuit "InvalidCGOperand" {
    firrtl.module @InvalidCGOperand(in %clk: !firrtl.clock, in %en: !firrtl.uint<2>) {
      // expected-error @below {{circt.clock_gate input 1 not size 1}}
      // expected-error @below {{failed to legalize}}
      %0 = firrtl.int.generic "circt.clock_gate" %clk, %en : (!firrtl.clock, !firrtl.uint<2>) -> !firrtl.clock
    }
}

// -----

firrtl.circuit "MissingParam" {
    firrtl.module @MissingParam(in %clk: !firrtl.clock, in %en: !firrtl.uint<2>) {
      // expected-error @below {{circt_plusargs_test is missing parameter FORMAT}}
      // expected-error @below {{failed to legalize}}
      %0 = firrtl.int.generic "circt_plusargs_test" : () -> !firrtl.uint<1>
    }
}

// -----

firrtl.circuit "InvalidLTLClockEdge" {
  firrtl.module @InvalidLTLClockEdge(in %in: !firrtl.uint<1>, in %clk: !firrtl.clock) {
    // expected-error @below {{circt_ltl_clock has invalid edge parameter 'falling', expected one of [posedge, negedge, edge]}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_ltl_clock" <edge: none = "falling"> %in, %clk : (!firrtl.uint<1>, !firrtl.clock) -> !firrtl.uint<1>
  }
}

// -----

firrtl.circuit "ViewNotBundle" {
  firrtl.module public @ViewNotBundle() {
    // expected-error @below {{'info' must be augmented bundle}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedGroundType\"}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewNotJSON" {
  firrtl.module public @ViewNotJSON() {
    // expected-error @below {{error parsing view JSON}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "boop"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewNoDefname" {
  firrtl.module public @ViewNoDefname() {
    // expected-error @below {{View 'info' did not contain required key 'defName'}}
    // expected-note @below {{The full 'info' attribute is reproduced here: {class = "sifive.enterprise.grandcentral.AugmentedBundleType"}}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\"}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewDefnameNotString" {
  firrtl.module public @ViewDefnameNotString() {
    // expected-error @below {{View 'info' did not contain the correct type for key 'defName'}}
    // expected-note @below {{The full 'info' attribute is reproduced here:}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\", \"defName\": 5}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewNoElementsField" {
  firrtl.module public @ViewNoElementsField() {
    // expected-error @below {{View 'info' did not contain required key 'elements'}}
    // expected-note @below {{The full 'info' attribute is reproduced here:}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\", \"defName\": \"MyView\"}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewInvalidElement" {
  firrtl.module public @ViewInvalidElement() {
    // expected-error @below {{View 'info' attribute with path '.elements[0]' contained an unexpected type (expected a DictionaryAttr)}}
    // expected-note @below {{The received element was: 5 : i64}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\", \"defName\": \"MyView\", \"elements\": [5]}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewElementEmptyDict" {
  firrtl.module public @ViewElementEmptyDict() {
    // expected-error @below {{View 'info' with path '.elements[0]' did not contain required key 'name'}}
    // expected-note @below {{The full 'info' attribute is reproduced here:}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\", \"defName\": \"MyView\", \"elements\": [{}]}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewElementGroundNoType" {
  firrtl.module public @ViewElementGroundNoType() {
    // expected-error @below {{View 'info' with path '.elements[0]' did not contain required key 'tpe'}}
    // expected-note @below {{The full 'info' attribute is reproduced here:}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\", \"defName\": \"MyView\", \"elements\": [{\"name\": \"foo\"}]}"> : () -> ()
  }
}

// -----

firrtl.circuit "ViewOperandNotGround" {
  firrtl.module public @ViewOperandNotGround(in %vec : !firrtl.vector<uint<1>, 2>) {
    // expected-error @below {{circt_view input 0 must be ground type}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = ""> %vec : (!firrtl.vector<uint<1>, 2>) -> ()
  }
}

// -----

firrtl.circuit "ViewWrongOperandCount" {
  firrtl.module public @ViewWrongOperandCount() {
    // expected-error @below {{circt_view has 0 operands but view 'info' has 1 leaf elements}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_view" <name: none = "view", info: none = "{\"class\":\"sifive.enterprise.grandcentral.AugmentedBundleType\", \"defName\": \"MyView\", \"elements\": [{\"name\": \"foo\", \"tpe\":{\"class\":\"sifive.enterprise.grandcentral.AugmentedGroundType\"}}]}"> : () -> ()
  }
}

// -----

// Without a target the record is for the module, which must be public.
firrtl.circuit "DebugTypeNoTargetPrivate" {
  firrtl.module private @Child() {
    // expected-error @below {{circt_debug_type needs a 'target' outside of a public module}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_type" <name: none = "T"> : () -> ()
  }
  firrtl.module @DebugTypeNoTargetPrivate() {
    firrtl.instance c @Child()
  }
}

// -----

firrtl.circuit "DebugTypeNoTargetPath" {
  firrtl.module @DebugTypeNoTargetPath() {
    // expected-error @below {{circt_debug_type without a 'target' cannot have a 'path'}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_type" <path: none = ".a", name: none = "T"> : () -> ()
  }
}

// -----

firrtl.circuit "DebugEnumNoTarget" {
  firrtl.module @DebugEnumNoTarget() {
    // expected-error @below {{circt_debug_enum is missing parameter target}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_enum" <name: none = "E", variant_A: ui32 = 0> : () -> ()
  }
}

// -----

firrtl.circuit "DebugTypeUnknownParam" {
  firrtl.module @DebugTypeUnknownParam() {
    // expected-error @below {{circt_debug_type has unknown parameter 'variant_A'}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_type" <target: none = "x", name: none = "T", variant_A: ui32 = 0> : () -> ()
  }
}

// -----

firrtl.circuit "DebugTypeNoName" {
  firrtl.module @DebugTypeNoName() {
    // expected-error @below {{circt_debug_type needs a 'name' or an 'ext_<lang>' parameter}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_type" <target: none = "x"> : () -> ()
  }
}

// -----

firrtl.circuit "DebugEnumNoVariants" {
  firrtl.module @DebugEnumNoVariants() {
    // expected-error @below {{circt_debug_enum has no variants}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_enum" <target: none = "x", name: none = "E"> : () -> ()
  }
}

// -----

firrtl.circuit "DebugEnumBadVariant" {
  firrtl.module @DebugEnumBadVariant() {
    // expected-error @below {{circt_debug_enum parameter 'variant_A' must name a variant and be an integer}}
    // expected-error @below {{failed to legalize}}
    firrtl.int.generic "circt_debug_enum" <target: none = "x", name: none = "E", variant_A: none = "a"> : () -> ()
  }
}
