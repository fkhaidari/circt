// RUN: circt-opt --verify-roundtrip %s | FileCheck %s

module {
  func.func @Test() {
    %0 = arith.constant 0 : i2

    // CHECK: %{{.+}} = dbg.enum %{{.*}}, "MyState", {A = 0 : i64, B = 1 : i64} : i2
    %e = dbg.enum %0, "MyState", {A = 0 : i64, B = 1 : i64} : i2
    dbg.variable "v", %e : !dbg.enum

    // CHECK: %{{.+}} = dbg.enum %{{.*}}, "SmallTag", {X = 0 : i2} : i2
    %f = dbg.enum %0, "SmallTag", {X = 0 : i2} : i2
    dbg.variable "w", %f : !dbg.enum

    return
  }
}
