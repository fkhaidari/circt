// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// FG2.5: dbg.subfield carries enumTypeName / enumFqn as string mirrors of
// the dbg.enumdef SSA linkage. When the dbg.enumdef lives in a different
// hw.module (shared enums in multi-module designs), the SSA `enumDef`
// operand is null but the FQN string is preserved and EmitUHDI's type pool
// resolves the enum entry by FQN.

hw.module @Owner(in %op : i2) {
  // Owns the enumdef; its subfield wires up the SSA enumDef operand.
  %enum = dbg.enumdef "AluOp", fqn "shared.AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2}
  dbg.moduleinfo typeName "Owner"
  %sf_op_owner = dbg.subfield "op", %op typeName "IO[AluOp]" enumDef %enum
    {enumTypeName = "AluOp", enumFqn = "shared.AluOp"} : i2
  %io_owner = dbg.struct {"op": %sf_op_owner} : !dbg.subfield
  dbg.variable "io", %io_owner typeName "IO[Bundle]"
    {uhdi.stable_id = "var_owner_io"} : !dbg.struct
}

hw.module @Borrower(in %op : i2) {
  // No local dbg.enumdef; only the FQN string mirror is available. The
  // pre-pass interns Owner's enumdef into the global type pool by FQN, so
  // EmitUHDI's lookupEnumByName resolves the typeRef to "shared.AluOp"
  // instead of the underlying uint2.
  dbg.moduleinfo typeName "Borrower"
  %sf_op_borrower = dbg.subfield "op", %op typeName "IO[AluOp]"
    {enumTypeName = "AluOp", enumFqn = "shared.AluOp"} : i2
  %io_borrower = dbg.struct {"op": %sf_op_borrower} : !dbg.subfield
  dbg.variable "io", %io_borrower typeName "IO[Bundle]"
    {uhdi.stable_id = "var_borrower_io"} : !dbg.struct
}

// Owner's struct keys on the SSA enumDef; structural dedup means
// Borrower's "io" reuses the same struct id (both resolve "op" to the
// shared enum entry).
// CHECK:      "types":
// CHECK:        "Owner_io":
// CHECK:          "kind": "struct"
// CHECK:          "members":
// CHECK:              "name": "op"
// CHECK:              "typeRef": "shared.AluOp"

// Enum pool entry interned by FQN once.
// CHECK:        "shared.AluOp":
// CHECK-NEXT:      "kind": "enum"

// Both the borrowing module's synthetic field and the owning module's
// synthetic field land on the same enum typeRef.
// CHECK:      "variables":
// CHECK:        "var_borrower_io":
// CHECK:          "typeRef": "Owner_io"
// CHECK:        "var_borrower_io__op":
// CHECK:          "typeRef": "shared.AluOp"
// CHECK:        "var_owner_io":
// CHECK:          "typeRef": "Owner_io"
// CHECK:        "var_owner_io__op":
// CHECK:          "typeRef": "shared.AluOp"
