// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-materialize-debug-info)))' --verify-diagnostics %s | FileCheck %s

firrtl.circuit "Ports" {

// CHECK-LABEL: firrtl.module @Ports
firrtl.module @Ports(
  in %inA: !firrtl.uint<42>,
  in %inB: !firrtl.bundle<a: sint<19>, b: clock>,
  in %inC: !firrtl.vector<asyncreset, 2>,
  in %inD: !firrtl.bundle<clocks: vector<clock, 4>>,
  out %outA: !firrtl.uint<42>
) {
  // CHECK-NEXT: dbg.variable "inA", %inA kind input

  // CHECK-NEXT: [[TMP0:%.+]] = firrtl.subfield %inB[a]
  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subfield %inB[b]
  // CHECK-NEXT: [[TMP:%.+]] = dbg.struct {"a": [[TMP0]], "b": [[TMP1]]}
  // CHECK-NEXT: dbg.variable "inB", [[TMP]]

  // CHECK-NEXT: [[TMP0:%.+]] = firrtl.subindex %inC[0]
  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subindex %inC[1]
  // CHECK-NEXT: [[TMP:%.+]] = dbg.array [[[TMP0]], [[TMP1]]]
  // CHECK-NEXT: dbg.variable "inC", [[TMP]]

  // CHECK-NEXT: [[TMP1:%.+]] = firrtl.subfield %inD[clocks]
  // CHECK-NEXT: [[TMP2:%.+]] = firrtl.subindex [[TMP1]][0]
  // CHECK-NEXT: [[TMP3:%.+]] = firrtl.subindex [[TMP1]][1]
  // CHECK-NEXT: [[TMP4:%.+]] = firrtl.subindex [[TMP1]][2]
  // CHECK-NEXT: [[TMP5:%.+]] = firrtl.subindex [[TMP1]][3]
  // CHECK-NEXT: [[TMP6:%.+]] = dbg.array [[[TMP2]], [[TMP3]], [[TMP4]], [[TMP5]]]
  // CHECK-NEXT: [[TMP7:%.+]] = dbg.struct {"clocks": [[TMP6]]}
  // CHECK-NEXT: dbg.variable "inD", [[TMP7]]

  // CHECK-NEXT: dbg.variable "outA", %outA kind output

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
  // CHECK-NEXT: dbg.variable "someWire", %someWire kind wire
  %someWire = firrtl.wire : !firrtl.uint<17>

  // CHECK-NEXT: firrtl.node
  // CHECK-NEXT: dbg.variable "someNode", %someNode kind node
  %someNode = firrtl.node %c0_ui17 : !firrtl.uint<17>

  // CHECK-NEXT: firrtl.reg
  // CHECK-NEXT: dbg.variable "someReg1", %someReg1 kind reg
  %someReg1 = firrtl.reg %c0_clock : !firrtl.clock, !firrtl.uint<17>

  // CHECK-NEXT: firrtl.regreset
  // CHECK-NEXT: dbg.variable "someReg2", %someReg2 kind reg
  %someReg2 = firrtl.regreset %c0_clock, %c0_ui1, %c0_ui17 : !firrtl.clock, !firrtl.uint<1>, !firrtl.uint<17>, !firrtl.uint<17>

  // CHECK-NEXT: firrtl.matchingconnect
  firrtl.matchingconnect %someWire, %c0_ui17 : !firrtl.uint<17>
}


// CHECK-LABEL: firrtl.module @KindsAndFlips
firrtl.module @KindsAndFlips(
  in %a: !firrtl.analog<1>,
  out %b: !firrtl.bundle<x: uint<1>, y flip: uint<2>>
) {
  // CHECK-NEXT: dbg.variable "a", %a kind inout
  // CHECK-NEXT: [[X:%.+]] = firrtl.subfield %b[x]
  // CHECK-NEXT: [[Y:%.+]] = firrtl.subfield %b[y]
  // CHECK-NEXT: [[S:%.+]] = dbg.struct {"x": [[X]], "y": [[Y]]} {flips = array<i1: false, true>}
  // CHECK-NEXT: dbg.variable "b", [[S]] kind output
  // CHECK-NEXT: firrtl.wire
  // CHECK-NEXT: firrtl.wire
  // CHECK-NEXT: [[A:%.+]] = firrtl.subfield %w[a]
  // CHECK-NEXT: [[S:%.+]] = dbg.struct {"a": [[A]]} :
  // CHECK-NEXT: dbg.variable "w", [[S]] kind wire

  // One warning per root, naming it, however many enums it holds.
  // expected-warning @below {{'e' has enum-typed values without debug info; FIRRTL enums are not supported}}
  %e = firrtl.wire : !firrtl.enum<A: uint<0>, B: uint<0>>
  // expected-warning @below {{'w' has enum-typed values without debug info; FIRRTL enums are not supported}}
  %w = firrtl.wire : !firrtl.bundle<a: uint<1>, e: enum<A: uint<0>, B: uint<0>>, f: enum<A: uint<0>, B: uint<0>>>
}

// Roots that existing Debug ops describe get no second variable. A root they
// describe only in part, like %p, gets none for the rest either: a frontend
// that describes a declaration describes all of it.
// CHECK-LABEL: firrtl.module @Described
firrtl.module @Described(
  in %p: !firrtl.bundle<a: uint<1>, b: uint<1>>,
  in %q: !firrtl.uint<1>
) {
  // CHECK-NEXT: dbg.variable "q", %q kind input
  // CHECK-NEXT: firrtl.subfield %p[a]
  // CHECK-NEXT: dbg.value
  // CHECK-NEXT: dbg.variable "p", {{%.+}} : !dbg.value
  // CHECK-NEXT: firrtl.wire
  // CHECK-NEXT: dbg.variable "w", %w : !firrtl.uint<1>
  // CHECK-NEXT: firrtl.node
  // CHECK-NEXT: dbg.variable "n", %n kind node
  %0 = firrtl.subfield %p[a] : !firrtl.bundle<a: uint<1>, b: uint<1>>
  %1 = dbg.value %0 : !firrtl.uint<1>
  dbg.variable "p", %1 : !dbg.value
  %w = firrtl.wire : !firrtl.uint<1>
  dbg.variable "w", %w : !firrtl.uint<1>
  %n = firrtl.node %q : !firrtl.uint<1>
}

}
