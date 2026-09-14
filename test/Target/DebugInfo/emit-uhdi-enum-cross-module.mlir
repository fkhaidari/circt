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
  dbg.variable "io", %io_owner_v : !dbg.value
}

hw.module @Borrower(in %op : i2) attributes {dbg.moduleinfo = {typeName = "Borrower"}} {
  // A separate inline dbg.enum with identical (fqn, variants); the emitter
  // interns both into one "shared.AluOp" type-pool entry by content key.
  %enum = dbg.enum %op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "shared.AluOp" : i2
  %sf_op_borrower = dbg.value %enum typeName "IO[AluOp]" : !dbg.enum
  %io_borrower = dbg.struct {"op": %sf_op_borrower} : !dbg.value
  %io_borrower_v = dbg.value %io_borrower typeName "IO[Bundle]" : !dbg.struct
  dbg.variable "io", %io_borrower_v : !dbg.value
}

// Structural dedup means Borrower's "io" reuses the same struct id as Owner's
// (both resolve "op" to the shared enum entry). The bracketed half of each
// leaf's `IO[AluOp]` is what names the type, once, for everyone using it.
// CHECK:      "types":
// CHECK:        "Owner_io":
// CHECK:          "kind": "struct"
// CHECK:          "members":
// CHECK:              "name": "op"
// CHECK:              "typeRef": "shared.AluOp"
// CHECK:          "source":
// CHECK-NEXT:       "name": "Bundle"

// Enum pool entry interned by FQN once.
// CHECK:        "shared.AluOp":
// CHECK-NEXT:      "kind": "enum"
// CHECK:           "source":
// CHECK-NEXT:        "name": "AluOp"

// Both modules describe an `io` of that one struct type, each binding its own
// module's `op` signal. The declaration half is all a variable keeps: the type
// entry holds the name, so `IO[Bundle]` is reconstructible without it.
// `modules` is keyed in sorted order, so Borrower comes first however the IR
// is ordered.
// CHECK:      "modules":
// CHECK:        "Borrower":
// CHECK:          "variables":
// CHECK-NEXT:       "io":
// CHECK:              "binding": "IO"
// CHECK-NOT:          "typeName"
// CHECK:              "verilog":
// CHECK-NEXT:           "op": "op"
// CHECK:            "typeRef": "Owner_io"
// CHECK:        "Owner":
// CHECK:          "variables":
// CHECK-NEXT:       "io":
// CHECK:              "verilog":
// CHECK-NEXT:           "op": "op"
// CHECK:            "typeRef": "Owner_io"
