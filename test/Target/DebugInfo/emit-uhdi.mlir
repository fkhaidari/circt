// RUN: circt-translate %s --emit-uhdi --uhdi-indent=0 --split-input-file | FileCheck %s

// A module with an unscoped `dbg.moduleinfo` is a source module. Its class
// name and language data go on the module. A variable takes its kind from
// `dbg.variable`.

// CHECK:      {"uhdi":"0.1","producer":"CIRCT {{[^"]*}}","profiles":["x-chisel"]
// CHECK-SAME: "types":[{"kind":"uint","width":8}]
// CHECK-SAME: "original":{"Foo":{"loc":[0,1,1],"name":"Foo","x-chisel":{"params":{"w":8}},"vars":{
// CHECK-SAME: "a":{"type":0,"loc":[0,2,1],"dir":"in"},
// CHECK-SAME: "b":{"type":0,"loc":[0,3,1],"dir":"out"},
// CHECK-SAME: "io":{"type":0,"loc":[0,4,1],"dir":"inout"},
// CHECK-SAME: "r":{"type":0,"loc":[0,5,1],"storage":"reg"},
// CHECK-SAME: "n":{"type":0,"loc":[0,6,1],"node":true},
// CHECK-SAME: "w":{"type":0,"loc":[0,7,1]}}}}
// CHECK-SAME: "generated":{"Foo":{}}
// CHECK-SAME: "bindings":[{"original":"Foo","generated":"Foo","vars":{"a":"a","b":"a","io":"a","r":"a","n":"a","w":"a"}}]
// CHECK-SAME: "files":[{"path":"Foo.scala"}]}
hw.module @Foo(in %a: i8) {
  dbg.moduleinfo "Foo" params ["{\"x-chisel\":{\"params\":{\"w\":8}}}"] loc("Foo.scala":1:1)
  dbg.variable "a", %a kind input : i8 loc("Foo.scala":2:1)
  dbg.variable "b", %a kind output : i8 loc("Foo.scala":3:1)
  dbg.variable "io", %a kind inout : i8 loc("Foo.scala":4:1)
  dbg.variable "r", %a kind reg : i8 loc("Foo.scala":5:1)
  dbg.variable "n", %a kind node : i8 loc("Foo.scala":6:1)
  dbg.variable "w", %a kind wire : i8 loc("Foo.scala":7:1)
} loc("Foo.scala":1:1)

// -----

// A port or a declared signal is named by its `hw.verilogName`, else `name`.

// CHECK:      "bindings":[{"original":"Signals","generated":"Signals","vars":{
// CHECK-SAME: "port":"a","firreg":"r_0","hwwire":"hw_0","svwire":"w_0","svreg":"sr"}}]
hw.module @Signals(in %a: i8, in %clk: !seq.clock) {
  dbg.moduleinfo "Signals"
  dbg.variable "port", %a : i8
  %r = seq.firreg %a clock %clk {hw.verilogName = "r_0"} : i8
  dbg.variable "firreg", %r : i8
  %hw = hw.wire %a {hw.verilogName = "hw_0"} : i8
  dbg.variable "hwwire", %hw : i8
  %w = sv.wire {hw.verilogName = "w_0"} : !hw.inout<i8>
  sv.assign %w, %r : i8
  %w_read = sv.read_inout %w : !hw.inout<i8>
  dbg.variable "svwire", %w_read : i8
  %sr = sv.reg : !hw.inout<i8>
  %sr_read = sv.read_inout %sr : !hw.inout<i8>
  dbg.variable "svreg", %sr_read : i8
} loc("Foo.scala":1:1)

// -----

// A wire that only aliases a port is named by the port, whatever ExportVerilog
// renamed it to: a wire driven by an input port, and a wire read by
// `hw.output`.

