// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-materialize-debug-info)))' %s --verify-diagnostics --split-input-file

firrtl.circuit "NoTarget" {
firrtl.module @NoTarget() {
  // expected-error @below {{circt_debug_type has no declaration named 'x'}}
  firrtl.int.generic "circt_debug_type" <target: none = "x", name: none = "Bool"> : () -> ()
}
}

// -----

firrtl.circuit "Index" {
firrtl.module @Index(in %v: !firrtl.vector<uint<1>, 2>) {
  // expected-error @below {{circt_debug_type path '[1]' must index a vector with '[*]'}}
  firrtl.int.generic "circt_debug_type" <target: none = "v", path: none = "[1]", name: none = "Bool"> : () -> ()
}
}

// -----

firrtl.circuit "Malformed" {
firrtl.module @Malformed(in %io: !firrtl.bundle<a: uint<1>>) {
  // expected-error @below {{circt_debug_type has a malformed path 'a'}}
  firrtl.int.generic "circt_debug_type" <target: none = "io", path: none = "a", name: none = "Bool"> : () -> ()
}
}

// -----

firrtl.circuit "EmptyField" {
firrtl.module @EmptyField(in %io: !firrtl.bundle<a: uint<1>>) {
  // expected-error @below {{circt_debug_type has a malformed path '..a'}}
  firrtl.int.generic "circt_debug_type" <target: none = "io", path: none = "..a", name: none = "Bool"> : () -> ()
}
}

// -----

firrtl.circuit "Mismatch" {
firrtl.module @Mismatch(in %io: !firrtl.bundle<a: uint<1>>) {
  // expected-error @below {{circt_debug_type path '[*]' does not match the type of 'io'}}
  firrtl.int.generic "circt_debug_type" <target: none = "io", path: none = "[*]", name: none = "Bool"> : () -> ()
}
}

// -----

firrtl.circuit "Twice" {
firrtl.module @Twice(in %io: !firrtl.bundle<a: uint<1>>) {
  firrtl.int.generic "circt_debug_type" <target: none = "io", path: none = ".a", name: none = "Bool"> : () -> ()
  // expected-error @below {{circt_debug_enum gives 'io.a' debug metadata twice}}
  firrtl.int.generic "circt_debug_enum" <target: none = "io", path: none = ".a", name: none = "S", variant_A: ui32 = 0> : () -> ()
}
}

// -----

firrtl.circuit "EnumNotUInt" {
firrtl.module @EnumNotUInt(in %s: !firrtl.sint<2>) {
  // expected-error @below {{circt_debug_enum must target an unsigned integer}}
  firrtl.int.generic "circt_debug_enum" <target: none = "s", name: none = "S", variant_A: ui32 = 0> : () -> ()
}
}

// -----

firrtl.circuit "NoVariants" {
firrtl.module @NoVariants(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_enum has no variants}}
  firrtl.int.generic "circt_debug_enum" <target: none = "a", name: none = "S"> : () -> ()
}
}

// -----

firrtl.circuit "VariantNotInt" {
firrtl.module @VariantNotInt(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_enum parameter 'variant_A' must name a variant and be an integer}}
  firrtl.int.generic "circt_debug_enum" <target: none = "a", name: none = "S", variant_A: none = "0"> : () -> ()
}
}

// -----

firrtl.circuit "WideVariant" {
firrtl.module @WideVariant(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_enum parameter 'variant_A' does not fit in 64 bits}}
  firrtl.int.generic "circt_debug_enum" <target: none = "a", name: none = "S", variant_A: ui65 = 18446744073709551616> : () -> ()
}
}

// -----

firrtl.circuit "EnumNoName" {
firrtl.module @EnumNoName(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_enum is missing parameter name}}
  firrtl.int.generic "circt_debug_enum" <target: none = "a", variant_A: ui32 = 0> : () -> ()
}
}

// -----

firrtl.circuit "Empty" {
firrtl.module @Empty(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_type needs a 'name' or an 'ext_<lang>' parameter}}
  firrtl.int.generic "circt_debug_type" <target: none = "a"> : () -> ()
}
}

// -----

firrtl.circuit "Unknown" {
firrtl.module @Unknown(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_type has unknown parameter 'variant_A'}}
  firrtl.int.generic "circt_debug_type" <target: none = "a", name: none = "S", variant_A: ui32 = 0> : () -> ()
}
}

// -----

firrtl.circuit "ExtNotJSON" {
firrtl.module @ExtNotJSON(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_type parameter 'ext_chisel' is not JSON}}
  firrtl.int.generic "circt_debug_type" <target: none = "a", ext_chisel: none = "{"> : () -> ()
}
}

