// RUN: circt-translate %s --emit-uhdi --split-input-file --verify-diagnostics

dbg.module @A type "A" impl @Dup
// expected-error @below {{more than one dbg.module for this module}}
dbg.module @B type "B" impl @Dup
hw.module @Dup() {}

// -----

hw.module @BadDefinition() {
  // expected-error @below {{def must reference a dbg.module}}
  %s = dbg.scope "inl" def @Missing
}

// -----

hw.module @Nested() {
  // expected-error @below {{symbol's parent must have the SymbolTable trait}}
  dbg.module @NestedDebug type "Nested"
}

// -----
dbg.module @debug1 type "NoType" impl @NoType

hw.module @NoType(in %s: !hw.string) {
  // expected-warning @below {{UHDI leaves out this variable: its type cannot be described}}
  dbg.variable "str", %s : !hw.string
}

// -----

// expected-warning @below {{UHDI leaves out port 's': its type cannot be described}}
hw.module.extern @NoTypePort(in %s: !hw.string)

// -----
dbg.module @debug1 type "Generated" impl @Generated

hw.generator.schema @Schema, "Schema", ["n"]
hw.module.generated @Gen, @Schema() attributes {n = 1 : i32}
hw.module @Generated() {
  // expected-warning @below {{UHDI leaves out this instance: its module is not an hw.module or hw.module.extern}}
  hw.instance "g" @Gen() -> ()
}

// -----
dbg.module @debug1 type "Deep" impl @Deep

// Each shared value is walked once. Walking every use would visit 2^32 values
// here.
hw.module @Deep(in %s: !hw.string) {
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
// expected-error @below {{ext is not valid JSON}}
dbg.module @debug1 type "A" ext "{" impl @ParamsNotJson

hw.module @ParamsNotJson() {
}

// -----
// expected-error @below {{ext must be a JSON object}}
dbg.module @debug1 type "A" ext "[1]" impl @ParamsNotObject

hw.module @ParamsNotObject() {
}

// -----
// expected-error @below {{ext key 'chisel' does not start with 'x-'}}
dbg.module @debug1 type "A" ext "{\"chisel\":{}}" impl @ParamsBadKey

hw.module @ParamsBadKey() {
}

// -----
dbg.module @debug1 type "A" impl @ValueParamsBadKey

hw.module @ValueParamsBadKey(in %a: i8) {
  // expected-error @below {{ext key 'w' does not start with 'x-'}}
  %v = dbg.value %a type "T" ext "{\"w\":8}" : i8
}

// -----

hw.hierpath private @wire [@UnsupportedQuery::@wire]
hw.module @UnsupportedQuery(in %i: i8) {
  %wire = hw.wire %i sym @wire : i8
  %query = dbg.value path @wire
  // expected-error @below {{invalid instance description path}}
  dbg.variable "wire", %query : !dbg.value
}

// -----

hw.hierpath private @cycle [@ScopeCycle::@scope]
hw.module @ScopeCycle() {
  // expected-error @below {{cyclic debug scope description}}
  %scope = dbg.scope "scope" sym #hw<innerSym@scope>
  %value = dbg.value path @cycle
  dbg.variable "self", %value scope %scope : !dbg.value
}
