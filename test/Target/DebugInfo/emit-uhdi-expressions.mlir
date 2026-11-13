// RUN: circt-translate %s --emit-uhdi --uhdi-indent=0 | FileCheck %s

hw.module @Expressions(in %hi: i4, in %lo: i4) {
  %zero = hw.constant 0 : i2
  %shifted = comb.concat %hi, %zero : i4, i2
  %packed = comb.concat %hi, %lo : i4, i4
  %filled = comb.replicate %lo : (i4) -> i8
  %part = comb.extract %packed from 2 : (i8) -> i4
  %empty = comb.icmp eq %hi, %lo : i4
  %negative = comb.icmp slt %hi, %lo : i4
  %select = comb.mux %empty, %hi, %lo : i4
  %sum = comb.add %hi, %lo : i4
  %shift = comb.shrs %hi, %lo : i4
  dbg.variable "shifted", %shifted : i6
  dbg.variable "packed", %packed : i8
  dbg.variable "filled", %filled : i8
  dbg.variable "part", %part : i4
  dbg.variable "empty", %empty : i1
  dbg.variable "negative", %negative : i1
  dbg.variable "select", %select : i4
  dbg.variable "sum", %sum : i4
  dbg.variable "shift", %shift : i4
  hw.output
}

// CHECK: "profiles":["expr"]
// CHECK-SAME: "shifted":{"$op":"{}","args":["hi",{"$const":"0b00"}]}
// CHECK-SAME: "packed":{"$op":"{}","args":["hi","lo"]}
// CHECK-SAME: "filled":{"$op":"R{}","args":[2,"lo"]}
// CHECK-SAME: "part":{"$op":"[]","args":[{"$op":"{}","args":["hi","lo"]},5,2]}
// CHECK-SAME: "empty":{"$op":"==","args":["hi","lo"]}
// CHECK-SAME: "negative":{"$op":"<","args":[{"$op":"$signed","args":["hi"]},{"$op":"$signed","args":["lo"]}]}
// CHECK-SAME: "select":{"$op":"?:","args":[{"$op":"==","args":["hi","lo"]},"hi","lo"]}
// CHECK-SAME: "sum":{"$op":"+","args":["hi","lo"]}
// CHECK-SAME: "shift":{"$op":">>>","args":[{"$op":"$signed","args":["hi"]},"lo"]}