// CHECK:      "bindings":[{"original":"Alias","generated":"Alias","vars":{
// CHECK-SAME: "in":"a","out":"b"}}]
hw.module @Alias(in %a: i8, out b: i8) {
  dbg.moduleinfo "Alias"
  %ain = sv.wire {hw.verilogName = "a_0"} : !hw.inout<i8>
  sv.assign %ain, %a : i8
  %ain_read = sv.read_inout %ain : !hw.inout<i8>
  dbg.variable "in", %ain_read kind input : i8
  %c = comb.xor %a, %a : i8
  %bout = sv.wire {hw.verilogName = "b_0"} : !hw.inout<i8>
  sv.assign %bout, %c : i8
  %bout_read = sv.read_inout %bout : !hw.inout<i8>
  dbg.variable "out", %bout_read kind output : i8
  hw.output %bout_read : i8
} loc("Foo.scala":1:1)

// -----

// An output port variable points at the driver of the port. A driver with a
// name of its own is named by it; one without a name is named by the port it
// drives.

// CHECK:      "bindings":[{"original":"Driver","generated":"Driver","vars":{
// CHECK-SAME: "b":"a","c":"c"}}]
hw.module @Driver(in %a: i8, out b: i8, out c: i8) {
  dbg.moduleinfo "Driver"
  dbg.variable "b", %a kind output : i8
  %sum = comb.add %a, %a : i8
  dbg.variable "c", %sum kind output : i8
  hw.output %a, %sum : i8, i8
} loc("Foo.scala":1:1)

// -----

// A constant is its bits, even when it drives an output port. A zero-width
// value has no bits.

// CHECK:      "types":[{"kind":"uint","width":4},{"kind":"uint","width":0}]
// CHECK-SAME: "bindings":[{"original":"Const","generated":"Const","vars":{
// CHECK-SAME: "k":{"$const":"0b0101"},"z":{"$zero_width":true}}}]
hw.module @Const(out k: i4) {
  dbg.moduleinfo "Const"
  %k = hw.constant 5 : i4
  dbg.variable "k", %k kind output : i4
  %z = hw.constant 0 : i0
  dbg.variable "z", %z : i0
  hw.output %k : i4
} loc("Foo.scala":1:1)

// -----

// A packed aggregate is one signal. Its leaves are slices of that signal:
// the first struct field is the most significant, array element 0 the least.
// A bit extract is a slice too. An index that is not a constant selects no
// fixed bits.

// CHECK:      "bindings":[{"original":"Packed","generated":"Packed","vars":{
// CHECK-SAME: "io":{"a":{"$slice":"io","hi":9,"lo":6},
// CHECK-SAME: "b":[{"$slice":"io","hi":2,"lo":0},{"$slice":"io","hi":5,"lo":3}]},
// CHECK-SAME: "ext":{"$slice":"w","hi":6,"lo":3},
// CHECK-SAME: "ext_a":{"$slice":"io","hi":8,"lo":7},
// CHECK-SAME: "dyn":{"$optimized_out":true}}}]
hw.module @Packed(in %io: !hw.struct<a: i4, b: !hw.array<2xi3>>, in %w: i9, in %i: i1) {
  dbg.moduleinfo "Packed"
  %a = hw.struct_extract %io["a"] : !hw.struct<a: i4, b: !hw.array<2xi3>>
  %b = hw.struct_extract %io["b"] : !hw.struct<a: i4, b: !hw.array<2xi3>>
  %false = hw.constant false
  %true = hw.constant true
  %b0 = hw.array_get %b[%false] : !hw.array<2xi3>, i1
  %b1 = hw.array_get %b[%true] : !hw.array<2xi3>, i1
  %bs = dbg.array [%b0, %b1] : i3
  %s = dbg.struct {"a": %a, "b": %bs} : i4, !dbg.array
  dbg.variable "io", %s : !dbg.struct
  %ext = comb.extract %w from 3 : (i9) -> i4
  dbg.variable "ext", %ext : i4
  %ext_a = comb.extract %a from 1 : (i4) -> i2
  dbg.variable "ext_a", %ext_a : i2
  %bi = hw.array_get %b[%i] : !hw.array<2xi3>, i1
  dbg.variable "dyn", %bi : i3
} loc("Foo.scala":1:1)

// -----

// An array port or wire is packed too (ExportVerilog emits `[1:0][2:0]`), so
// a constant index is a slice of it.

