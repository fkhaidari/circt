// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// Shared enums in multi-module designs: each module materialises its own
// inline `dbg.enum` carrying the full variant map. The emitter interns them
// by content key (fqn), so identical enums across modules collapse to a
// single "shared.AluOp" type-pool entry.

hw.module @Owner(in %op : i2) attributes {dbg.moduleinfo = {typeName = "Owner"}} {
  // Each module carries its own inline dbg.enum with the full variant map.
  %enum = dbg.enum %op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "shared.AluOp" : i2
  %sf_op_owner = dbg.value %enum typeName "IO[AluOp]" : !dbg.enum
  %io_owner = dbg.struct {"op": %sf_op_owner} : !dbg.value
  %io_owner_v = dbg.value %io_owner typeName "IO[Bundle]" : !dbg.struct
  dbg.variable "io", %io_owner_v
    {uhdi.stable_id = "var_owner_io"} : !dbg.value
}

hw.module @Borrower(in %op : i2) attributes {dbg.moduleinfo = {typeName = "Borrower"}} {
  // A separate inline dbg.enum with identical (fqn, variants); the emitter
  // interns both into one "shared.AluOp" type-pool entry by content key.
  %enum = dbg.enum %op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "shared.AluOp" : i2
  %sf_op_borrower = dbg.value %enum typeName "IO[AluOp]" : !dbg.enum
  %io_borrower = dbg.struct {"op": %sf_op_borrower} : !dbg.value
  %io_borrower_v = dbg.value %io_borrower typeName "IO[Bundle]" : !dbg.struct
  dbg.variable "io", %io_borrower_v
    {uhdi.stable_id = "var_borrower_io"} : !dbg.value
}

// Structural dedup means Borrower's "io" reuses the same struct id as Owner's
// (both resolve "op" to the shared enum entry).
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
