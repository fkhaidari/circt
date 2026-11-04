// RUN: circt-opt --canonicalize %s | FileCheck %s
// RUN: circt-opt --cse %s | FileCheck %s --check-prefix=CSE

// dbg.value is Pure: an unused wrapper is erased, a wrapper used by a
// dbg.variable or dbg.struct survives.
// CHECK-LABEL: func.func @PureValue
func.func @PureValue(%arg0: i32, %arg1: i32, %arg2: i32) {
  // CHECK-NOT: typeName "Unused"
  dbg.value %arg0 typeName "Unused" : i32
  // CHECK: [[V:%.+]] = dbg.value %arg1 typeName "Var" : i32
  // CHECK-NEXT: dbg.variable "v", [[V]] : !dbg.value
  %v = dbg.value %arg1 typeName "Var" : i32
  dbg.variable "v", %v : !dbg.value
  // CHECK: [[W:%.+]] = dbg.value %arg2 typeName "Field" : i32
  // CHECK-NEXT: [[S:%.+]] = dbg.struct {"f": [[W]]} : !dbg.value
  // CHECK-NEXT: dbg.variable "s", [[S]] : !dbg.struct
  %w = dbg.value %arg2 typeName "Field" : i32
  %s = dbg.struct {"f": %w} : !dbg.value
  dbg.variable "s", %s : !dbg.struct
  return
}

// Identical wrappers are merged.
// CSE-LABEL: func.func @CSEValue
func.func @CSEValue(%arg0: i32) {
  // CSE-NEXT: [[V:%.+]] = dbg.value %arg0 typeName "T" : i32
  // CSE-NEXT: dbg.variable "a", [[V]] : !dbg.value
  // CSE-NEXT: dbg.variable "b", [[V]] : !dbg.value
  // CSE-NEXT: return
  %0 = dbg.value %arg0 typeName "T" : i32
  %1 = dbg.value %arg0 typeName "T" : i32
  dbg.variable "a", %0 : !dbg.value
  dbg.variable "b", %1 : !dbg.value
  return
}
