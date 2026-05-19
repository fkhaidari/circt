// RUN: circt-translate %s --split-input-file --emit-uhdi --uhdi-source-prefix=srcPrefix --uhdi-output-prefix=hdlPrefix 2>/dev/null | FileCheck %s
// RUN: circt-translate %s --split-input-file --emit-uhdi --uhdi-source-prefix=srcPrefix --uhdi-output-prefix=hdlPrefix 2>&1 >/dev/null | FileCheck %s --check-prefix=DIAG --allow-empty

// Pool-based UHDI emission smoke test (spec sec.3-sec.8 shape).
// Exercises: module + inline scope (via dbg.scope), a port variable with
// uhdi.repr_entry stamped by the snapshot pass, type pool dedup for
// multiple uint8 occurrences, and the fixed {chisel, verilog}
// representations manifest.

#locFoo = loc("Foo.scala":4:10)
#locTop = loc("Top.scala":2:1)
#locPort = loc("Top.scala":3:3)
#locScope = loc("Top.scala":7:5)

hw.module @Top(in %a : i8 loc(#locPort), out b : i8) {
  %c1_i8 = hw.constant 1 : i8
  dbg.variable "a", %a {
    uhdi.stable_id = "var_0000_0000",
    uhdi.repr_entry = {verilog = {name = "a"}}
  } : i8 loc(#locPort)
  %scope = dbg.scope "leaf", "Leaf" {uhdi.stable_id = "scope_1111_0000"} loc(#locScope)
  dbg.variable "x", %a scope %scope {
    uhdi.stable_id = "var_2222_0000",
    uhdi.repr_entry = {verilog = {name = "a"}}
  } : i8 loc(#locFoo)
  %0 = comb.add bin %a, %c1_i8 : i8
  hw.output %0 : i8
} loc(#locTop)

// Document envelope.
// CHECK:      "format":
// CHECK-NEXT:   "name": "uhdi"
// CHECK-NEXT:   "version": "1.0"

// Source/HDL files collected with the configured prefixes.
// CHECK:      "representations":
// CHECK:        "chisel":
// CHECK:          "files":
// CHECK:            "srcPrefix{{/|\\\\}}Top.scala"
// CHECK:            "srcPrefix{{/|\\\\}}Foo.scala"
// CHECK:          "kind": "source"
// CHECK:          "language": "Chisel"
// CHECK:        "verilog":
// CHECK:          "kind": "hdl"
// CHECK:          "language": "SystemVerilog"

// Roles default to (chisel / verilog / verilog).
// CHECK:      "roles":
// CHECK-NEXT:   "authoring": "chisel"
// CHECK-NEXT:   "canonical": "verilog"
// CHECK-NEXT:   "simulation": "verilog"

// Module scope.
// CHECK:      "scopes":
// CHECK:        "Top":
// CHECK:          "kind": "module"
// CHECK:          "name": "Top"
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "Top"

// Inline scope entry keyed by stable_id.
// CHECK:        "scope_1111_0000":
// CHECK:          "kind": "inline"
// CHECK:          "name": "Leaf"

// top references the public module.
// CHECK:      "top":
// CHECK:        "Top"

// Type pool dedupes scalar types; uint8 exists exactly once.
// CHECK:      "types":
// CHECK:        "uint8":
// CHECK:          "kind": "uint"
// CHECK:          "width": 8

// Port variable carries direction=input, bindKind=port, and both reprs.
// CHECK:      "variables":
// CHECK:        "var_0000_0000":
// CHECK:          "bindKind": "port"
// CHECK:          "direction": "input"
// CHECK:          "ownerScopeRef": "Top"
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "a"
// CHECK:            "verilog":
// CHECK:              "name": "a"
// CHECK:              "value":
// CHECK:                "sigName": "a"
// CHECK:          "typeRef": "uint8"

// Scoped variable carries ownerScopeRef = the scope's stable_id.
// CHECK:        "var_2222_0000":
// CHECK:          "ownerScopeRef": "scope_1111_0000"

// -----

// Extern modules surface as kind=extmodule scope entries (no port_vars,
// no instantiates).
hw.module.extern @MyExtern(in %a : i8, out b : i8)

// CHECK-LABEL: "MyExtern":
// CHECK-NEXT:    "kind": "extmodule",
// CHECK-NEXT:    "name": "MyExtern"

// -----

// hw.instance children populate `instantiates[]` on the parent scope and
// carry an optional verilog-side rename when PrettifyVerilogNames diverged
// from the source instance name.

#locInst = loc("Top.scala":15:5)

hw.module @Child(in %x : i8, out y : i8) {
  hw.output %x : i8
}

hw.module @Parent(in %a : i8, out b : i8) {
  %c.y = hw.instance "c" @Child(x: %a: i8) -> (y: i8) {hw.verilogName = "c_renamed"} loc(#locInst)
  hw.output %c.y : i8
}

// CHECK-LABEL: "Parent":
// CHECK:         "instantiates":
// CHECK:           "as": "c",
// CHECK:           "representations":
// CHECK:             "verilog":
// CHECK:               "name": "c_renamed"
// CHECK:           "scopeRef": "Child"

// -----

// Output ports: a dbg.variable whose value reaches hw.output via
// sv.read_inout / sv.wire chains gets resolved to the wire's
// hw.verilogName ("_y_output" in the canonical case). The variable
// binds as bindKind=port / direction=output, and the covered port
// must NOT additionally surface as a synthesized var_WithOutput_b
// duplicate.

hw.module @WithOutput(in %a : i8, out b : i8) {
  %c1_i8 = hw.constant 1 : i8
  %_y_output = sv.wire {hw.verilogName = "_y_output"} : !hw.inout<i8>
  %0 = sv.read_inout %_y_output : !hw.inout<i8>
  %1 = comb.add bin %a, %c1_i8 : i8
  sv.assign %_y_output, %1 : i8
  dbg.variable "b", %0 {uhdi.stable_id = "var_3333_0000"} : i8
  hw.output %0 : i8
}

// CHECK-LABEL: "var_3333_0000":
// CHECK:         "bindKind": "port"
// CHECK:         "direction": "output"
// CHECK:         "verilog":
// CHECK-NEXT:      "name": "_y_output",
// CHECK-NEXT:      "status": "preserved",
// CHECK-NEXT:      "value":
// CHECK-NEXT:        "sigName": "_y_output"

// The uncovered input a still gets a synthesized entry; the covered
// output b must not. Keys sort var_3333_0000 < var_WithOutput_a, and a
// duplicate var_WithOutput_b would land right after var_WithOutput_a.
// CHECK:       "var_WithOutput_a":
// CHECK-NOT:   "var_WithOutput_b"

// -----

// Same wire-alias resolution, but the value is wrapped in a dbg.enum cast.
// Name resolution must look through dbg.enum to reach the sv.read_inout/sv.wire
// chain, otherwise the !dbg.enum result type is opaque and sigName goes empty
// (rule #1). typeRef still picks up the enum pool entry.

hw.module @EnumOutput(in %a : i8, out b : i2) {
  %c1_i2 = hw.constant 1 : i2
  %_e_output = sv.wire {hw.verilogName = "_e_output"} : !hw.inout<i2>
  %0 = sv.read_inout %_e_output : !hw.inout<i2>
  %e = dbg.enum %0, "AluOp",
    {ADD = 0 : i2, SUB = 1 : i2} fqn "Top.AluOp" : i2
  sv.assign %_e_output, %c1_i2 : i2
  dbg.variable "be", %e {uhdi.stable_id = "var_enumout"} : !dbg.enum
  hw.output %0 : i2
}

// Same no-duplicate guarantee with the dbg.enum wrapper in the way:
// coverage detection must unwrap dbg.enum before walking the wire-alias
// chain. var_EnumOutput_a (capital E) sorts before var_enumout; a
// synthesized var_EnumOutput_b would land between them.
// CHECK:       "var_EnumOutput_a":
// CHECK-NOT:   "var_EnumOutput_b"

// CHECK-LABEL: "var_enumout":
// CHECK:          "bindKind": "port"
// CHECK:          "direction": "output"
// CHECK:          "verilog":
// CHECK:            "name": "_e_output",
// CHECK:            "value":
// CHECK-NEXT:        "sigName": "_e_output"
// CHECK:          "typeRef": "Top.AluOp"

// -----

// Constant-driven dbg.variable emits `value.constant` instead of a
// sigName trace; downstream HGLDD renders that as a bit_vector literal.

hw.module @ConstDriven(out o : i8) {
  %c42_i8 = hw.constant 42 : i8
  dbg.variable "o", %c42_i8 {uhdi.stable_id = "var_4444_0000"} : i8
  hw.output %c42_i8 : i8
}

// CHECK-LABEL: "var_4444_0000":
// CHECK:         "verilog":
// CHECK-NEXT:      "status": "preserved",
// CHECK-NEXT:      "value":
// CHECK-NEXT:        "constant": 42

// -----

// Wide constants (> 64 bits) cannot ride a JSON number safely, and
// llvm::APInt::getZExtValue() asserts beyond 64 bits. Emit a fixed-width
// `bitVector` binary literal instead so the value survives the round
// trip through both the scalar variable path and the aggregate path.
// The constant must not also feed a named output port -- otherwise
// `resolveVerilogName` short-circuits the leaf to `{sigName: ...}`
// and the constant path is never exercised.

hw.module @WideConst() {
  %c = hw.constant 18446744073709551616 : i72
  dbg.variable "wideC", %c {uhdi.stable_id = "var_wide_scalar"} : i72
  %s = dbg.struct {"x": %c} {uhdi.stable_id = "struct_wide"} : i72
  dbg.variable "io", %s {uhdi.stable_id = "var_wide_aggr"} : !dbg.struct
}

// Aggregate path: the constant rides through ExpressionPool::operandFor.
// Width is implicit in the bit-string length (LeafBitVec carries no
// `width` per expressions.schema.json -- only LeafConst does).
// CHECK:       "expressions":
// CHECK:         "expr_0":
// CHECK-NEXT:      "opcode": "'{"
// CHECK:             "bitVector": "000000010000000000000000000000000000000000000000000000000000000000000000"

// Scalar variable path: emitVariable serialises the same constant into
// the variable's verilog repr. Width is implicit from the variable's
// typeRef, so no `width` key here.
// CHECK:       "var_wide_scalar":
// CHECK:         "verilog":
// CHECK-NEXT:      "status": "preserved",
// CHECK-NEXT:      "value":
// CHECK-NEXT:        "bitVector": "000000010000000000000000000000000000000000000000000000000000000000000000"
// CHECK:         "typeRef": "uint72"

// -----

// Nested-bundle variable: the TypePool interns both the outer and inner
// structs with path-qualified ids ("<Module>_<var>" then
// "<Module>_<var>_<field>" for fields that are themselves aggregates),
// the ExpressionPool reconstructs the aggregate via '{ opcodes, and
// the variable's `typeRef` points at the outer struct.

hw.module @Nested(in %a : i8, in %b : i4, in %out_lo : i12) {
  %inner = dbg.struct {"a": %a, "b": %b} {uhdi.stable_id = "struct_in"} : i8, i4
  %outer = dbg.struct {"in": %inner, "out": %out_lo} {uhdi.stable_id = "struct_out"} : !dbg.struct, i12
  dbg.variable "io", %outer {uhdi.stable_id = "var_5555_0000"} : !dbg.struct
  hw.output
}

// llvm::json::Object iterates keys alphabetically; checks below track
// that order:  expressions -> types -> variables.  Content is otherwise
// identical to what the Python converter topologically sorts into HGLDD.

// Expression pool exists with nested '{ ops (outer references inner via
// exprRef).
// CHECK:       "expressions":
// CHECK:         "expr_0":
// CHECK-NEXT:      "opcode": "'{"
// CHECK:             "exprRef": "expr_1"
// CHECK:         "expr_1":
// CHECK-NEXT:      "opcode": "'{"

// Type pool: outer struct first (lex-shorter), inner struct second.
// CHECK:       "types":
// CHECK:         "Nested_io":
// CHECK-NEXT:      "kind": "struct"
// CHECK-NEXT:      "members":
// CHECK:             "name": "in"
// CHECK-NEXT:        "typeRef": "Nested_io_in"
// CHECK:             "name": "out"
// CHECK-NEXT:        "typeRef": "uint12"
// CHECK:         "Nested_io_in":
// CHECK-NEXT:      "kind": "struct"
// CHECK-NEXT:      "members":
// CHECK:             "name": "a"
// CHECK-NEXT:        "typeRef": "uint8"
// CHECK:             "name": "b"
// CHECK-NEXT:        "typeRef": "uint4"

// Variable: typeRef points at the outer struct; verilog value is an
// exprRef into the '{ pool entry above.
// CHECK:       "variables":
// CHECK:         "var_5555_0000":
// CHECK:           "representations":
// CHECK:             "verilog":
// CHECK:               "value":
// CHECK-NEXT:            "exprRef": "expr_
// CHECK:           "typeRef": "Nested_io"

// -----

// Phase-2 body emission: a dbg.rootblock captured inside a module
// surfaces as a `body` array on the module's scope entry, with
// nested block/connect/decl entries and var/guard refs resolved to
// the stable_id stamped on each dbg.variable.

hw.module @WithBody(in %a : i8, in %en : i1, out q : i8) {
  dbg.variable "a", %a {uhdi.stable_id = "var_a_id"} : i8
  dbg.variable "en", %en {uhdi.stable_id = "var_en_id"} : i1
  dbg.variable "q", %a {uhdi.stable_id = "var_q_id"} : i8
  dbg.rootblock {
    dbg.decl_stmt #dbg.varref<"a">
    dbg.subblock conditionRef #dbg.varref<"en"> {
      dbg.connect_stmt #dbg.varref<"q"> = #dbg.varref<"a">
    }
    dbg.subblock conditionRef #dbg.varref<"en"> negated true {
      dbg.connect_stmt #dbg.varref<"q"> = #dbg.varref<"a">
    }
  }
  hw.output %a : i8
}

// CHECK-LABEL: "WithBody":
// CHECK:         "body":
// decl statement (may have a trailing `locations` block when the op's
// own loc is a FileLineColLoc; we only check the logical fields here).
// CHECK:           "kind": "decl"
// CHECK:           "varRef": "var_a_id"
// The connect inside the when-branch carries bp.enableRef, which the
// emitter derives from the conditions of the enclosing subblocks rather
// than from a field on the statement.
// CHECK:           "bp":
// CHECK-NEXT:        "enableRef": "var_en_id"
// CHECK:           "kind": "connect"
// CHECK:           "valueRef":
// CHECK-NEXT:        "varRef": "var_a_id"
// CHECK:           "varRef": "var_q_id"
// Containing block op: guardRef resolved to the stable_id.
// CHECK:           "guardRef": "var_en_id"
// CHECK:           "kind": "block"
// Else arm shares the guard and flips `negated`.
// CHECK:           "guardRef": "var_en_id"
// CHECK:           "kind": "block"
// CHECK:           "negated": true

// -----
// Two dbg.variable ops sharing one source-level name -- buildVarRefIndex
// must NOT silently shadow the second. Expect a warning at the second op
// and the body-walker's varRef tokens to fall back to the literal name
// (not commit to a confidently-wrong stable_id).

#locDup = loc("Dup.scala":1:1)
hw.module @Dup(in %p : i1 loc(#locDup), out o : i1) {
  dbg.variable "tmp", %p {uhdi.stable_id = "var_aaaa_0000"} : i1 loc(#locDup)
  dbg.variable "tmp", %p {uhdi.stable_id = "var_bbbb_0001"} : i1 loc(#locDup)
  dbg.rootblock {
    dbg.connect_stmt #dbg.varref<"tmp"> = #dbg.varref<"tmp"> loc(#locDup)
  } loc(#locDup)
  hw.output %p : i1
} loc(#locDup)

// Producer-side warning fires on the second colliding dbg.variable op
// (matched by the DIAG prefix run that captures stderr only):
// DIAG: warning: uhdi: dbg.variable name 'tmp' collides within module 'Dup'

// Body resolution falls back to the literal name, not to either stable_id:
// CHECK-LABEL: "Dup":
// CHECK:         "body":
// CHECK:           "kind": "connect"
// CHECK:           "valueRef":
// CHECK-NEXT:        "varRef": "tmp"
// CHECK:           "varRef": "tmp"

// -----

// Regression for input-id ↔ port-id confusion in synthesizePortVars.
// Body-block args are indexed by input-id (HWOpInterfaces.td:95-101);
// synthesizePortVars consumes coveredPortIndices as absolute port-ids.
// With interleaved inputs/outputs + partial dbg.variable coverage, the
// collect walker must translate input-id → port-id via
// ModuleType::getPortIdForInputId — otherwise an uncovered output whose
// port-id numerically matches a covered input's input-id is silently
// dropped from the variables pool, and the covered input is duplicated
// as a synthesized port_var with a conflicting (fixed) typeRef.

hw.module @Interleaved(in %a : i8, out b : i8, in %c : i8, out d : i8) {
  // argNumber(%c) = 1 (input-id); port-id(%c) = 2. Pre-fix covered = {1}
  // would (a) skip port-id 1 (output b — wrongly treated as covered) and
  // (b) synthesize port-id 2 (input c — wrongly treated as uncovered).
  // Post-fix covered = {2}: only c is skipped, all three of a/b/d
  // surface as synthesized port_vars with correct directions.
  dbg.variable "c", %c {uhdi.stable_id = "var_inter_c"} : i8
  %c0 = hw.constant 0 : i8
  hw.output %c0, %c0 : i8, i8
}

// CHECK-LABEL: "Interleaved":
// CHECK:         "kind": "module"

// llvm::json::Object sorts keys alphabetically; capital 'I' (0x49) sorts
// before lowercase 'i' (0x69), so the three synthesized port_vars
// precede the real var_inter_c.
// CHECK:       "var_Interleaved_a":
// CHECK:         "direction": "input"
// CHECK:       "var_Interleaved_b":
// CHECK:         "direction": "output"
// No synthesized entry for c — c is already covered by the real
// dbg.variable below. The pre-fix bug would emit one here.
// CHECK-NOT:   "var_Interleaved_c":
// CHECK:       "var_Interleaved_d":
// CHECK:         "direction": "output"

// The real dbg.variable on the covered input survives with its stable_id.
// CHECK:       "var_inter_c":
// CHECK:         "ownerScopeRef": "Interleaved"
