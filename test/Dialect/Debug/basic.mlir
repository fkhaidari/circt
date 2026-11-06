// RUN: circt-opt %s --verify-diagnostics | circt-opt | FileCheck %s

// CHECK-LABEL: func.func @Foo
func.func @Foo(%arg0: i32, %arg1: index, %arg2: f64) {
  // CHECK-NEXT: dbg.variable "foo", %arg0 : i32
  // CHECK-NEXT: dbg.variable "bar", %arg1 : index
  // CHECK-NEXT: dbg.variable "baz", %arg2 : f64
  dbg.variable "foo", %arg0 : i32
  dbg.variable "bar", %arg1 : index
  dbg.variable "baz", %arg2 : f64

  // CHECK-NEXT: [[TMP:%.+]] = dbg.struct {"foo": %arg0, "bar": %arg1, "baz": %arg2} : i32, index, f64
  // CHECK-NEXT: dbg.variable "megafoo", [[TMP]] : !dbg.struct
  %0 = dbg.struct {"foo": %arg0, "bar": %arg1, "baz": %arg2} : i32, index, f64
  dbg.variable "megafoo", %0 : !dbg.struct

  // CHECK-NEXT: [[TMP:%.+]] = dbg.array [%arg1, %arg1] : index
  // CHECK-NEXT: dbg.variable "megabar", [[TMP]] : !dbg.array
  %1 = dbg.array [%arg1, %arg1] : index
  dbg.variable "megabar", %1 : !dbg.array

  // CHECK-NEXT: [[TMP:%.+]] = dbg.scope "inlined", "Bar"
  // CHECK-NEXT: dbg.variable {{.+}} scope [[TMP]]
  // CHECK-NEXT: dbg.scope {{.+}} scope [[TMP]]
  %2 = dbg.scope "inlined", "Bar"
  dbg.variable "x", %arg0 scope %2 : i32
  dbg.scope "y", "Baz" scope %2

  return
}


// CHECK-LABEL: func.func @KindFlipsModuleInfo
func.func @KindFlipsModuleInfo(%arg0: i32) {
  // CHECK-NEXT: dbg.variable "a", %arg0 kind input : i32
  // CHECK-NEXT: dbg.variable "b", %arg0 kind output : i32
  // CHECK-NEXT: dbg.variable "c", %arg0 kind inout : i32
  // CHECK-NEXT: dbg.variable "d", %arg0 kind wire : i32
  // CHECK-NEXT: dbg.variable "e", %arg0 kind reg : i32
  // CHECK-NEXT: dbg.variable "f", %arg0 kind node : i32
  dbg.variable "a", %arg0 kind input : i32
  dbg.variable "b", %arg0 kind output : i32
  dbg.variable "c", %arg0 kind inout : i32
  dbg.variable "d", %arg0 kind wire : i32
  dbg.variable "e", %arg0 kind reg : i32
  dbg.variable "f", %arg0 kind node : i32

  // CHECK-NEXT: [[S:%.+]] = dbg.scope "inlined", "Bar"
  // CHECK-NEXT: dbg.variable "h", %arg0 scope [[S]] kind reg : i32
  %s = dbg.scope "inlined", "Bar"
  dbg.variable "h", %arg0 scope %s kind reg : i32

  // CHECK-NEXT: [[T:%.+]] = dbg.struct {"x": %arg0, "y": %arg0} {flips = array<i1: false, true>} : i32, i32
  // CHECK-NEXT: dbg.variable "io", [[T]] kind output : !dbg.struct
  %t = dbg.struct {"x": %arg0, "y": %arg0} {flips = array<i1: false, true>} : i32, i32
  dbg.variable "io", %t kind output : !dbg.struct

  // CHECK-NEXT: [[V:%.+]] = dbg.value %arg0 typeName "UInt" params ["{\22x-chisel\22:{\22params\22:{\22width\22:8}}}"] : i32
  // CHECK-NEXT: dbg.variable "v", [[V]] : !dbg.value
  %v = dbg.value %arg0 typeName "UInt" params ["{\"x-chisel\":{\"params\":{\"width\":8}}}"] : i32
  dbg.variable "v", %v : !dbg.value

  // CHECK-NEXT: dbg.moduleinfo "Alu"
  // CHECK-NEXT: dbg.moduleinfo "Alu" params ["{\22x-chisel\22:{\22params\22:{\22width\22:8}}}"]
  // CHECK-NEXT: dbg.moduleinfo "Alu" scope [[S]]
  // CHECK-NEXT: dbg.moduleinfo "Alu" params ["{}"] scope [[S]]
  dbg.moduleinfo "Alu"
  dbg.moduleinfo "Alu" params ["{\"x-chisel\":{\"params\":{\"width\":8}}}"]
  dbg.moduleinfo "Alu" scope %s
  dbg.moduleinfo "Alu" params ["{}"] scope %s
  return
}
