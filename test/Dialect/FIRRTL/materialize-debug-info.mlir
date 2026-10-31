// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-materialize-debug-info)))' %s | FileCheck %s

firrtl.circuit "Ports" {

// CHECK-LABEL: firrtl.module @Ports
firrtl.module @Ports(
  in %inA: !firrtl.uint<42>,
  in %inB: !firrtl.bundle<a: sint<19>, b: clock>,
  in %inC: !firrtl.vector<asyncreset, 2>,
  in %inD: !firrtl.bundle<clocks: vector<clock, 4>>,
  out %outA: !firrtl.uint<42>,
  out %pad: !firrtl.analog<1>,
  out %fl: !firrtl.bundle<x: uint<1>, y flip: uint<1>>
) {
  // CHECK-NEXT: dbg.variable "inA", %inA dir in :

  // CHECK-NEXT: [[TMP0:%.+]] = firrtl.subfield %inB[a]
  // CHECK-NEXT: [[VAL0:%.+]] = dbg.value [[TMP0]] sint
  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subfield %inB[b]
  // CHECK-NEXT: [[VAL1:%.+]] = dbg.value [[TMP1]] clock
  // CHECK-NEXT: [[TMP:%.+]] = dbg.struct {"a": [[VAL0]], "b": [[VAL1]]}
  // CHECK-NEXT: dbg.variable "inB", [[TMP]] dir in :

  // CHECK-NEXT: [[TMP0:%.+]] = firrtl.subindex %inC[0]
  // CHECK-NEXT: [[VAL0:%.+]] = dbg.value [[TMP0]] asyncreset
  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subindex %inC[1]
  // CHECK-NEXT: [[VAL1:%.+]] = dbg.value [[TMP1]] asyncreset
  // CHECK-NEXT: [[TMP:%.+]] = dbg.array [[[VAL0]], [[VAL1]]]
  // CHECK-NEXT: dbg.variable "inC", [[TMP]] dir in :

  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subfield %inD[clocks]
  // CHECK-NEXT: [[TMP2:%.+]] = firrtl.subindex [[TMP1]][0]
  // CHECK-NEXT: [[VAL2:%.+]] = dbg.value [[TMP2]] clock
  // CHECK-NEXT: [[TMP3:%.+]] = firrtl.subindex [[TMP1]][1]
  // CHECK-NEXT: [[VAL3:%.+]] = dbg.value [[TMP3]] clock
  // CHECK-NEXT: [[TMP4:%.+]] = firrtl.subindex [[TMP1]][2]
  // CHECK-NEXT: [[VAL4:%.+]] = dbg.value [[TMP4]] clock
  // CHECK-NEXT: [[TMP5:%.+]] = firrtl.subindex [[TMP1]][3]
  // CHECK-NEXT: [[VAL5:%.+]] = dbg.value [[TMP5]] clock
  // CHECK-NEXT: [[TMP6:%.+]] = dbg.array [[[VAL2]], [[VAL3]], [[VAL4]], [[VAL5]]]
  // CHECK-NEXT: [[TMP7:%.+]] = dbg.struct {"clocks": [[TMP6]]}
  // CHECK-NEXT: dbg.variable "inD", [[TMP7]] dir in :

  // CHECK-NEXT: dbg.variable "outA", %outA dir out :
  // CHECK-NEXT: dbg.variable "pad", %pad dir inout :

  // A flipped field is marked in `flips`.
  // CHECK-NEXT: [[TMP0:%.+]] = firrtl.subfield %fl[x]
  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subfield %fl[y]
  // CHECK-NEXT: [[TMP:%.+]] = dbg.struct {"x": [[TMP0]], "y": [[TMP1]]} {flips = array<i1: false, true>}
  // CHECK-NEXT: dbg.variable "fl", [[TMP]] dir out :

  // CHECK-NEXT: firrtl.matchingconnect
  firrtl.matchingconnect %outA, %inA : !firrtl.uint<42>
}

// CHECK-LABEL: firrtl.module @Decls
firrtl.module @Decls() {
  // CHECK-NEXT: firrtl.constant
  // CHECK-NEXT: firrtl.constant
  // CHECK-NEXT: firrtl.specialconstant
  %c0_ui1 = firrtl.constant 0 : !firrtl.uint<1>
  %c0_ui17 = firrtl.constant 0 : !firrtl.uint<17>
  %c0_clock = firrtl.specialconstant 0 : !firrtl.clock

  // CHECK-NEXT: firrtl.wire
  // CHECK-NEXT: dbg.variable "someWire", %someWire
  %someWire = firrtl.wire : !firrtl.uint<17>

  // CHECK-NEXT: firrtl.node
  // CHECK-NEXT: dbg.variable "someNode", %someNode node
  %someNode = firrtl.node %c0_ui17 : !firrtl.uint<17>

  // CHECK-NEXT: firrtl.reg
  // CHECK-NEXT: dbg.variable "someReg1", %someReg1 reg
  %someReg1 = firrtl.reg %c0_clock : !firrtl.clock, !firrtl.uint<17>

  // CHECK-NEXT: firrtl.regreset
  // CHECK-NEXT: dbg.variable "someReg2", %someReg2 reg
  %someReg2 = firrtl.regreset %c0_clock, %c0_ui1, %c0_ui17 : !firrtl.clock, !firrtl.uint<1>, !firrtl.uint<17>, !firrtl.uint<17>

  // CHECK-NEXT: firrtl.matchingconnect
  firrtl.matchingconnect %someWire, %c0_ui17 : !firrtl.uint<17>
}

// An instance gets a scope that describes it by name.
// CHECK-LABEL: firrtl.module @Instances
firrtl.module @Instances(in %c: !firrtl.uint<1>) {
  // CHECK-NEXT: dbg.variable "c", %c
  // CHECK-NEXT: dbg.instance "child", "Decls"
  // CHECK-NEXT: firrtl.instance child @Decls()
  firrtl.instance child @Decls()
  // CHECK-NEXT: firrtl.when
  firrtl.when %c : !firrtl.uint<1> {
    // CHECK-NEXT: dbg.instance "other", "Decls"
    // CHECK-NEXT: firrtl.instance other @Decls()
    firrtl.instance other @Decls()
  }
}

// A memory gets an instance scope whose module lowering fills in.
// CHECK-LABEL: firrtl.module @Memories
firrtl.module @Memories() {
  // CHECK-NEXT: dbg.instance "cmem"
  // CHECK-NEXT: chirrtl.combmem
  %cmem = chirrtl.combmem : !chirrtl.cmemory<uint<1>, 2>
  // CHECK-NEXT: dbg.instance "smem"
  // CHECK-NEXT: chirrtl.seqmem
  %smem = chirrtl.seqmem Undefined : !chirrtl.cmemory<uint<1>, 2>
  // CHECK-NEXT: dbg.instance "mem"
  // CHECK-NEXT: firrtl.mem
  %mem_r = firrtl.mem Undefined {depth = 2 : i64, name = "mem", portNames = ["r"], readLatency = 0 : i32, writeLatency = 1 : i32} : !firrtl.bundle<addr: uint<1>, en: uint<1>, clk: clock, data flip: uint<1>>
}

// `circt_debug_type` and `circt_debug_enum` give a node of a declaration a
// source type name, language data or enum variants. The pass consumes them.

firrtl.layer @A bind {}

// CHECK-LABEL: firrtl.module @Meta
// CHECK-NOT:     firrtl.int.generic
firrtl.module @Meta(
  in %io: !firrtl.bundle<a: uint<8>, ok: uint<1>, st flip: uint<2>>,
  in %n: !firrtl.sint<4>,
  in %clk: !firrtl.clock,
  in %v: !firrtl.vector<vector<bundle<x: uint<1>>, 2>, 1>,
  in %c: !firrtl.uint<1>
) {
  // An intrinsic may come before the declaration it targets, or sit in a
  // `when` or a layer.
  firrtl.int.generic "circt_debug_type" <target: none = "w", name: none = "Bool"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "io", name: none = "MyBundle", ext_chisel: none = "{\"w\":8}", ext_other: none = "null"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "io", path: none = ".ok", name: none = "Bool"> : () -> ()
  firrtl.int.generic "circt_debug_enum" <target: none = "io", path: none = ".st", name: none = "State", variant_Idle: ui32 = 0, variant_Run: ui32 = 1> : () -> ()
  // A kind keeps its op and gets the name.
  firrtl.int.generic "circt_debug_type" <target: none = "n", name: none = "SInt<4>"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "clk", name: none = "Clock"> : () -> ()
  // `[*]` names every element.
  firrtl.int.generic "circt_debug_type" <target: none = "v", path: none = "[*][*]", name: none = "E"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "v", path: none = "[*][*].x", name: none = "Bool"> : () -> ()

  // CHECK:      [[OK:%.+]] = dbg.value %{{.+}} typeName "Bool"
  // CHECK:      [[ST:%.+]] = dbg.enum %{{.+}}, "State", {Idle = 0 : i64, Run = 1 : i64} :
  // CHECK:      [[S:%.+]] = dbg.struct {"a": %{{.+}}, "ok": [[OK]], "st": [[ST]]}
  // CHECK-NEXT: [[IO:%.+]] = dbg.value [[S]] typeName "MyBundle" ext {chisel = "{\22w\22:8}", other = "null"} : !dbg.struct
  // CHECK-NEXT: dbg.variable "io", [[IO]]

  // CHECK:      [[N:%.+]] = dbg.value %n typeName "SInt<4>" sint
  // CHECK-NEXT: dbg.variable "n", [[N]]
  // CHECK:      [[CLK:%.+]] = dbg.value %clk typeName "Clock" clock
  // CHECK-NEXT: dbg.variable "clk", [[CLK]]

  // CHECK:      [[X:%.+]] = dbg.value %{{.+}} typeName "Bool"
  // CHECK-NEXT: [[E0:%.+]] = dbg.struct {"x": [[X]]}
  // CHECK-NEXT: dbg.value [[E0]] typeName "E"
  // CHECK:      dbg.value %{{.+}} typeName "Bool"
  // CHECK:      dbg.value %{{.+}} typeName "E"
  // CHECK-NEXT: [[INNER:%.+]] = dbg.array
  // CHECK-NEXT: [[OUTER:%.+]] = dbg.array {{\[}}[[INNER]]]
  // CHECK-NEXT: dbg.variable "v", [[OUTER]]

  // CHECK:      dbg.variable "c", %c
  firrtl.when %c : !firrtl.uint<1> {
    // CHECK:      [[W:%.+]] = dbg.value %w typeName "Bool"
    // CHECK-NEXT: dbg.variable "w", [[W]]
    %w = firrtl.wire : !firrtl.uint<1>
  }
  firrtl.layerblock @A {
    firrtl.int.generic "circt_debug_enum" <target: none = "e", name: none = "S", variant_A: ui32 = 0> : () -> ()
    // CHECK: [[E:%.+]] = dbg.enum %e, "S", {A = 0 : i64}
    // CHECK-NEXT: dbg.variable "e", [[E]]
    %e = firrtl.wire : !firrtl.uint<1>
  }
}

// Metadata on a node the pass does not describe is dropped without leaving a
// debug op behind: an unnamed declaration, a memory.

// CHECK-LABEL: firrtl.module @Dropped
// CHECK-NOT:     firrtl.int.generic
// CHECK-NOT:     typeName
firrtl.module @Dropped(in %clock: !firrtl.clock) {
  firrtl.int.generic "circt_debug_type" <target: none = "_t", name: none = "Bool"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "mem", ext_chisel: none = "{}"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "mem", path: none = ".x", name: none = "Bool"> : () -> ()
  %_t = firrtl.wire : !firrtl.uint<1>
  %mem = chirrtl.combmem : !chirrtl.cmemory<uint<8>, 4>
}


// `circt_debug_type` on an instance gives it the class its module was
// elaborated from. Without a target the record is for the module itself.
// CHECK-LABEL: firrtl.module @Classes
// CHECK-SAME: attributes {dbg.moduleinfo = {ext = {chisel = "[]"}, name = "Top"}}
firrtl.module @Classes() {
  // CHECK-NEXT: dbg.instance "c0", "Decls" typeName "Child" ext {chisel = "{\22w\22:8}"}
  // CHECK-NEXT: firrtl.instance c0 @Decls()
  // CHECK-NEXT: dbg.instance "c1", "Decls"{{$}}
  // CHECK-NEXT: firrtl.instance c1 @Decls()
  firrtl.int.generic "circt_debug_type" <name: none = "Top", ext_chisel: none = "[]"> : () -> ()
  firrtl.int.generic "circt_debug_type" <target: none = "c0", name: none = "Child", ext_chisel: none = "{\"w\":8}"> : () -> ()
  firrtl.instance c0 @Decls()
  firrtl.instance c1 @Decls()
}

}
