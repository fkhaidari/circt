// RUN: circt-opt %s --verify-diagnostics --split-input-file

// The module name is not empty.

func.func @EmptyModuleName() {
  // expected-error @+1 {{has an empty module name}}
  dbg.instance "a", ""
  return
}

// -----

// An ext key is a lowercase language name.

func.func @ExtBadLanguage() {
  // expected-error @+1 {{ext key 'Chisel' is not a lowercase language name}}
  dbg.instance "a", "Alu" ext {Chisel = "{}"}
  return
}

// -----

func.func @ExtNotString() {
  // expected-error @+1 {{ext value of 'chisel' must be a string}}
  dbg.instance "a", "Alu" ext {chisel = 1 : i32}
  return
}

// -----

func.func @ExtDigitFirstKey() {
  // expected-error @+1 {{ext key '1x' is not a lowercase language name}}
  dbg.instance "a", "Alu" ext {"1x" = "{}"}
  return
}

// -----

// A scope of an inlined instance checks its ext the same way.

func.func @ScopeExtNotString() {
  // expected-error @+1 {{ext value of 'chisel' must be a string}}
  %0 = dbg.scope "a", "Alu" ext {chisel = 1 : i32}
  return
}
