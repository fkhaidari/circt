// RUN: circt-translate %s --emit-uhdi --split-input-file --verify-diagnostics

hw.module @Dup() {
  // expected-note @below {{previous one is here}}
  dbg.moduleinfo "A"
  // expected-error @below {{more than one dbg.moduleinfo for this module}}
  dbg.moduleinfo "B"
}

// -----

hw.module @DupScope() {
  %s = dbg.scope "inl", "C"
  // expected-note @below {{previous one is here}}
  dbg.moduleinfo "C" scope %s
  // expected-error @below {{more than one dbg.moduleinfo for this scope}}
  dbg.moduleinfo "C" scope %s
}

// -----

hw.module @DupNested() {
  // expected-note @below {{previous one is here}}
  dbg.moduleinfo "A"
  sv.ifdef @M {
    // expected-error @below {{more than one dbg.moduleinfo for this module}}
    dbg.moduleinfo "B"
  }
}
sv.macro.decl @M

// -----

hw.module @NoType(in %s: !hw.string) {
  dbg.moduleinfo "NoType"
  // expected-warning @below {{UHDI leaves out this variable: its type cannot be described}}
  dbg.variable "str", %s : !hw.string
}

// -----

// expected-warning @below {{UHDI leaves out port 's': its type cannot be described}}
hw.module.extern @NoTypePort(in %s: !hw.string)

// -----

hw.generator.schema @Schema, "Schema", ["n"]
hw.module.generated @Gen, @Schema() attributes {n = 1 : i32}
hw.module @Generated() {
  dbg.moduleinfo "Generated"
  // expected-warning @below {{UHDI leaves out this instance: its module is not an hw.module or hw.module.extern}}
  hw.instance "g" @Gen() -> ()
}

// -----

// Each shared value is walked once. Walking every use would visit 2^32 values
// here.
hw.module @Deep(in %s: !hw.string) {
  dbg.moduleinfo "Deep"
  %a1 = dbg.array [%s, %s] : !hw.string
  %a2 = dbg.array [%a1, %a1] : !dbg.array
  %a3 = dbg.array [%a2, %a2] : !dbg.array
  %a4 = dbg.array [%a3, %a3] : !dbg.array
  %a5 = dbg.array [%a4, %a4] : !dbg.array
  %a6 = dbg.array [%a5, %a5] : !dbg.array
  %a7 = dbg.array [%a6, %a6] : !dbg.array
  %a8 = dbg.array [%a7, %a7] : !dbg.array
  %a9 = dbg.array [%a8, %a8] : !dbg.array
  %a10 = dbg.array [%a9, %a9] : !dbg.array
  %a11 = dbg.array [%a10, %a10] : !dbg.array
  %a12 = dbg.array [%a11, %a11] : !dbg.array
  %a13 = dbg.array [%a12, %a12] : !dbg.array
  %a14 = dbg.array [%a13, %a13] : !dbg.array
  %a15 = dbg.array [%a14, %a14] : !dbg.array
  %a16 = dbg.array [%a15, %a15] : !dbg.array
  %a17 = dbg.array [%a16, %a16] : !dbg.array
  %a18 = dbg.array [%a17, %a17] : !dbg.array
  %a19 = dbg.array [%a18, %a18] : !dbg.array
  %a20 = dbg.array [%a19, %a19] : !dbg.array
  %a21 = dbg.array [%a20, %a20] : !dbg.array
  %a22 = dbg.array [%a21, %a21] : !dbg.array
  %a23 = dbg.array [%a22, %a22] : !dbg.array
  %a24 = dbg.array [%a23, %a23] : !dbg.array
  %a25 = dbg.array [%a24, %a24] : !dbg.array
  %a26 = dbg.array [%a25, %a25] : !dbg.array
  %a27 = dbg.array [%a26, %a26] : !dbg.array
  %a28 = dbg.array [%a27, %a27] : !dbg.array
  %a29 = dbg.array [%a28, %a28] : !dbg.array
  %a30 = dbg.array [%a29, %a29] : !dbg.array
  %a31 = dbg.array [%a30, %a30] : !dbg.array
  %a32 = dbg.array [%a31, %a31] : !dbg.array
  // expected-warning @below {{UHDI leaves out this variable: its type cannot be described}}
  dbg.variable "deep", %a32 : !dbg.array
}

// -----

hw.module @ParamsNotJson() {
  // expected-error @below {{params is not valid JSON}}
  dbg.moduleinfo "A" params ["{"]
}

// -----

hw.module @ParamsNotObject() {
  // expected-error @below {{params must be a JSON object}}
  dbg.moduleinfo "A" params ["[1]"]
}

// -----

hw.module @ParamsBadKey() {
  // expected-error @below {{params key 'chisel' does not start with 'x-'}}
  dbg.moduleinfo "A" params ["{\"chisel\":{}}"]
}

// -----

hw.module @ValueParamsBadKey(in %a: i8) {
  dbg.moduleinfo "A"
  // expected-error @below {{params key 'w' does not start with 'x-'}}
  %v = dbg.value %a typeName "T" params ["{\"w\":8}"] : i8
}
