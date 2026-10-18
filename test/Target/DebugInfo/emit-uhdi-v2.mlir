// RUN: circt-translate %s --emit-uhdi --uhdi-format=2 2>/dev/null | FileCheck %s

// Layout 2: a source module, the target module it became, and the binding
// between their variables and signals.

#locChild = loc("Child.scala":1:1)
#locIo = loc("Child.scala":2:3)
#locReg = loc(fused["Child.scala":3:3, fused<"verilogLocations">["out.sv":9:5]])
#locLost = loc("Child.scala":4:3)
#locTop = loc("Top.scala":1:1)
#locInst = loc("Top.scala":4:5)
#locK = loc("Top.scala":5:5)
#locWide = loc("Top.scala":6:5)

hw.module.extern @Ext(in %a : i8)

hw.module @Child(in %a : i8, in %op : i2, out b : i8) {
  %enum = dbg.enum %op, "Op", {Add = 0 : i2, Sub = 1 : i2} fqn "pkg.Op" : i2
  %op_v = dbg.value %enum typeName "IO[Op]" : !dbg.enum
  %0 = hw.bitcast %a : (i8) -> i8
  %vec = dbg.array [%a, %0] : i8
  %io = dbg.struct {"a": %a, "op": %op_v, "v": %vec} : i8, !dbg.value, !dbg.array<i8>
  %io_v = dbg.value %io typeName "IO[Bundle]" : !dbg.struct<i8, !dbg.value, !dbg.array<i8>>
  dbg.variable "io", %io_v {dbg.port = "in"} : !dbg.value loc(#locIo)
  %r = dbg.value %a typeName "Reg[UInt<8>]" : i8
  dbg.variable "r", %r : !dbg.value loc(#locReg)
  dbg.variable "lost", %0 : i8 loc(#locLost)
  hw.output %a : i8
} loc(fused[#locChild, fused<"verilogLocations">["out.sv":7:1]])

hw.module @Top(in %a : i8, in %op : i2, out b : i8) attributes {dbg.moduleinfo = {typeName = "Top"}} {
  %c5_i8 = hw.constant 5 : i8
  %big = hw.constant -1 : i80
  dbg.variable "k", %c5_i8 : i8 loc(#locK)
  dbg.variable "wide", %big : i80 loc(#locWide)
  %c.b = hw.instance "c" @Child(a: %a: i8, op: %op: i2) -> (b: i8) {dbg.moduleinfo = {params = [{name = "w", typeName = "Int", value = "8"}], typeName = "ChildClass"}, hw.verilogName = "c_0"} loc(#locInst)
  hw.instance "e" @Ext(a: %a: i8) -> ()
  hw.output %c.b : i8
} loc(fused[#locTop, fused<"verilogLocations">["out.sv":12:1]])

// CHECK:      "uhdi": "2.0",
// CHECK-NEXT: "producer": "firtool",
// CHECK-NEXT: "profiles": [
// CHECK-NEXT:   "x-chisel"
// CHECK-NEXT: ],
// CHECK-NEXT: "files": [
// CHECK-NEXT:   {
// CHECK-NEXT:     "path": "Child.scala"
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "path": "Top.scala"
// CHECK-NEXT:   },

// Target files follow the source files in the one list.
// CHECK:            "path": "out.sv",
// CHECK-NEXT:     "target": true
// CHECK-NEXT:   }
// CHECK-NEXT: ],

// Struct fields carry their own type; an enum maps labels to values.
// CHECK:      "types": {
// CHECK-NEXT:   "Child_io": {
// CHECK-NEXT:     "fields": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "name": "a",
// CHECK-NEXT:         "type": "uint8"
// CHECK-NEXT:       },
// CHECK-NEXT:       {
// CHECK-NEXT:         "name": "op",
// CHECK-NEXT:         "type": "pkg.Op"
// CHECK-NEXT:       },
// CHECK-NEXT:       {
// CHECK-NEXT:         "name": "v",
// CHECK-NEXT:         "type": "Child_io_v"
// CHECK-NEXT:       }
// CHECK-NEXT:     ],
// CHECK-NEXT:     "kind": "struct",
// CHECK-NEXT:     "name": "Bundle"
// CHECK-NEXT:   },
// CHECK-NEXT:   "Child_io_v": {
// CHECK-NEXT:     "elem": "uint8",
// CHECK-NEXT:     "kind": "vector",
// CHECK-NEXT:     "size": 2
// CHECK-NEXT:   },
// CHECK-NEXT:   "pkg.Op": {
// CHECK-NEXT:     "base": "uint2",
// CHECK-NEXT:     "kind": "enum",
// CHECK-NEXT:     "name": "Op",
// CHECK-NEXT:     "values": {
// CHECK-NEXT:       "Add": 0,
// CHECK-NEXT:       "Sub": 1
// CHECK-NEXT:     }
// CHECK-NEXT:   },

// The class recorded on the only instance describes the source module. The
// input ports are leaves of `io` and are not repeated; `b` is.
// CHECK:      "source": {
// CHECK-NEXT:   "Child": {
// CHECK-NEXT:     "loc": [
// CHECK-NEXT:       0,
// CHECK-NEXT:       1,
// CHECK-NEXT:       1
// CHECK-NEXT:     ],
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "b": {
// CHECK-NEXT:         "dir": "out",
// CHECK-NEXT:         "type": "uint8"
// CHECK-NEXT:       },
// CHECK-NEXT:       "io": {
// CHECK-NEXT:         "dir": "in",
// CHECK:              "type": "Child_io",
// CHECK-NEXT:         "x-chisel": {
// CHECK-NEXT:           "binding": "IO"
// CHECK-NEXT:         }
// CHECK-NEXT:       },
// CHECK-NEXT:       "lost": {
// CHECK:            "r": {
// CHECK-NOT:          "kind"
// CHECK:                "binding": "Reg"
// CHECK:            "params": [
// CHECK-NEXT:         {
// CHECK-NEXT:           "name": "w",
// CHECK-NEXT:           "type": "Int",
// CHECK-NEXT:           "value": "8"
// CHECK-NEXT:         }
// CHECK-NEXT:       ],
// CHECK-NEXT:       "typeName": "ChildClass"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   "Top": {
// CHECK:          "x-chisel": {
// CHECK-NEXT:       "typeName": "Top"

// An instance is keyed by its Verilog name. An extern module has no source,
// so its instance names none.
// CHECK:      "target": {
// CHECK-NEXT:   "Child": {
// CHECK-NEXT:     "file": [[SV:[0-9]+]]
// CHECK-NEXT:   },
// CHECK-NEXT:   "Ext": {
// CHECK-NEXT:     "kind": "extern"
// CHECK-NEXT:   },
// CHECK-NEXT:   "Top": {
// CHECK-NEXT:     "file": [[SV]],
// CHECK-NEXT:     "inst": {
// CHECK-NEXT:       "c_0": {
// CHECK-NEXT:         "at": [
// CHECK-NEXT:           1,
// CHECK-NEXT:           4,
// CHECK-NEXT:           5
// CHECK-NEXT:         ],
// CHECK-NEXT:         "module": "Child",
// CHECK-NEXT:         "name": "c",
// CHECK-NEXT:         "source": "Child"
// CHECK-NEXT:       },
// CHECK-NEXT:       "e": {
// CHECK-NOT:          "source"
// CHECK:              "module": "Ext"
// CHECK-NEXT:       }

// A struct value is an object, a vector an array. A value optimized away is
// marked as such, in a vector too.
// CHECK:      "bindings": [
// CHECK-NEXT:   {
// CHECK-NEXT:     "source": "Child",
// CHECK-NEXT:     "target": "Child",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "b": "b",
// CHECK-NEXT:       "io": {
// CHECK-NEXT:         "a": "a",
// CHECK-NEXT:         "op": "op",
// CHECK-NEXT:         "v": [
// CHECK-NEXT:           "a",
// CHECK-NEXT:           {
// CHECK-NEXT:             "$none": "optimized"
// CHECK-NEXT:           }
// CHECK-NEXT:         ]
// CHECK-NEXT:       },
// CHECK-NEXT:       "lost": {
// CHECK-NEXT:         "$none": "optimized"
// CHECK-NEXT:       },
// CHECK-NEXT:       "r": "a"
// CHECK-NEXT:     }
// CHECK-NEXT:   },
// CHECK-NEXT:   {
// CHECK-NEXT:     "source": "Top",
// CHECK-NEXT:     "target": "Top",
// CHECK-NEXT:     "vars": {
// CHECK-NEXT:       "a": "a",
// CHECK-NEXT:       "b": "b",
// CHECK-NEXT:       "k": {
// CHECK-NEXT:         "$const": "0b00000101"
// CHECK-NEXT:       },
// CHECK-NEXT:       "op": "op",
// CHECK-NEXT:       "wide": {
// CHECK-NEXT:         "$const": "0b11111111111111111111111111111111111111111111111111111111111111111111111111111111"
// CHECK-NEXT:       }
