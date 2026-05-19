// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// Prototype: enum modelled as an inline `dbg.enum` cast op instead of a
// separate `dbg.enumdef` definition + FQN string mirrors on value wrappers. Each
// use site carries the full variant map; identical enums (same fqn) across
// modules must collapse to a single type-pool entry. There is NO dbg.enumdef
// in this input, so a hit on "shared.AluOp" can only come from the dbg.enum
// interning path (negative control for the old pre-pass).

hw.module @Owner(in %op : i2) attributes {dbg.moduleinfo = {typeName = "Owner"}} {
  %e = dbg.enum %op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "shared.AluOp" : i2
  %sf_op_owner = dbg.value %e typeName "IO[AluOp]" : !dbg.enum
  %io_owner = dbg.struct {"op": %sf_op_owner} : !dbg.value
  %io_owner_v = dbg.value %io_owner typeName "IO[Bundle]" : !dbg.struct
  dbg.variable "io", %io_owner_v
    {uhdi.stable_id = "var_owner_io"} : !dbg.value
}

hw.module @Borrower(in %op : i2) attributes {dbg.moduleinfo = {typeName = "Borrower"}} {
  %e = dbg.enum %op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "shared.AluOp" : i2
  %sf_op_borrower = dbg.value %e typeName "IO[AluOp]" : !dbg.enum
  %io_borrower = dbg.struct {"op": %sf_op_borrower} : !dbg.value
  %io_borrower_v = dbg.value %io_borrower typeName "IO[Bundle]" : !dbg.struct
  dbg.variable "io", %io_borrower_v
    {uhdi.stable_id = "var_borrower_io"} : !dbg.value
}

// Enum pool entry interned by FQN once, shape identical to the dbg.enumdef path.
// CHECK:        "shared.AluOp":
// CHECK-NEXT:      "kind": "enum"

// Variables are emitted in id-sorted order: var_alu__op (Alu.AluOp) precedes
// the two shared.AluOp leaves. All three resolve to an enum typeRef.
// CHECK:      "variables":
// CHECK:        "var_alu__op":
// CHECK:          "typeRef": "Alu.AluOp"
// CHECK:        "var_borrower_io__op":
// CHECK:          "typeRef": "shared.AluOp"
// CHECK:        "var_owner_io__op":
// CHECK:          "typeRef": "shared.AluOp"

// -----------------------------------------------------------------------
// Enum leaf inside a dbg.struct, wrapped in dbg.enum: the synthetic leaf
// variable carries the enum typeRef. (Field sigName resolution for dbg.enum
// is exercised separately in emit-uhdi.mlir, where fields resolve through the
// post-ExportVerilog wire-alias chain.)

hw.module @Alu(in %io_in_op : i2, out io_out : i8)
    attributes {dbg.moduleinfo = {typeName = "Alu"}} {
  %c0 = hw.constant 0 : i8
  %e = dbg.enum %io_in_op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "Alu.AluOp" : i2
  %sf_op = dbg.value %e typeName "IO[AluOp]" : !dbg.enum
  %in_bundle = dbg.struct {"op": %sf_op} : !dbg.value
  %in_bundle_v = dbg.value %in_bundle typeName "IO[Operands]"
    : !dbg.struct
  dbg.variable "aluio", %in_bundle_v
    {uhdi.stable_id = "var_alu"} : !dbg.value
  hw.output %c0 : i8
}
