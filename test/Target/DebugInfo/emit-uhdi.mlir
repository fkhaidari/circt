// RUN: circt-translate %s --split-input-file --emit-uhdi --uhdi-source-prefix=srcPrefix --uhdi-output-prefix=hdlPrefix 2>/dev/null | FileCheck %s
// RUN: circt-translate %s --split-input-file --emit-uhdi --uhdi-source-prefix=srcPrefix --uhdi-output-prefix=hdlPrefix 2>&1 >/dev/null | FileCheck %s --check-prefix=DIAG --allow-empty

// No section draws a diagnostic; an extern-only input is emitted as-is.
// DIAG-NOT: warning

// UHDI emission smoke test. Exercises: module + inline scope (via
// dbg.scope), a port variable, type pool dedup for multiple uint8 occurrences,
// and the two language manifests.

#locFoo = loc("Foo.scala":4:10)
#locTop = loc("Top.scala":2:1)
#locPort = loc("Top.scala":3:3)
#locScope = loc("Top.scala":7:5)

hw.module @Top(in %a : i8 loc(#locPort), out b : i8) {
  %c1_i8 = hw.constant 1 : i8
  dbg.variable "a", %a : i8 loc(#locPort)
  %scope = dbg.scope "leaf", "Leaf" loc(#locScope)
  dbg.variable "x", %a scope %scope : i8 loc(#locFoo)
  %0 = comb.add bin %a, %c1_i8 : i8
  hw.output %0 : i8
} loc(#locTop)

// Document envelope.
// CHECK:      "format":
// CHECK-NEXT:   "version": "1.0"

// Source and target files, collected with the configured prefixes. Each is a
// language plus the files that language contributed.
// CHECK:      "source":
// CHECK-NEXT:   "files":
// CHECK-NEXT:     "srcPrefix{{/|\\\\}}Top.scala"
// CHECK-NEXT:     "srcPrefix{{/|\\\\}}Foo.scala"
// CHECK:        "language": "Chisel"
// CHECK:      "target":
// CHECK:        "language": "SystemVerilog"

// Type pool dedupes scalar types; uint8 exists exactly once.
// CHECK:      "types":
// CHECK:        "uint8":
// CHECK-NEXT:     "kind": "uint"
// CHECK-NEXT:     "width": 8

// The module is keyed by its source name, which `source` does not repeat.
// CHECK:      "modules":
// CHECK:        "Top":
// CHECK-NOT:      "name": "Top"

// The port variable is keyed by its source name and binds to its own signal.
// CHECK:          "variables":
// CHECK-NEXT:       "a":
// CHECK-NEXT:         "direction": "input",
// CHECK:              "target":
// CHECK-NEXT:            "verilog": "a"

// The scoped variable lives inside the inline scope that owns it, not
// alongside the module's own.
// CHECK:          "scopes": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "kind": "inline",
// CHECK:              "name": "leaf"
// CHECK:              "variables":
// CHECK-NEXT:           "x":

// -----

// Extern modules surface as kind=extmodule entries (no variables, no
// instances). An extern-only design is emitted as-is: no `top` key and no
// synthetic module standing in for one.
hw.module.extern @MyExtern(in %a : i8, out b : i8)

// CHECK-LABEL: "MyExtern":
// CHECK-NEXT:    "kind": "extmodule"
// CHECK-NEXT:    "variables": {}

// -----

// hw.instance children populate `instances` on the parent module and
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
// CHECK:         "instances":
// CHECK-NEXT:      "c":
// CHECK-NEXT:        "moduleRef": "Child",
// CHECK:             "target":
// CHECK-NEXT:          "name": "c_renamed"

// -----

// Output ports: a dbg.variable whose value reaches hw.output via
// sv.read_inout / sv.wire chains is an output. Named after the port it
// drives, it binds to the port itself rather than to the wire's
// hw.verilogName ("_y_output"), and the covered port must NOT additionally
// surface as a synthesized duplicate.

hw.module @WithOutput(in %a : i8, out b : i8) {
  %c1_i8 = hw.constant 1 : i8
  %_y_output = sv.wire {hw.verilogName = "_y_output"} : !hw.inout<i8>
  %0 = sv.read_inout %_y_output : !hw.inout<i8>
  %1 = comb.add bin %a, %c1_i8 : i8
  sv.assign %_y_output, %1 : i8
  dbg.variable "b", %0 : i8
  hw.output %0 : i8
}

// The uncovered input a still gets a synthesized entry; the covered output b
// must not, so `a` and `b` are the only two keys here.
// CHECK-LABEL: "WithOutput":
// CHECK:         "variables":
// CHECK-NEXT:      "a":
// CHECK:             "direction": "input",
// CHECK:           "b":
// CHECK-NEXT:        "direction": "output",
// CHECK:             "target":
// CHECK-NEXT:          "verilog": "b"
// CHECK-NOT:       "b.1"

// -----

// Same wire-alias resolution, but the value is wrapped in a dbg.enum cast.
// Name resolution must look through dbg.enum to reach the sv.read_inout/sv.wire
// chain, otherwise the !dbg.enum result type is opaque and the binding goes
// empty (rule #1). typeRef still picks up the enum pool entry.

hw.module @EnumOutput(in %a : i8, out b : i2) {
  %c1_i2 = hw.constant 1 : i2
  %_e_output = sv.wire {hw.verilogName = "_e_output"} : !hw.inout<i2>
  %0 = sv.read_inout %_e_output : !hw.inout<i2>
  %e = dbg.enum %0, "AluOp",
    {ADD = 0 : i2, SUB = 1 : i2} fqn "Top.AluOp" : i2
  sv.assign %_e_output, %c1_i2 : i2
  dbg.variable "be", %e : !dbg.enum
  hw.output %0 : i2
}

// `be` drives the output but is not named after it, so it is a node with the
// wire it lives on, and port `b` gets its own record. The dbg.enum wrapper
// still has to be unwrapped for `be` to reach the wire at all.
// CHECK-LABEL: "EnumOutput":
// CHECK:         "variables":
// CHECK-NEXT:      "a":
// CHECK:           "b": {
// CHECK-NEXT:        "direction": "output",
// CHECK:           "be": {
// CHECK-NEXT:        "source": {
// CHECK:             "target": {
// CHECK-NEXT:          "verilog": "_e_output"
// CHECK:             "typeRef": "Top.AluOp"
// CHECK-NOT:       "b.1"

// -----

// A dbg.variable named after the output port its constant drives is that
// port: one record, bound to the port's own signal rather than the literal.
// A constant that drives no port binds to the literal; downstream HGLDD
// renders that as a bit_vector literal.

hw.module @ConstDriven(out o : i8) {
  %c42_i8 = hw.constant 42 : i8
  %c7_i8 = hw.constant 7 : i8
  dbg.variable "o", %c42_i8 : i8
  dbg.variable "k", %c7_i8 : i8
  hw.output %c42_i8 : i8
}

// CHECK-LABEL: "ConstDriven":
// CHECK:         "variables":
// CHECK-NEXT:      "k":
// CHECK:             "target":
// CHECK-NEXT:          "verilog":
// CHECK-NEXT:            "constant": 7
// CHECK:           "o":
// CHECK-NEXT:        "direction": "output",
// CHECK:             "target":
// CHECK-NEXT:          "verilog": "o"
// CHECK-NOT:       "o.1"

// -----

// Wide constants (> 64 bits) cannot ride a JSON number safely, and
// llvm::APInt::getZExtValue() asserts beyond 64 bits. Emit a fixed-width
// `bitVector` binary literal instead so the value survives the round
// trip through both the scalar variable path and the aggregate path.
// The constant must not also feed a named output port -- otherwise
// `resolveVerilogName` short-circuits the leaf to a signal name
// and the constant path is never exercised.

hw.module @WideConst() {
  %c = hw.constant 18446744073709551616 : i72
  dbg.variable "wideC", %c : i72
  %s = dbg.struct {"x": %c} : i72
  dbg.variable "io", %s : !dbg.struct
}

// Aggregate path: the constant lands under the member's dotted path.
// CHECK-LABEL: "WideConst":
// CHECK:         "variables":
// CHECK-NEXT:      "io":
// CHECK:             "target":
// CHECK-NEXT:          "verilog":
// CHECK-NEXT:            "x":
// CHECK-NEXT:              "bitVector": "000000010000000000000000000000000000000000000000000000000000000000000000"
// CHECK:             "typeRef": "WideConst_io"

// Scalar path: the variable binds straight to the literal.
// Width is implicit in the bit-string length.
// CHECK:           "wideC":
// CHECK:             "target":
// CHECK-NEXT:          "verilog":
// CHECK-NEXT:            "bitVector": "000000010000000000000000000000000000000000000000000000000000000000000000"

// -----

// Nested-bundle variable: the TypePool interns both the outer and inner
// structs with path-qualified ids ("<Module>_<var>" then
// "<Module>_<var>_<field>" for fields that are themselves aggregates), the
// variable's `typeRef` points at the outer struct, and one `target.verilog` map
// holds every leaf under its dotted path.

hw.module @Nested(in %a : i8, in %b : i4, in %out_lo : i12) {
  %inner = dbg.struct {"a": %a, "b": %b} : i8, i4
  %outer = dbg.struct {"in": %inner, "out": %out_lo} {dbg.flips = array<i1: true, false>} : !dbg.struct, i12
  dbg.variable "io", %outer : !dbg.struct
  hw.output
}

// Type pool: outer struct first (lex-shorter), inner struct second. Only the
// member `dbg.flips` marks is flipped; the inner members are block arguments
// too, and that does not flip them.
// CHECK:       "types":
// CHECK:         "Nested_io":
// CHECK-NEXT:      "kind": "struct"
// CHECK-NEXT:      "members":
// CHECK-NEXT:        {
// CHECK-NEXT:          "flipped": true,
// CHECK-NEXT:          "name": "in"
// CHECK-NEXT:          "typeRef": "Nested_io_in"
// CHECK-NEXT:        },
// CHECK-NEXT:        {
// CHECK-NEXT:          "name": "out"
// CHECK-NEXT:          "typeRef": "uint12"
// CHECK:         "Nested_io_in":
// CHECK-NEXT:      "kind": "struct"
// CHECK-NEXT:      "members":
// CHECK-NEXT:        {
// CHECK-NEXT:          "name": "a"
// CHECK-NEXT:          "typeRef": "uint8"
// CHECK-NEXT:        },
// CHECK-NEXT:        {
// CHECK-NEXT:          "name": "b"
// CHECK-NEXT:          "typeRef": "uint4"

// One variable covers the whole bundle: a nested member contributes its path,
// not a record of its own, and every leaf names the flat signal it lowered to.
// CHECK-LABEL: "Nested":
// CHECK:         "variables":
// CHECK-NEXT:      "io":
// CHECK:             "target":
// CHECK-NEXT:          "verilog":
// CHECK-NEXT:            "in.a": "a",
// CHECK-NEXT:            "in.b": "b",
// CHECK-NEXT:            "out": "out_lo"
// CHECK:             "typeRef": "Nested_io"

// -----

// Regression for input-id ↔ port-id confusion in synthesizePortVars.
// Body-block args are indexed by input-id (HWOpInterfaces.td:95-101);
// synthesizePortVars consumes coveredPortIndices as absolute port-ids.
// With interleaved inputs/outputs + partial dbg.variable coverage, the
// collect walker must translate input-id → port-id via
// ModuleType::getPortIdForInputId — otherwise an uncovered output whose
// port-id numerically matches a covered input's input-id is silently
// dropped, and the covered input is duplicated as a synthesized port record
// with a conflicting (fixed) typeRef.

hw.module @Interleaved(in %a : i8, out b : i8, in %c : i8, out d : i8) {
  // argNumber(%c) = 1 (input-id); port-id(%c) = 2. Pre-fix covered = {1}
  // would (a) skip port-id 1 (output b — wrongly treated as covered) and
  // (b) synthesize port-id 2 (input c — wrongly treated as uncovered).
  // Post-fix covered = {2}: only c is skipped, all three of a/b/d
  // surface as synthesized port records with correct directions.
  dbg.variable "c", %c : i8
  %c0 = hw.constant 0 : i8
  hw.output %c0, %c0 : i8, i8
}

// The covered input is listed once, through the real dbg.variable, and the
// three uncovered ports each carry their own direction.
// CHECK-LABEL: "Interleaved":
// CHECK:         "variables":
// CHECK-NEXT:      "a":
// CHECK:             "direction": "input",
// CHECK:           "b":
// CHECK:             "direction": "output",
// CHECK:           "c":
// CHECK:             "direction": "input",
// CHECK:           "d":
// CHECK:             "direction": "output",
// No second record for c — the real dbg.variable already covers it.
// CHECK-NOT:       "c.1"