// CHECK:      "bindings":[{"original":"Array","generated":"Array","vars":{
// CHECK-SAME: "p1":{"$slice":"p","hi":5,"lo":3},"w0":{"$slice":"w_0","hi":2,"lo":0}}}]
hw.module @Array(in %p: !hw.array<2xi3>) {
  dbg.moduleinfo "Array"
  %false = hw.constant false
  %true = hw.constant true
  %p1 = hw.array_get %p[%true] : !hw.array<2xi3>, i1
  dbg.variable "p1", %p1 : i3
  %w = hw.wire %p {hw.verilogName = "w_0"} : !hw.array<2xi3>
  %w0 = hw.array_get %w[%false] : !hw.array<2xi3>, i1
  dbg.variable "w0", %w0 : i3
} loc("Foo.scala":1:1)

// -----

// An expression with no named signal is optimized out.

// CHECK:      "bindings":[{"original":"Expr","generated":"Expr","vars":{
// CHECK-SAME: "x":{"$optimized_out":true}}}]
hw.module @Expr(in %a: i8, in %b: i8) {
  dbg.moduleinfo "Expr"
  %x = comb.xor %a, %b : i8
  dbg.variable "x", %x : i8
} loc("Foo.scala":1:1)

// -----

// A module without `dbg.moduleinfo` was made by the compiler. Its variables
// and instances are hoisted into the scope that instantiates it, with a path
// relative to that scope's module. A `dbg.scope` without `dbg.moduleinfo` is
// transparent too.

// CHECK:      "original":{"Child":{
// CHECK-SAME: "Top":{"loc":[0,1,1],"name":"Top","vars":{
// CHECK-SAME: "deep":{"type":0,"loc":[0,3,1]},
// CHECK-SAME: "inwhen":{"type":0,"loc":[0,4,1]},
// CHECK-SAME: "c":{"type":1,"loc":[0,5,1]}}}}
// CHECK-SAME: "generated":{"Wrap":{},"Child":{},"Top":{}}
// CHECK-SAME: {"original":"Top","generated":"Top","vars":{
// CHECK-SAME: "deep":"wrap_0.x","inwhen":"in","c":{"$inst":"wrap_0.c","module":"Child"}}}
hw.module private @Wrap(in %x: i8) {
  dbg.variable "deep", %x : i8 loc("Foo.scala":3:1)
  hw.instance "c" @Child(a: %x: i8) -> () {hw.verilogName = "c"} loc("Foo.scala":5:1)
} loc(unknown)
hw.module private @Child(in %a: i8) {
  dbg.moduleinfo "Child" loc(unknown)
  dbg.variable "a", %a : i8 loc(unknown)
} loc(unknown)
hw.module @Top(in %in: i8) {
  dbg.moduleinfo "Top" loc("Foo.scala":1:1)
  hw.instance "wrap" @Wrap(x: %in: i8) -> () {hw.verilogName = "wrap_0"}
  %when = dbg.scope "when", "Top"
  dbg.variable "inwhen", %in scope %when : i8 loc("Foo.scala":4:1)
} loc(unknown)

// -----

// An instance has no scope operand. An instance that an inlined module held
// stays in the module it was inlined into (a v1 gap).

// CHECK:      "original":{"Leaf":{"name":"Leaf","vars":{}},
// CHECK-SAME: "Top":{"name":"Top","vars":{"mid":{"type":0},"leaf":{"type":1}}},
// CHECK-SAME: "Mid":{"name":"Mid","vars":{}}}
// CHECK-SAME: {"original":"Top","generated":"Top","vars":{
// CHECK-SAME: "mid":{"$inline":["mid"]},"leaf":{"$inst":"mid_leaf","module":"Leaf"}}}
hw.module private @Leaf() {
  dbg.moduleinfo "Leaf" loc(unknown)
} loc(unknown)
hw.module @Top() {
  dbg.moduleinfo "Top" loc(unknown)
  %mid = dbg.scope "mid", "Mid" loc(unknown)
  dbg.moduleinfo "Mid" scope %mid loc(unknown)
  hw.instance "leaf" @Leaf() -> () {hw.verilogName = "mid_leaf"} loc(unknown)
} loc(unknown)

