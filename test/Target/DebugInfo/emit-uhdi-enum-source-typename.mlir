// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// Exercises source-language type names on module / variable / value wrapper,
// the enum-typeRef override for enum-tagged dbg.value wrappers, and the
// dotted-path binding of a nested bundle. Mirrors the rameloni Tywaves-Chisel
// HGLDD shape so the downstream converter can produce byte-identical
// `source_lang_type_info` / `enum_defs` / `enum_def_ref` on the consuming side.

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
    : !dbg.value
  hw.output %io_in_a : i8
}

// -----------------------------------------------------------------------
// Type pool: enum entry interned under the FQN-derived key. `Binding[X]` is
// split, and X names the type, so each entry carries its own Chisel name once
// instead of every user repeating it.
// CHECK:      "types":
// CHECK:        "Alu.AluOp":
// CHECK-NEXT:      "kind": "enum"
// CHECK:           "source":
// CHECK-NEXT:        "name": "AluOp"
// CHECK:           "underlyingTypeRef": "uint2"
// CHECK:           "variants":
// CHECK:             "0": "ADD"
// CHECK:             "1": "SUB"
// CHECK:             "2": "AND"
// CHECK:             "3": "OR"

// CHECK:        "Alu_io":
// CHECK-NEXT:      "kind": "struct"
// CHECK:           "source":
// CHECK-NEXT:        "name": "AnonymousBundle"
// CHECK:        "Alu_io_in":
// CHECK-NEXT:      "kind": "struct"
// CHECK:               "typeRef": "Alu.AluOp"
// CHECK:           "source":
// CHECK-NEXT:        "name": "Operands"
// A Chisel `Clock` and a plain `Bool` are both one bit; each keeps an entry of
// its own so the two stay distinguishable.
// CHECK:        "bool_Bool":
// CHECK-NEXT:      "kind": "uint"
// CHECK:           "source":
// CHECK-NEXT:        "name": "Bool"
// CHECK:        "bool_Clock":
// CHECK-NEXT:      "kind": "uint"
// CHECK:           "source":
// CHECK-NEXT:        "name": "Clock"
// CHECK:        "uint8":
// CHECK:           "source":
// CHECK-NEXT:        "name": "UInt<8>"

// -----------------------------------------------------------------------
// A module reports dbg.moduleinfo's typeName as its source-level type.
// CHECK:      "modules":
// CHECK:        "Alu":
// CHECK:          "source": {
// CHECK:            "typeName": "Alu"

// -----------------------------------------------------------------------
// One variable, not a parent plus a record per leaf: every leaf that has a
// value appears in `target.verilog` under its dotted member path. The variable
// keeps only the declaration half of `IO[AnonymousBundle]`, since the type
// already carries the rest.
// CHECK:          "variables": {
// CHECK-NEXT:       "io": {
// CHECK-NEXT:         "source": {
// CHECK-NEXT:           "binding": "IO",
// CHECK-NOT:            "typeName"
// CHECK:              "target": {
// CHECK-NEXT:            "verilog": {
// CHECK-NEXT:              "in.a": "io_in_a",
// CHECK-NEXT:              "in.b": "io_in_b",
// CHECK-NEXT:              "in.op": "io_in_op",
// CHECK-NEXT:              "out": "io_in_a"
// CHECK:              "typeRef": "Alu_io"

// The output port no aggregate leaf covers still gets its own record.
// CHECK:            "io_out": {
// CHECK:              "direction": "output",

// -----------------------------------------------------------------------
// Structure alone does not identify a type: a Chisel `Clock` and a plain
// `Bool` are both one bit, and a consumer that collapses them can no longer
// tell a clock from a boolean. They get an entry each, keyed by the name, and
// the variables just point at the right one -- no per-variable override.
//
// A variable's own constructor params stay on the variable, since two
// declarations of the same type can be parameterised differently.

hw.module @Ground(in %clk : i1, in %rst : i1, in %w : i8)
    attributes {dbg.moduleinfo = {typeName = "Ground"}} {
  %vc = dbg.value %clk typeName "IO[Clock]" : i1
  dbg.variable "clk", %vc : !dbg.value
  %vr = dbg.value %rst typeName "IO[Bool]" : i1
  dbg.variable "rst", %vr : !dbg.value
  %vw = dbg.value %w typeName "Wire[UInt<8>]"
    params [{name = "width", typeName = "Int", value = "8"}] : i8
  dbg.variable "w", %vw : !dbg.value
}

// CHECK:        "Ground":
// CHECK:          "variables": {
// CHECK-NEXT:       "clk": {
// CHECK:              "typeRef": "bool_Clock"
// CHECK:            "rst": {
// CHECK:              "typeRef": "bool_Bool"
// CHECK:            "w": {
// CHECK:              "source": {
// CHECK-NEXT:           "binding": "Wire",
// CHECK:                 "params": [
// CHECK-NEXT:             {
// CHECK-NEXT:               "name": "width",
// CHECK-NEXT:               "type": "Int",
// CHECK-NEXT:               "value": "8"
