// RUN: circt-opt --test-verify-uhdi-refs %s --verify-diagnostics

// Statement refs that resolve to a `dbg.variable` are silent.
hw.module @Resolved(in %a : i1, in %b : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "b", %b : i1
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"a">
    dbg.subblock conditionRef #dbg.varref<"a"> {
      dbg.connect_stmt #dbg.varref<"b"> = #dbg.varref<"a">
    }
  }
}

// A condition carried by a materialised expression is an SSA operand, so it
// is verified by the type system and needs no name lookup here.
hw.module @ExpressionCondition(in %en : i1, in %valid : i1, in %x : i1) {
  dbg.variable "x", %x : i1
  %expr = dbg.expression "g_and", opcode "&", operands(%en, %valid : i1, i1)
  dbg.rootblock {
    dbg.subblock condition %expr {
      dbg.connect_stmt #dbg.varref<"x"> = #dbg.varref<"x">
    }
  }
}

// A condition that could not be reduced names nothing, so nothing is looked
// up. It still records that the group is conditional.
hw.module @OpaqueCondition(in %a : i1) {
  dbg.variable "a", %a : i1
  dbg.rootblock {
    dbg.subblock conditionRef #dbg.opaque_cond {
      dbg.connect_stmt #dbg.varref<"a"> = #dbg.varref<"a">
    }
  }
}

// A constant source names nothing either.
hw.module @ConstSource(in %a : i1, out o : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "o", %a : i1
  dbg.rootblock {
    dbg.connect_stmt #dbg.varref<"o"> = #dbg.const_source
  }
  hw.output %a : i1
}

// A cross-module source resolves against a symbol, not against anything
// visible in this module, so it is left alone.
hw.module @XmrSource(in %a : i1) {
  dbg.variable "a", %a : i1
  dbg.rootblock {
    dbg.connect_stmt #dbg.varref<"a"> = @some_hierpath
  }
}

// Unresolved roots produce one diagnostic each.
hw.module @Unresolved(in %a : i1) {
  dbg.variable "a", %a : i1
  dbg.rootblock {
    // expected-warning @below {{uhdi: statement condition names 'ghost', which is not a dbg.variable in this scope}}
    dbg.subblock conditionRef #dbg.varref<"ghost"> {
      // expected-warning @below {{uhdi: statement dest names 'phantom'}}
      // expected-warning @below {{uhdi: statement src names 'spirit'}}
      dbg.connect_stmt #dbg.varref<"phantom"> = #dbg.varref<"spirit">
    }
    // expected-warning @below {{uhdi: statement target names 'wraith'}}
    dbg.decl_stmt #dbg.varref<"wraith">
    // dest resolves, src does not -- one diagnostic, not two.
    // expected-warning @below {{uhdi: statement src names 'ghost'}}
    dbg.connect_stmt #dbg.varref<"a"> = #dbg.varref<"ghost">
  }
}

// A path is checked against the aggregate the variable actually wraps, not
// against a name. Walking into a real field is silent.
hw.module @AggregatePathResolves(in %a : i8, in %b : i8) {
  %s = dbg.struct {"x": %a, "y": %b} : i8, i8
  dbg.variable "io", %s : !dbg.struct
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"io", ["x"]>
    dbg.connect_stmt #dbg.varref<"io", ["y"]> = #dbg.varref<"io", ["x"]>
  }
}

// A field that is not there is caught, which a flattened name never could be.
hw.module @AggregatePathMissing(in %a : i8, in %b : i8) {
  %s = dbg.struct {"x": %a, "y": %b} : i8, i8
  dbg.variable "io", %s : !dbg.struct
  dbg.rootblock {
    // expected-warning @below {{uhdi: statement target path step 0 does not select anything in 'io'}}
    dbg.decl_stmt #dbg.varref<"io", ["nosuchfield"]>
  }
}

// An index into an array, and an index past its end.
hw.module @ElementPath(in %a : i8, in %b : i8) {
  %arr = dbg.array [%a, %b] : i8
  dbg.variable "v", %arr : !dbg.array
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"v", [1]>
    // expected-warning @below {{uhdi: statement target path step 0 does not select anything in 'v'}}
    dbg.decl_stmt #dbg.varref<"v", [7]>
  }
}

// A `dbg.value` wrapper carries source-language metadata and is transparent
// to path traversal.
hw.module @PathThroughValueWrapper(in %a : i8) {
  %w = dbg.value %a typeName "UInt8" : i8
  %s = dbg.struct {"x": %w} : !dbg.value
  dbg.variable "io", %s : !dbg.struct
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"io", ["x"]>
  }
}

// Two rootblocks under one module, as ModuleInliner leaves them.
hw.module @TwoRootblocks(in %a : i1, in %b : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "b", %b : i1
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"a">
  }
  dbg.rootblock {
    dbg.connect_stmt #dbg.varref<"b"> = #dbg.varref<"a">
  }
}

// Two inlined copies of one module: same variable name under two scopes,
// each rootblock carrying its own. A statement is looked up in the scope of
// the rootblock that encloses it, so the copies are told apart rather than
// reported as ambiguous.
hw.module @InlinedCopiesAreDistinct(in %x : i1, in %y : i1) {
  %s1 = dbg.scope "inst1", "Mod"
  %s2 = dbg.scope "inst2", "Mod"
  dbg.variable "v", %x scope %s1 : i1
  dbg.variable "v", %y scope %s2 : i1
  dbg.rootblock scope %s1 {
    dbg.decl_stmt #dbg.varref<"v">
  }
  dbg.rootblock scope %s2 {
    dbg.decl_stmt #dbg.varref<"v">
  }
}

// A statement may not reach a variable that belongs to another scope.
hw.module @ScopeIsNotBlind(in %x : i1) {
  %s1 = dbg.scope "inst1", "Mod"
  dbg.variable "scoped", %x scope %s1 : i1
  dbg.rootblock {
    // expected-warning @below {{uhdi: statement target names 'scoped', which is not a dbg.variable in this scope}}
    dbg.decl_stmt #dbg.varref<"scoped">
  }
}
