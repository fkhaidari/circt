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
    dbg.subblock guard "cond" {
      %c = arith.constant 0 : i32
    }
  }
  return
}

// -----
// Valid dbg.rootblock (no error expected).

func.func @RootBlockValid() {
  dbg.rootblock {
    dbg.decl_stmt "x"
    dbg.connect_stmt "x" = "y"
    dbg.subblock guard "cond" {
      dbg.connect_stmt "x" = "z"
    }
  }
  return
}
