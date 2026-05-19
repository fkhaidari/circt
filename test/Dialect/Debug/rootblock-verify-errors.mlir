// RUN: circt-opt %s --verify-diagnostics --split-input-file

// -----
// Foreign op inside dbg.rootblock body must be rejected.

func.func @RootBlockForeignOp() {
  // expected-error @+1 {{body may only contain dbg.subblock, dbg.connect_stmt, or dbg.decl_stmt; got 'arith.constant'}}
  dbg.rootblock {
    %c = arith.constant 0 : i32
  }
  return
}

// -----
// Foreign op inside dbg.subblock body must be rejected.

func.func @SubBlockForeignOp() {
  dbg.rootblock {
    // expected-error @+1 {{body may only contain dbg.subblock, dbg.connect_stmt, or dbg.decl_stmt; got 'arith.constant'}}
    dbg.subblock conditionRef #dbg.varref<"cond"> {
      %c = arith.constant 0 : i32
    }
  }
  return
}

// -----
// A subblock with no condition at all leaves a consumer unable to tell the
// group apart from an unconditional one.

func.func @SubBlockNoCondition() {
  dbg.rootblock {
    // expected-error @+1 {{missing condition}}
    dbg.subblock {
      dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"y">
    }
  }
  return
}

// -----
// Two conditions are two answers to one question.

func.func @SubBlockBothConditions(%arg0: i1) {
  %e = dbg.expression "c", opcode "&&", operands(%arg0 : i1)
  dbg.rootblock {
    // expected-error @+1 {{condition given both as an operand and as an attribute}}
    dbg.subblock condition %e conditionRef #dbg.varref<"cond"> {
      dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"y">
    }
  }
  return
}

// -----
// An empty root names nothing.

func.func @EmptyRoot() {
  dbg.rootblock {
    // expected-error @+1 {{root name must not be empty}}
    dbg.decl_stmt #dbg.varref<"">
  }
  return
}

// -----
// A path step must select a field or an element.

func.func @BadPathStep() {
  dbg.rootblock {
    // expected-error @+1 {{path step 0 must be a field name or an element index}}
    dbg.decl_stmt #dbg.varref<"io", [unit]>
  }
  return
}

// -----
// Valid dbg.rootblock (no error expected).

func.func @RootBlockValid(%arg0: i1) {
  %e = dbg.expression "cond", opcode "&&", operands(%arg0 : i1)
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"x">
    dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"y">
    dbg.subblock condition %e {
      dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"z">
    }
    dbg.subblock conditionRef #dbg.opaque_cond {
      dbg.connect_stmt #dbg.varref<"io", ["a"]> = #dbg.const_source
    }
  }
  return
}
