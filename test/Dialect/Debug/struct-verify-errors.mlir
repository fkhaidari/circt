// RUN: circt-opt %s --verify-diagnostics --split-input-file

// -----
// dbg.struct with a flips array of the wrong length.

func.func @StructFlipsTooShort(%arg0: i32, %arg1: i32) {
  // expected-error @+1 {{failed to verify that number of fields and flips match}}
  %s = dbg.struct {"a": %arg0, "b": %arg1} {flips = array<i1: false>} : i32, i32
  return
}

// -----
// dbg.struct with flips but no fields.

func.func @StructFlipsNoFields() {
  // expected-error @+1 {{failed to verify that number of fields and flips match}}
  %s = dbg.struct {} {flips = array<i1: true>}
  return
}
