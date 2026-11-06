// RUN: circt-opt %s --verify-diagnostics --split-input-file

// -----
// dbg.struct with a flips array of the wrong length.

func.func @StructFlipsTooShort(%arg0: i32, %arg1: i32) {
  // expected-error @+1 {{number of flips (1) and fields (2) must match}}
  %s = dbg.struct {"a": %arg0, "b": %arg1} {flips = array<i1: false>} : i32, i32
  return
}

// -----
// dbg.struct with flips but no fields.

func.func @StructFlipsNoFields() {
  // expected-error @+1 {{number of flips (1) and fields (0) must match}}
  %s = dbg.struct {} {flips = array<i1: true>}
  return
}