// -----

firrtl.circuit "ExtBadLanguage" {
firrtl.module @ExtBadLanguage(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_type parameter 'ext_Chisel' must name a lowercase language}}
  firrtl.int.generic "circt_debug_type" <target: none = "a", ext_Chisel: none = "{}"> : () -> ()
}
}

// -----

firrtl.circuit "EnumNegative" {
firrtl.module @EnumNegative(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_enum parameter 'variant_A' must not be negative}}
  firrtl.int.generic "circt_debug_enum" <target: none = "a", name: none = "E", variant_A: si32 = -1> : () -> ()
}
}

// -----

firrtl.circuit "EnumTooWide" {
firrtl.module @EnumTooWide(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_enum variant 'Big' does not fit in the 2-bit target 'a'}}
  firrtl.int.generic "circt_debug_enum" <target: none = "a", name: none = "E", variant_Big: ui32 = 4> : () -> ()
}
}

// -----

firrtl.circuit "NoField" {
firrtl.module @NoField(in %io: !firrtl.bundle<a: uint<1>>) {
  // expected-error @below {{circt_debug_type path '.typo' names no field 'typo' of 'io'}}
  firrtl.int.generic "circt_debug_type" <target: none = "io", path: none = ".typo", name: none = "Bool"> : () -> ()
}
}

// -----

firrtl.circuit "Operand" {
firrtl.module @Operand(in %a: !firrtl.uint<2>) {
  // expected-error @below {{circt_debug_type has 1 inputs instead of 0}}
  firrtl.int.generic "circt_debug_type" <target: none = "a", name: none = "S"> %a : (!firrtl.uint<2>) -> ()
}
}

// -----

firrtl.circuit "InstancePath" {
firrtl.module private @Child() {}
firrtl.module @InstancePath() {
  // expected-error @below {{circt_debug_type cannot have a 'path' on instance 'c'}}
  firrtl.int.generic "circt_debug_type" <target: none = "c", path: none = ".a", name: none = "T"> : () -> ()
  firrtl.instance c @Child()
}
}

// -----

firrtl.circuit "InstanceEnum" {
firrtl.module private @Child() {}
firrtl.module @InstanceEnum() {
  // expected-error @below {{circt_debug_enum cannot target instance 'c'}}
  firrtl.int.generic "circt_debug_enum" <target: none = "c", name: none = "E", variant_A: ui32 = 0> : () -> ()
  firrtl.instance c @Child()
}
}

// -----

firrtl.circuit "InstanceTwice" {
firrtl.module private @Child() {}
firrtl.module @InstanceTwice() {
  firrtl.int.generic "circt_debug_type" <target: none = "c", name: none = "A"> : () -> ()
  // expected-error @below {{circt_debug_type gives 'c' debug metadata twice}}
  firrtl.int.generic "circt_debug_type" <target: none = "c", name: none = "B"> : () -> ()
  firrtl.instance c @Child()
}
}

// -----

firrtl.circuit "ModuleTwice" {
firrtl.module @ModuleTwice() {
  firrtl.int.generic "circt_debug_type" <name: none = "A"> : () -> ()
  // expected-error @below {{circt_debug_type gives the module debug metadata twice}}
  firrtl.int.generic "circt_debug_type" <name: none = "B"> : () -> ()
}
}

// -----

firrtl.circuit "ModulePrivate" {
firrtl.module private @Child() {
  // expected-error @below {{circt_debug_type needs a 'target' outside of a public module}}
  firrtl.int.generic "circt_debug_type" <name: none = "T"> : () -> ()
}
firrtl.module @ModulePrivate() {
  firrtl.instance c @Child()
}
}

// -----

firrtl.circuit "InstanceChoice" {
firrtl.option @Platform {
  firrtl.option_case @FPGA
}
firrtl.module private @Default() {}
firrtl.module private @Fpga() {}
firrtl.module @InstanceChoice() {
  // expected-error @below {{circt_debug_type on instance_choice 'ic' is not supported yet}}
  firrtl.int.generic "circt_debug_type" <target: none = "ic", name: none = "T"> : () -> ()
  firrtl.instance_choice ic @Default alternatives @Platform { @FPGA -> @Fpga } ()
}
}

// -----

firrtl.circuit "Ambiguous" {
firrtl.module private @Child() {}
firrtl.module @Ambiguous() {
  // expected-error @below {{circt_debug_type target 'x' names more than one declaration}}
  firrtl.int.generic "circt_debug_type" <target: none = "x", name: none = "T"> : () -> ()
  %x = firrtl.wire : !firrtl.uint<1>
  firrtl.instance x @Child()
}
}