// -----

// A layer module is transparent and its bind instance is not a scope. An XMR
// read is followed to its target: a signal of the scope's module is named
// locally, and a signal of the layer module through the bind instance.

// CHECK:      {"original":"Top","generated":"Top","vars":{
// CHECK-SAME: "lv":"in","lx":"w_0","lw":"verif.lw"}}
hw.hierpath private @xmr_in [@Top::@sym_in]
hw.hierpath private @xmr_w [@Top::@sym_w]
hw.module private @Top_Verif() {
  %0 = sv.xmr.ref @xmr_in : !hw.inout<i8>
  %1 = sv.read_inout %0 : !hw.inout<i8>
  dbg.variable "lv", %1 : i8
  %2 = sv.xmr.ref @xmr_w : !hw.inout<i8>
  %3 = sv.read_inout %2 : !hw.inout<i8>
  dbg.variable "lx", %3 : i8
  %lw = sv.wire {hw.verilogName = "lw"} : !hw.inout<i8>
  sv.assign %lw, %3 : i8
  %lw_read = sv.read_inout %lw : !hw.inout<i8>
  dbg.variable "lw", %lw_read : i8
}
hw.module @Top(in %in: i8 {hw.exportPort = #hw<innerSym@sym_in>}) {
  dbg.moduleinfo "Top"
  %w = sv.wire sym @sym_w {hw.verilogName = "w_0"} : !hw.inout<i8>
  sv.assign %w, %in : i8
  hw.instance "verif" @Top_Verif() -> () {doNotPrint, hw.verilogName = "verif"}
} loc("Foo.scala":1:1)

// -----

// An inlined module is a `dbg.scope`. Its class is the `dbg.moduleinfo` in
// that scope, not the scope's module name. Equal inlined copies share one
// entry in `original`; a copy that differs gets a new key.

// CHECK:      "types":[{"kind":"uint","width":8},
// CHECK-SAME: {"kind":"module","module":"Inl","name":"Cls","x-chisel":{"params":{"n":1}}},
// CHECK-SAME: {"kind":"module","module":"Inl_1","name":"Cls","x-chisel":{"params":{"n":2}}}]
// CHECK-SAME: "original":{"Top":{"loc":[0,1,1],"name":"Top","vars":{
// CHECK-SAME: "i1":{"type":1,"loc":[0,2,1]},"i2":{"type":1,"loc":[0,3,1]},"i3":{"type":2,"loc":[0,4,1]}}}
// CHECK-SAME: "Inl":{"loc":[0,5,1],"name":"Cls","x-chisel":{"params":{"n":1}},"vars":{"st":{"type":0,"loc":[0,6,1]}}}
// CHECK-SAME: "Inl_1":{"loc":[0,5,1],"name":"Cls","x-chisel":{"params":{"n":2}},"vars":{"st":{"type":0,"loc":[0,6,1]}}}}
// CHECK-SAME: "generated":{"Top":{}}
// CHECK-SAME: "bindings":[{"original":"Top","generated":"Top","vars":{"i1":{"$inline":["i1"]},"i2":{"$inline":["i2"]},"i3":{"$inline":["i3"]}}},
// CHECK-SAME: {"original":"Inl","generated":"Top","inline_path":["i1"],"vars":{"st":"a"}},
// CHECK-SAME: {"original":"Inl","generated":"Top","inline_path":["i2"],"vars":{"st":"b"}},
// CHECK-SAME: {"original":"Inl_1","generated":"Top","inline_path":["i3"],"vars":{"st":"a"}}]
hw.module @Top(in %a: i8, in %b: i8) {
  dbg.moduleinfo "Top" loc("Foo.scala":1:1)
  %i1 = dbg.scope "i1", "Inl" loc("Foo.scala":2:1)
  dbg.moduleinfo "Cls" params ["{\"x-chisel\":{\"params\":{\"n\":1}}}"] scope %i1 loc("Foo.scala":5:1)
  dbg.variable "st", %a scope %i1 : i8 loc("Foo.scala":6:1)
  %i2 = dbg.scope "i2", "Inl" loc("Foo.scala":3:1)
  dbg.moduleinfo "Cls" params ["{\"x-chisel\":{\"params\":{\"n\":1}}}"] scope %i2 loc("Foo.scala":5:1)
  dbg.variable "st", %b scope %i2 : i8 loc("Foo.scala":6:1)
  %i3 = dbg.scope "i3", "Inl" loc("Foo.scala":4:1)
  dbg.moduleinfo "Cls" params ["{\"x-chisel\":{\"params\":{\"n\":2}}}"] scope %i3 loc("Foo.scala":5:1)
  dbg.variable "st", %a scope %i3 : i8 loc("Foo.scala":6:1)
} loc(unknown)

// -----

// Types are interned by shape. Two types with one name and different shapes
// are two types. A type that only gets a name does not stay in the table.
// Flips go on struct fields.

// CHECK:      "types":[{"kind":"uint","width":8},
// CHECK-SAME: {"fields":[{"name":"d","type":0}],"kind":"struct","name":"AluIO","x-chisel":{"params":{"w":8}}},
// CHECK-SAME: {"kind":"uint","width":16},
// CHECK-SAME: {"fields":[{"name":"d","type":2}],"kind":"struct","name":"AluIO","x-chisel":{"params":{"w":16}}},
// CHECK-SAME: {"kind":"uint","width":4},
// CHECK-SAME: {"fields":[{"name":"x","type":4},{"flip":true,"name":"y","type":0}],"kind":"struct"},
// CHECK-SAME: {"kind":"uint","width":2},
// CHECK-SAME: {"base":6,"kind":"enum","name":"Op","values":{"Add":0,"Sub":1}}]
// CHECK-SAME: "vars":{"io8":{"type":1},"io16":{"type":3},"flipped":{"type":5},"op":{"type":7}}
// CHECK-SAME: "vars":{"io8":{"d":"x"},"io16":{"d":"y"},"flipped":{"x":"z","y":"x"},"op":"e"}
hw.module @Types(in %x: i8, in %y: i16, in %z: i4, in %e: i2) {
  dbg.moduleinfo "Types" loc(unknown)
  %s8 = dbg.struct {"d": %x} : i8
  %io8 = dbg.value %s8 typeName "AluIO" params ["{\"x-chisel\":{\"params\":{\"w\":8}}}"] : !dbg.struct
  dbg.variable "io8", %io8 : !dbg.value loc(unknown)
  %s16 = dbg.struct {"d": %y} : i16
  %io16 = dbg.value %s16 typeName "AluIO" params ["{\"x-chisel\":{\"params\":{\"w\":16}}}"] : !dbg.struct
  dbg.variable "io16", %io16 : !dbg.value loc(unknown)
  %f = dbg.struct {"x": %z, "y": %x} {flips = array<i1: false, true>} : i4, i8
  dbg.variable "flipped", %f : !dbg.struct loc(unknown)
  %en = dbg.enum %e, "Op", {Add = 0 : i2, Sub = 1 : i2} fqn "a.Op" : i2
  dbg.variable "op", %en : !dbg.enum loc(unknown)
} loc(unknown)

// -----

// A variable key is unique in its module and has none of `.`, `[`, `]`. A key
// that differs from the declared name is accompanied by `name`. A variable of
// a type that cannot be shown is left out with a warning (see
// emit-uhdi-errors.mlir).

// CHECK:      "vars":{"x":{"type":0},"x_1":{"name":"x","type":0},"a_b_c_":{"name":"a.b[c]","type":0}}
// CHECK-SAME: "vars":{"x":"a","x_1":"a","a_b_c_":"a"}
hw.module @Keys(in %a: i8) {
  dbg.moduleinfo "Keys" loc(unknown)
  dbg.variable "x", %a : i8 loc(unknown)
  dbg.variable "x", %a : i8 loc(unknown)
  dbg.variable "a.b[c]", %a : i8 loc(unknown)
} loc(unknown)

// -----

// A module that nothing instantiates is a scope even without
// `dbg.moduleinfo`, but it has no class. An external module is kept as an
// instance and gets its ports as variables. Each `instance_choice` alternative
// is its own instance.

// CHECK:      "types":[{"kind":"uint","width":8},{"kind":"module","module":"BB"},{"kind":"module","module":"Opt","name":"Opt"}]
// CHECK-SAME: "original":{"BB":{"vars":{"p":{"type":0,"dir":"in"},"q":{"type":0,"dir":"out"}}},
// CHECK-SAME: "Opt":{"name":"Opt","vars":{}},
// CHECK-SAME: "Root":{"vars":{"bb":{"type":1},"opt_a":{"type":2},"opt_b":{"type":2}}}}
// CHECK-SAME: "generated":{"BlackBox":{"kind":"extern"},"Opt":{},"Root":{}}
// CHECK-SAME: "bindings":[{"original":"BB","generated":"BlackBox","vars":{"p":"p","q":"q"}},
// CHECK-SAME: {"original":"Opt","generated":"Opt","vars":{}},
// CHECK-SAME: {"original":"Root","generated":"Root","vars":{"bb":{"$inst":"bb","module":"BlackBox"},
// CHECK-SAME: "opt_a":{"$inst":"opt_a","module":"Opt"},"opt_b":{"$inst":"opt_b","module":"Opt"}}}]
hw.module.extern @BB(in %p: i8 loc(unknown), out q: i8 loc(unknown)) attributes {verilogName = "BlackBox"} loc(unknown)
hw.module private @Opt(in %a: i8) {
  dbg.moduleinfo "Opt" loc(unknown)
} loc(unknown)
sv.macro.decl @A
hw.module @Root(in %a: i8) {
  %bb.q = hw.instance "bb" @BB(p: %a: i8) -> (q: i8) loc(unknown)
  sv.ifdef @A {
    hw.instance "opt_a" @Opt(a: %a: i8) -> () loc(unknown)
  } else {
    hw.instance "opt_b" @Opt(a: %a: i8) -> () loc(unknown)
  }
} loc(unknown)

// -----

// A value that CSE shares is walked once and shown at each use: an array used
// as several elements of another, and a struct field that is also a field of
// a sibling field.

// CHECK:      "types":[{"kind":"uint","width":2},
// CHECK-SAME: {"elem":0,"kind":"vector","size":2},
// CHECK-SAME: {"elem":1,"kind":"vector","size":3},
// CHECK-SAME: {"fields":[{"name":"x","type":1}],"kind":"struct"},
// CHECK-SAME: {"fields":[{"name":"a","type":3},{"name":"b","type":1}],"kind":"struct"}]
// CHECK-SAME: "vars":{"outer":{"type":2},"sp":{"type":4}}
// CHECK-SAME: "vars":{
// CHECK-SAME: "outer":{{\[\[}}"a",{"$const":"0b01"}],["a",{"$const":"0b01"}],["a",{"$const":"0b01"}]],
// CHECK-SAME: "sp":{"a":{"x":["a",{"$const":"0b01"}]},"b":["a",{"$const":"0b01"}]}}
hw.module @Shared(in %a: i2) {
  dbg.moduleinfo "Shared" loc(unknown)
  %c = hw.constant 1 : i2
  %inner = dbg.array [%a, %c] : i2
  %outer = dbg.array [%inner, %inner, %inner] : !dbg.array
  dbg.variable "outer", %outer : !dbg.array loc(unknown)
  %sa = dbg.struct {"x": %inner} : !dbg.array
  %sp = dbg.struct {"a": %sa, "b": %inner} : !dbg.struct, !dbg.array
  dbg.variable "sp", %sp : !dbg.struct loc(unknown)
} loc(unknown)

// -----

// Several `x-` keys in one `params` are copied as they are, and each one is
// listed in `profiles`, sorted.

// CHECK:      "profiles":["x-chisel","x-scala"]
// CHECK-SAME: "name":"Multi","x-chisel":{"a":1},"x-scala":{"b":2}
hw.module @Multi(in %a: i2) {
  dbg.moduleinfo "Multi" params ["{\"x-scala\":{\"b\":2},\"x-chisel\":{\"a\":1}}"] loc(unknown)
  dbg.variable "a", %a kind input : i2 loc(unknown)
} loc(unknown)
