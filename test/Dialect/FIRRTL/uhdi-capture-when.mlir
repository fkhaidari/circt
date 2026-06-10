// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-uhdi-init, firrtl-uhdi-capture-when, firrtl-uhdi-init)))' %s | FileCheck %s

// capture-when walks firrtl.when / firrtl.connect before ExpandWhens and
// records the control-flow tree into a `dbg.rootblock` region. References
// into the debug variables are typed: an SSA handle on a materialised
// expression, a `#dbg.varref` naming a variable and a path into whatever
// aggregate it wraps, or an explicit marker where neither applies. The
// second uhdi-init
// run mirrors firtool's production pipeline (Firtool.cpp:164) and stamps
// `uhdi.stable_id` onto ops synthesised by capture-when (compound-guard
// `dbg.expression`s and per-port mem `dbg.variable`s) that did not exist
// when the first uhdi-init walked the IR.

// CHECK-LABEL: firrtl.circuit "Counter"
firrtl.circuit "Counter" {

  // CHECK-LABEL: firrtl.module @Counter
  firrtl.module @Counter(in %clock: !firrtl.clock, in %reset: !firrtl.uint<1>,
                         in %en: !firrtl.uint<1>, out %q: !firrtl.uint<8>) {
    dbg.variable "clock", %clock : !firrtl.clock
    dbg.variable "reset", %reset : !firrtl.uint<1>
    dbg.variable "en", %en : !firrtl.uint<1>
    %r = firrtl.reg %clock {name = "r"} : !firrtl.clock, !firrtl.uint<8>
    dbg.variable "r", %r : !firrtl.uint<8>
    %c0 = firrtl.constant 0 : !firrtl.uint<8>
    %c1 = firrtl.constant 1 : !firrtl.uint<8>
    dbg.variable "q", %r : !firrtl.uint<8>
    firrtl.when %reset : !firrtl.uint<1> {
      firrtl.connect %r, %c0 : !firrtl.uint<8>, !firrtl.uint<8>
    } else {
      firrtl.when %en : !firrtl.uint<1> {
        %sum = firrtl.add %r, %c1 : (!firrtl.uint<8>, !firrtl.uint<8>)
            -> !firrtl.uint<9>
        %sum_lo = firrtl.tail %sum, 1 : (!firrtl.uint<9>) -> !firrtl.uint<8>
        firrtl.connect %r, %sum_lo : !firrtl.uint<8>, !firrtl.uint<8>
      }
    }
    firrtl.matchingconnect %q, %r : !firrtl.uint<8>

    // dbg.rootblock is appended at the end of the module. The trailing
    // `{` anchors each CHECK to the *opening* of each subblock so a
    // regression that drops the body or fuses two subblocks fails the
    // match. The connects inside the when-arms are dropped by capture-
    // when (the constant / sum-tail sources have no source-level name),
    // so the inner bodies are empty here.
    // CHECK: dbg.rootblock {
    // CHECK:   dbg.decl_stmt #dbg.varref<"r">
    // CHECK:   dbg.subblock conditionRef #dbg.varref<"reset"> {
    // CHECK:   dbg.subblock conditionRef #dbg.varref<"reset"> negated true {
    // CHECK:     dbg.subblock conditionRef #dbg.varref<"en"> {
    // Unconditional connect outside any when.
    // CHECK:   dbg.connect_stmt #dbg.varref<"q"> = #dbg.varref<"r">
  }

  // Compound-guard module: `when and(en, valid)` triggers materialisation
  // of a `dbg.expression` at module-body level; the subblock references it
  // by the synthesised name. Operands live at module body (block-args of
  // the enclosing FModuleOp) so dominance check passes.
  // CHECK-LABEL: firrtl.module @CompoundGuard
  firrtl.module @CompoundGuard(in %en: !firrtl.uint<1>,
                                in %valid: !firrtl.uint<1>,
                                in %x: !firrtl.uint<8>, out %r: !firrtl.uint<8>) {
    dbg.variable "en", %en : !firrtl.uint<1>
    dbg.variable "valid", %valid : !firrtl.uint<1>
    dbg.variable "x", %x : !firrtl.uint<8>
    %c0 = firrtl.constant 0 : !firrtl.uint<8>
    %cond = firrtl.and %en, %valid : (!firrtl.uint<1>, !firrtl.uint<1>)
        -> !firrtl.uint<1>
    firrtl.when %cond : !firrtl.uint<1> {
      firrtl.connect %r, %x : !firrtl.uint<8>, !firrtl.uint<8>
    } else {
      firrtl.connect %r, %c0 : !firrtl.uint<8>, !firrtl.uint<8>
    }

    // The dbg.expression is emitted BEFORE the dbg.rootblock at module
    // body level with a synthesised name of the form
    // `__uhdi_expr_<ModuleName>_<N>`. Its opcode is `&` (bitwise AND at
    // uint<1> width, semantically == &&). The second uhdi-init run stamps
    // the synthesised expression with a stable_id of shape `expr_<hex>_<hex>`.
    // Both arms take the expression's result as an operand, so the link is
    // an SSA edge rather than a name the two sides have to agree on.
    // CHECK:      [[EXPR:%.+]] = dbg.expression "__uhdi_expr_CompoundGuard_0"
    // CHECK-SAME: opcode "&"
    // CHECK-SAME: uhdi.stable_id = "{{expr_[0-9a-f]+_[0-9a-f]+}}"
    // CHECK:      dbg.rootblock
    // CHECK:        dbg.subblock condition [[EXPR]] {
    // CHECK:        dbg.subblock condition [[EXPR]] negated true
  }

  // Nested compound: an inner `when` whose condition `and(en, not(valid))`
  // is computed INSIDE the outer when's body (so the firrtl primops
  // live in a child region, not at module body). The recursive
  // materialiser walks down: %not_valid (in child region) -> find a
  // module-body proxy fails -> recurse into firrtl.not -> its operand
  // %valid is a module input (block-arg of the FModuleOp), passes; emit
  // an inner dbg.expression at module body. Then the outer `and`
  // materialises with operands (%en module-arg, inner !dbg.expression
  // result). Both expression ops live at module body so dominance
  // holds for the !dbg.expression operand.
  // CHECK-LABEL: firrtl.module @NestedCompound
  firrtl.module @NestedCompound(in %en: !firrtl.uint<1>,
                                 in %valid: !firrtl.uint<1>,
                                 in %outer: !firrtl.uint<1>,
                                 in %x: !firrtl.uint<8>, out %r: !firrtl.uint<8>) {
    dbg.variable "en", %en : !firrtl.uint<1>
    dbg.variable "valid", %valid : !firrtl.uint<1>
    dbg.variable "outer", %outer : !firrtl.uint<1>
    dbg.variable "x", %x : !firrtl.uint<8>
    firrtl.when %outer : !firrtl.uint<1> {
      // Compute inside outer when -- guarantees these primops live in
      // a child region.
      %not_valid = firrtl.not %valid : (!firrtl.uint<1>) -> !firrtl.uint<1>
      %cond = firrtl.and %en, %not_valid : (!firrtl.uint<1>, !firrtl.uint<1>)
          -> !firrtl.uint<1>
      firrtl.when %cond : !firrtl.uint<1> {
        firrtl.connect %r, %x : !firrtl.uint<8>, !firrtl.uint<8>
      }
    }

    // Two dbg.expression ops at module body. Counter is per-module so
    // the inner (recursed first) gets _0, outer gets _1.
    // CHECK:      dbg.expression "__uhdi_expr_NestedCompound_0"
    // CHECK-SAME: opcode "!"
    // CHECK:      [[OUTER_EXPR:%.+]] = dbg.expression "__uhdi_expr_NestedCompound_1"
    // CHECK-SAME: opcode "&"
    // CHECK:      dbg.rootblock
    // CHECK:        dbg.subblock conditionRef #dbg.varref<"outer">
    // CHECK:          dbg.subblock condition [[OUTER_EXPR]]
  }

  // firrtl.mem ports get per-field dbg.variable wrappers synthesised
  // upfront. Names use `_` separators (matches post-LowerCHIRRTL flat-
  // wire convention + native HGLDD output). Each variable wraps a
  // firrtl.subfield that future LowerCHIRRTL rewires onto the actual
  // scalar wire, then snapshot picks up its Verilog name.
  // CHECK-LABEL: firrtl.module @WithMem
  firrtl.module @WithMem(in %clock: !firrtl.clock,
                          in %addr: !firrtl.uint<4>,
                          in %en: !firrtl.uint<1>,
                          out %dout: !firrtl.uint<8>) {
    %bank_r, %bank_w = firrtl.mem Undefined {depth = 16 : i64,
        name = "bank", portNames = ["r", "w"], readLatency = 0 : i32,
        writeLatency = 1 : i32}
        : !firrtl.bundle<addr: uint<4>, en: uint<1>, clk: clock,
                         data flip: uint<8>>,
          !firrtl.bundle<addr: uint<4>, en: uint<1>, clk: clock,
                         data: uint<8>, mask: uint<1>>
    // (rest of mem wiring elided for the test)

    // Per-port-per-field dbg.variable. Names follow `<mem>_<port>_<field>`.
    // The second uhdi-init run stamps each synthesised dbg.variable with a
    // stable_id of shape `var_<hex>_<hex>`; spot-check on bank_r_addr.
    // CHECK: dbg.variable "bank_r_addr"
    // CHECK-SAME: uhdi.stable_id = "{{var_[0-9a-f]+_[0-9a-f]+}}"
    // CHECK: dbg.variable "bank_r_en"
    // CHECK: dbg.variable "bank_r_clk"
    // CHECK: dbg.variable "bank_r_data"
    // CHECK: dbg.variable "bank_w_addr"
    // CHECK: dbg.variable "bank_w_en"
    // CHECK: dbg.variable "bank_w_mask"
  }

  // Aggregate regreset: the connect targets a bundle field via
  // `firrtl.subfield`, not the RegResetOp result directly. The pass must
  // walk the LHS chain up through SubfieldOp/SubindexOp to find the root
  // RegResetOp and still emit the `!reset` guard. Regression for the
  // dropped-guard bug on lowered (post-LowerCHIRRTL) and naturally-
  // aggregate regresets.
  // CHECK-LABEL: firrtl.module @BundleRegreset
  firrtl.module @BundleRegreset(in %clock: !firrtl.clock,
                                 in %reset: !firrtl.uint<1>,
                                 in %x: !firrtl.uint<8>) {
    dbg.variable "clock", %clock : !firrtl.clock
    dbg.variable "reset", %reset : !firrtl.uint<1>
    dbg.variable "x", %x : !firrtl.uint<8>
    %init = firrtl.wire {name = "init"} : !firrtl.bundle<a: uint<8>>
    dbg.variable "init", %init : !firrtl.bundle<a: uint<8>>
    %r = firrtl.regreset %clock, %reset, %init {name = "r"}
        : !firrtl.clock, !firrtl.uint<1>,
          !firrtl.bundle<a: uint<8>>, !firrtl.bundle<a: uint<8>>
    dbg.variable "r", %r : !firrtl.bundle<a: uint<8>>
    %r_a = firrtl.subfield %r[a] : !firrtl.bundle<a: uint<8>>
    firrtl.connect %r_a, %x : !firrtl.uint<8>, !firrtl.uint<8>

    // Reset priority is recorded the same way any other condition is: as an
    // enclosing subblock. The destination keeps the field it assigns as a
    // path step rather than a name with a separator to decode.
    // CHECK: dbg.rootblock
    // CHECK: dbg.subblock conditionRef #dbg.varref<"reset"> negated true {
    // CHECK:   dbg.connect_stmt #dbg.varref<"r", ["a"]> = #dbg.varref<"x">
  }

  // XMR (cross-module reference) handling is in `xmrSymbol`: the
  // ref.resolve -> ref.sub* -> xmr.ref chain is walked back to the
  // hw.hierpath it names, and the symbol itself is what the statement
  // carries -- a symbol survives renaming, a joined path string does not.
  // Smoke-tested on real-world fixtures with hierpath instances; an
  // isolated lit test would need a full circuit with @inst+@reg
  // SymbolRef targets which doesn't compose cleanly with the per-module
  // pass-pipeline this lit file uses. End-to-end coverage via firtool
  // catches any breakage.

  // CHECK-LABEL: firrtl.module @VecSubindex
  firrtl.module @VecSubindex(in %clock: !firrtl.clock) {
    %vec = firrtl.wire {name = "vec"} : !firrtl.vector<uint<8>, 4>
    dbg.variable "vec", %vec : !firrtl.vector<uint<8>, 4>
    %c42 = firrtl.constant 42 : !firrtl.uint<8>
    %elem = firrtl.subindex %vec[2] : !firrtl.vector<uint<8>, 4>
    firrtl.connect %elem, %c42 : !firrtl.uint<8>, !firrtl.uint<8>

    // A statically indexed element is one path step, not a name with
    // brackets to parse back out.
    // CHECK: dbg.rootblock
    // CHECK: dbg.connect_stmt #dbg.varref<"vec", [2 : i64]>
  }

  // CHECK-LABEL: firrtl.module @VecSubaccess
  firrtl.module @VecSubaccess(in %clock: !firrtl.clock,
                               in %idx: !firrtl.uint<2>) {
    dbg.variable "idx", %idx : !firrtl.uint<2>
    %vec = firrtl.wire {name = "vec"} : !firrtl.vector<uint<8>, 4>
    dbg.variable "vec", %vec : !firrtl.vector<uint<8>, 4>
    %c7 = firrtl.constant 7 : !firrtl.uint<8>
    %elem = firrtl.subaccess %vec[%idx] : !firrtl.vector<uint<8>, 4>, !firrtl.uint<2>
    firrtl.connect %elem, %c7 : !firrtl.uint<8>, !firrtl.uint<8>

    // A dynamic index selects no statically known element, so the
    // reference names the aggregate itself rather than inventing a step
    // that resolves to nothing.
    // CHECK: dbg.rootblock
    // CHECK: dbg.connect_stmt #dbg.varref<"vec">
  }

  // Compound guard whose primop has a CONSTANT leaf defined INSIDE the when
  // block. The materialised dbg.expression lives at module-body level, so an
  // in-when constant cannot be a valid operand (SSA dominance is structural).
  // findModuleBodyProxy must leave it unresolved; the guard falls back to the
  // `<complex>` sentinel rather than producing an invalid dbg.expression.
  // CHECK-LABEL: firrtl.module @InWhenConstGuard
  firrtl.module @InWhenConstGuard(in %clock: !firrtl.clock,
                                   in %a: !firrtl.uint<8>,
                                   in %sel: !firrtl.uint<1>) {
    dbg.variable "a", %a : !firrtl.uint<8>
    dbg.variable "sel", %sel : !firrtl.uint<1>
    %r = firrtl.reg %clock {name = "r"} : !firrtl.clock, !firrtl.uint<8>
    dbg.variable "r", %r : !firrtl.uint<8>
    firrtl.when %sel : !firrtl.uint<1> {
      %k = firrtl.constant 5 : !firrtl.uint<8>
      %g = firrtl.eq %a, %k : (!firrtl.uint<8>, !firrtl.uint<8>) -> !firrtl.uint<1>
      firrtl.when %g : !firrtl.uint<1> {
        firrtl.connect %r, %a : !firrtl.uint<8>, !firrtl.uint<8>
      }
    }

    // The inner guard cannot be materialised (constant leaf trapped in the
    // when), so it is recorded as a condition that did not reduce -- and the
    // IR stays valid (no `does not dominate` verifier error).
    // CHECK: dbg.rootblock
    // CHECK: dbg.subblock conditionRef #dbg.varref<"sel">
    // CHECK: dbg.subblock conditionRef #dbg.opaque_cond
  }
}
