// RUN: circt-opt %s --verify-diagnostics | circt-opt | FileCheck %s --check-prefix=META
  // META-DAG: dbg.module @{{[^ ]+}} type "Alu"
  // META-DAG: dbg.module @{{[^ ]+}} type "Alu" ext "{}"
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

  // CHECK-NEXT: [[TMP:%.+]] = dbg.scope "inlined"
  // CHECK-NEXT: dbg.variable {{.+}} scope [[TMP]]
  // CHECK-NEXT: dbg.scope {{.+}} scope [[TMP]]
  %2 = dbg.scope "inlined"
  dbg.variable "x", %arg0 scope %2 : i32
  dbg.scope "y" scope %2

  return
}

// CHECK-LABEL: func.func @KindFlipsModuleInfo
dbg.module @debug1 type "Alu"
dbg.module @debug2 type "Alu" ext "{}"
func.func @KindFlipsModuleInfo(%arg0: i32) {
  // CHECK-NEXT: dbg.variable "a", %arg0 kind input : i32
  dbg.variable "a", %arg0 kind input : i32

  // CHECK-NEXT: [[S:%.+]] = dbg.scope "inlined"
  // CHECK-NEXT: dbg.variable "h", %arg0 scope [[S]] kind reg : i32
  %s = dbg.scope "inlined" def @debug2
  dbg.variable "h", %arg0 scope %s kind reg : i32

  // CHECK-NEXT: [[T:%.+]] = dbg.struct {"x": %arg0, "y": %arg0} {flips = array<i1: false, true>} : i32, i32
  // CHECK-NEXT: dbg.variable "io", [[T]] kind output : !dbg.struct
  %t = dbg.struct {"x": %arg0, "y": %arg0} {flips = array<i1: false, true>} : i32, i32
  dbg.variable "io", %t kind output : !dbg.struct



  return
}
