// RUN: circt-opt %s | circt-opt | FileCheck %s

// CHECK-LABEL: func.func @StmtTree
func.func @StmtTree(%arg0: i1, %arg1: i32) {
  // dbg.expression with operands
  // CHECK: [[EX0:%.+]] = dbg.expression "cond_and", opcode "&&", operands(%arg0, %arg0 : i1, i1)
  %0 = dbg.expression "cond_and", opcode "&&", operands(%arg0, %arg0 : i1, i1)

  // dbg.expression with no operands
  // CHECK: [[EX1:%.+]] = dbg.expression "reset_n", opcode "!"
  %1 = dbg.expression "reset_n", opcode "!"

  // dbg.rootblock with an explicit scope
  // CHECK: [[SC:%.+]] = dbg.scope "m", "M"
  %2 = dbg.scope "m", "M"
  // CHECK: dbg.rootblock scope [[SC]] {
  dbg.rootblock scope %2 {
    // dbg.decl_stmt
    // CHECK: dbg.decl_stmt #dbg.varref<"x">
    dbg.decl_stmt #dbg.varref<"x">
    // dbg.connect_stmt
    // CHECK: dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"y">
    dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"y">
    // a condition carried by a materialised expression
    // CHECK: dbg.subblock condition [[EX0]] {
    dbg.subblock condition %0 {
      // CHECK: dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"z">
      dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"z">
      // nested subblock, condition named by a variable, negated
      // CHECK: dbg.subblock conditionRef #dbg.varref<"en"> negated true {
      dbg.subblock conditionRef #dbg.varref<"en"> negated true {
        // CHECK: dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"w">
        dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"w">
      }
    }
    // a condition that could not be reduced to either
    // CHECK: dbg.subblock conditionRef #dbg.opaque_cond {
    dbg.subblock conditionRef #dbg.opaque_cond {
      // a source with no name of its own
      // CHECK: dbg.connect_stmt #dbg.varref<"x"> = #dbg.const_source
      dbg.connect_stmt #dbg.varref<"x"> = #dbg.const_source
    }
  }

  // paths into aggregates stay structured rather than flattened
  // CHECK: dbg.rootblock {
  dbg.rootblock {
    // CHECK: dbg.decl_stmt #dbg.varref<"io", ["a"]>
    dbg.decl_stmt #dbg.varref<"io", ["a"]>
    // CHECK: dbg.connect_stmt #dbg.varref<"v", [2 : i64]> = #dbg.varref<"io", ["b", "c"]>
    dbg.connect_stmt #dbg.varref<"v", [2 : i64]> = #dbg.varref<"io", ["b", "c"]>
  }

  return
}

// A cross-module source is a symbol, not a flattened path string.
// CHECK-LABEL: func.func @XmrSource
func.func @XmrSource() {
  // CHECK: dbg.rootblock {
  dbg.rootblock {
    // CHECK: dbg.connect_stmt #dbg.varref<"x"> = @path
    dbg.connect_stmt #dbg.varref<"x"> = @path
  }
  return
}
