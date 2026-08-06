// RUN: circt-opt --firrtl-lower-types %s | FileCheck %s

// Nothing else covers debug operations through type lowering, and the UHDI
// reference model depends on what happens here: an aggregate is scalarised into
// `_`-joined names in which a field and an index cannot be told apart, so the
// `dbg.struct` built beforehand is the only thing that still knows the source
// shape. Lowering must rewire its leaves onto the split scalars and leave the
// names alone.

firrtl.circuit "Top" {
  firrtl.module private @Child(in %in: !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>,
                               out %out: !firrtl.uint<1>) {
    %0 = firrtl.subfield %in[a] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    firrtl.matchingconnect %out, %0 : !firrtl.uint<1>
  }

  // CHECK-LABEL: firrtl.module @Top
  firrtl.module @Top(in %x: !firrtl.uint<1>) {
    // The instance's ports are split, one result per leaf.
    // CHECK: %[[IN_A:.+]], %[[IN_B0:.+]], %[[IN_B1:.+]], %[[OUT:.+]] = firrtl.instance c
    %c_in, %c_out = firrtl.instance c @Child(
      in in: !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>,
      out out: !firrtl.uint<1>)

    %in_a = firrtl.subfield %c_in[a] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    %in_b = firrtl.subfield %c_in[b] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    %in_b0 = firrtl.subindex %in_b[0] : !firrtl.vector<uint<1>, 2>
    %in_b1 = firrtl.subindex %in_b[1] : !firrtl.vector<uint<1>, 2>

    // The debug aggregate keeps its field names and now points at the scalars.
    // CHECK: %[[ARR:.+]] = dbg.array [%[[IN_B0]], %[[IN_B1]]]
    // CHECK: %[[INS:.+]] = dbg.struct {"a": %[[IN_A]], "b": %[[ARR]]}
    // CHECK: %[[ST:.+]] = dbg.struct {"in": %[[INS]], "out": %[[OUT]]}
    // CHECK: dbg.variable "c", %[[ST]] {uhdi.instance_view}
    %arr = dbg.array [%in_b0, %in_b1] : !firrtl.uint<1>
    %ins = dbg.struct {"a": %in_a, "b": %arr} : !firrtl.uint<1>, !dbg.array
    %st = dbg.struct {"in": %ins, "out": %c_out} : !dbg.struct, !firrtl.uint<1>
    dbg.variable "c", %st {uhdi.instance_view} : !dbg.struct

    firrtl.matchingconnect %in_a, %x : !firrtl.uint<1>
    firrtl.matchingconnect %in_b0, %x : !firrtl.uint<1>
    firrtl.matchingconnect %in_b1, %x : !firrtl.uint<1>
  }
}
