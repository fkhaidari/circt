// RUN: circt-opt %s --verify-diagnostics --split-input-file

func.func @missingSource() {
  // expected-error @+1 {{requires exactly one of value or path}}
  %v = dbg.value type "Leaf"
  return
}

// -----

func.func @twoSources(%arg: i8) {
  // expected-error @+1 {{requires exactly one of value or path}}
  %v = dbg.value %arg path @path type "Leaf" : i8
  return
}

// -----

firrtl.circuit "Top" {
  firrtl.module @Top() {
    // expected-error @+1 {{path must reference hw.hierpath}}
    %v = dbg.value path @missing
  }
}

// -----

firrtl.circuit "Top" {
  hw.hierpath private @path [@Top]
  firrtl.module @Top() {
    // expected-error @+1 {{path must target an operation with an inner symbol}}
    %v = dbg.value path @path
  }
}
