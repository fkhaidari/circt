// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// Exercises sourceLangType emission on module / variable / value wrapper, the
// enum-typeRef override for enum-tagged dbg.value wrappers, and
// synthetic-Variable materialisation for bundle fields. Mirrors the
// rameloni Tywaves-Chisel HGLDD shape so the downstream uhdi_to_hgldd
// converter can produce byte-identical `source_lang_type_info` /
// `enum_defs` / `enum_def_ref` on the consuming side.

hw.module @Alu(in %io_in_a : i8, in %io_in_b : i8, in %io_in_op : i2,
               out io_out : i8) attributes {dbg.moduleinfo = {typeName = "Alu"}} {
  %enum = dbg.enum %io_in_op, "AluOp",
    {ADD = 0 : i2, AND = 2 : i2, OR = 3 : i2, SUB = 1 : i2} fqn "Alu.AluOp" : i2
  %sf_a = dbg.value %io_in_a typeName "IO[UInt<8>]" : i8
  %sf_b = dbg.value %io_in_b typeName "IO[UInt<8>]" : i8
  %sf_op = dbg.value %enum typeName "IO[AluOp]" : !dbg.enum
  %sf_out = dbg.value %io_in_a typeName "IO[UInt<8>]" : i8
  %in_bundle = dbg.struct {"a": %sf_a, "b": %sf_b, "op": %sf_op}
    : !dbg.value, !dbg.value, !dbg.value
  %sf_in = dbg.value %in_bundle typeName "IO[Operands]"
    : !dbg.struct
  %io = dbg.struct {"in": %sf_in, "out": %sf_out}
    : !dbg.value, !dbg.value
  %io_v = dbg.value %io typeName "IO[AnonymousBundle]"
    : !dbg.struct
  dbg.variable "io", %io_v
    {uhdi.stable_id = "var_io"}
    : !dbg.value
  hw.output %io_in_a : i8
}

// -----------------------------------------------------------------------
// Module scope picks up dbg.moduleinfo's typeName as the scope-level
// sourceLangType.
// CHECK:      "scopes":
// CHECK:        "Alu":
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "sourceLangType":
// CHECK:                "typeName": "Alu"

// -----------------------------------------------------------------------
// Type pool: enum entry interned under the FQN derived key.
// CHECK:      "types":
// CHECK:        "Alu.AluOp":
// CHECK-NEXT:      "kind": "enum"
// CHECK:           "underlyingTypeRef": "uint2"
// CHECK:           "variants":
// CHECK:             "0": "ADD"
// CHECK:             "1": "SUB"
// CHECK:             "2": "AND"
// CHECK:             "3": "OR"

// -----------------------------------------------------------------------
// Variables: the parent aggregate `var_io` plus one synthetic per
// dbg.value leaf, each carrying its own Chisel-side sourceLangType
// and (for `op`) the enum typeRef.

// Parent aggregate carries the IO[AnonymousBundle] typeName.
// CHECK:      "variables":
// CHECK:        "var_io":
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "io"
// CHECK:              "sourceLangType":
// CHECK:                "typeName": "IO[AnonymousBundle]"

// Synthetic Variables (alphabetical by id; the inner-bundle path is
// "in_<field>" so e.g. `var_io__in__a` precedes `var_io__out`).
// CHECK:        "var_io__in__a":
// CHECK:          "bindKind": "synthetic"
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "a"
// CHECK:              "sourceLangType":
// CHECK:                "typeName": "IO[UInt<8>]"
// CHECK:          "typeRef": "uint8"

// CHECK:        "var_io__in__op":
// CHECK:          "bindKind": "synthetic"
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "op"
// CHECK:              "sourceLangType":
// CHECK:                "typeName": "IO[AluOp]"
// CHECK:          "typeRef": "Alu.AluOp"

// CHECK:        "var_io__out":
// CHECK:          "bindKind": "synthetic"
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "out"
// CHECK:              "sourceLangType":
// CHECK:                "typeName": "IO[UInt<8>]"
