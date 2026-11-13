// RUN: circt-opt %s --verify-diagnostics --split-input-file
func.func @invalidPlacement() {
  // expected-error @+1 {{symbol's parent must have the SymbolTable trait}}
  dbg.module @ChildDebug type "Child"
  return
}
// -----
firrtl.circuit "Top" {
  // expected-error @+1 {{impl must reference a module operation}}
  dbg.module @MissingDebug type "Missing" impl @Missing
  firrtl.module @Top() {}
}
// -----
dbg.module @LeafDebug type "Leaf"
hw.module @Top(in %x: i8) {
  // expected-error @+1 {{def and type are mutually exclusive}}
  %v = dbg.value %x def @LeafDebug type "Leaf" : i8
}
