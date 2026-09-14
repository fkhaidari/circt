// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// A module is keyed by its source name, like variables and instances. When the
// Verilog backend renamed it, `target.name` carries the emitted name, which is
// what a consumer holding the netlist matches on. The instance names the module
// by the same key.

hw.module @Child(in %p : i8) attributes {verilogName = "Child_1"} {
  dbg.variable "p", %p : i8
}

hw.module @Top(in %a : i8) {
  hw.instance "c" @Child(p: %a: i8) -> ()
  dbg.variable "a", %a : i8
}

// CHECK:      "modules": {
// CHECK-NEXT:   "Child": {
// CHECK:          "target": {
// CHECK-NEXT:       "name": "Child_1"

// A module the backend left alone has no `target.name`.
// CHECK:        "Top": {
// CHECK-NOT:      "name": "Top"
// CHECK:          "instances": {
// CHECK-NEXT:       "c": {
// CHECK-NEXT:         "moduleRef": "Child"

// The Verilog name is not a key of its own.
// CHECK-NOT:  "Child_1": {
