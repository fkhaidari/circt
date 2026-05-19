// RUN: circt-opt --test-verify-uhdi-refs %s --verify-diagnostics

// Statement-tree refs that DO resolve to a `dbg.variable` are silent.
hw.module @Resolved(in %a : i1, in %b : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "b", %b : i1
  dbg.rootblock {
    dbg.decl_stmt "a"
    dbg.subblock guard "a" {
      dbg.connect_stmt "b" = "a"
    }
  }
}

// `<complex>` is the sentinel for unreducible guards; verifier must NOT
// fire on it.
hw.module @ComplexGuardSentinel(in %a : i1) {
  dbg.variable "a", %a : i1
  dbg.rootblock {
    dbg.subblock guard "<complex>" {
      dbg.connect_stmt "a" = "a"
    }
  }
}

// `dbg.expression` names also resolve -- capture-when materialises one
// for compound when-guards and guardRef points at it.
hw.module @ExpressionGuard(in %en : i1, in %valid : i1, in %x : i1) {
  dbg.variable "en", %en : i1
  dbg.variable "valid", %valid : i1
  dbg.variable "x", %x : i1
  %expr = dbg.expression "g_and", opcode "&", operands(%en, %valid : i1, i1)
  dbg.rootblock {
    dbg.subblock guard "g_and" {
      dbg.connect_stmt "x" = "en"
    }
  }
}

// Unresolved refs trigger one warning each. Literal-string fallback is
// the emitter's runtime behaviour; this lint just makes the gap loud.
hw.module @Unresolved(in %a : i1) {
  dbg.variable "a", %a : i1
  dbg.rootblock {
    // expected-warning @below {{uhdi: statement guardRef 'ghost' has no matching dbg.variable}}
    dbg.subblock guard "ghost" {
      // expected-warning @below {{uhdi: statement varRef 'phantom' has no matching dbg.variable}}
      // expected-warning @below {{uhdi: statement valueRef 'spirit' has no matching dbg.variable}}
      dbg.connect_stmt "phantom" = "spirit"
    }
    // expected-warning @below {{uhdi: statement varRef 'wraith' has no matching dbg.variable}}
    dbg.decl_stmt "wraith"
    // varRef resolves ("a" exists), valueRef does not -- only one warning.
    // expected-warning @below {{uhdi: statement valueRef 'ghost' has no matching dbg.variable}}
    dbg.connect_stmt "a" = "ghost"
  }
}

// bp.enableRef is intentionally NOT validated by verifyUhdiStatementRefs.
// Contract (DebugOps.h): literal-string fallback is intentional for names
// that don't yet have a matching dbg.variable (mem-port subfields, XMR refs,
// synthesised capture-when names).  If the verifier is ever "tightened" to
// reject unknown enableRef values, this test will catch it by turning silent
// into expected-warning, which --verify-diagnostics then flags as unexpected.
hw.module @BpEnableRefUnresolved(in %a : i1, in %b : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "b", %b : i1
  dbg.rootblock {
    // varRef and valueRef both resolve; only enableRef is a ghost name.
    // No warning expected -- bp.enableRef is outside the lint scope.
    dbg.connect_stmt "b" = "a" bp {enableRef = "ghost_name_that_does_not_exist"}
  }
}

// Two rootblocks under one module (ModuleInliner clone scenario); both must
// see the same knownByScope entry without false-positives.
hw.module @TwoRootblocks(in %a : i1, in %b : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "b", %b : i1
  dbg.rootblock {
    dbg.decl_stmt "a"
  }
  dbg.rootblock {
    dbg.connect_stmt "b" = "a"
  }
}

// Two dbg.expression ops with the same name under distinct dbg.scope handles:
// the scope-blind lookup finds "g" in 2 scope-buckets and cannot distinguish
// them, so it emits an ambiguous-reference warning at the lookup site.
hw.module @AmbiguousScopeGuardWarns(in %en : i1, in %x : i1) {
  %s1 = dbg.scope "inst1", "Mod"
  %s2 = dbg.scope "inst2", "Mod"
  // Same name "g" under two distinct scope handles — distinct identities.
  %e1 = dbg.expression "g", opcode "&" scope %s1
  %e2 = dbg.expression "g", opcode "|" scope %s2
  dbg.variable "x", %x : i1
  dbg.rootblock {
    // guardRef "g" is ambiguous: present in 2 distinct dbg.scope buckets.
    // expected-warning @+1 {{ambiguous: matches expressions/variables under 2 distinct dbg.scope handles}}
    dbg.subblock guard "g" {
      dbg.connect_stmt "x" = "x"
    }
  }
}

// `<const>` is a sentinel (kUhdiConstSentinel) that capture-when stamps on
// valueRef for connects whose source is constant- or temp-wire-driven and has
// no source-level dbg.variable. The verifier must skip it; otherwise every
// such connect would produce a spurious warning.
hw.module @ConstSentinelExempted(in %a : i1, out o : i1) {
  dbg.variable "a", %a : i1
  dbg.variable "o", %a : i1
  dbg.rootblock {
    // varRef resolves; valueRef is the sentinel — must NOT warn.
    dbg.connect_stmt "o" = "<const>"
  }
  hw.output %a : i1
}

// Two dbg.expression ops with DIFFERENT names under distinct dbg.scope handles:
// each name appears in exactly one scope-bucket, so the lookup is unambiguous
// and no warning fires.
hw.module @DistinctScopesNoAmbiguity(in %en : i1, in %x : i1) {
  %s1 = dbg.scope "inst1", "Mod"
  %s2 = dbg.scope "inst2", "Mod"
  // "g" under %s1 and "h" under %s2 — distinct names, no collision.
  %e1 = dbg.expression "g", opcode "&" scope %s1
  %e2 = dbg.expression "h", opcode "|" scope %s2
  dbg.variable "x", %x : i1
  dbg.rootblock {
    // guardRef "g" resolves uniquely to the %s1 bucket; no warning.
    dbg.subblock guard "g" {
      dbg.connect_stmt "x" = "x"
    }
  }
}
