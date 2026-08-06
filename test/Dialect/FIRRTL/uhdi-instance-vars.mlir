// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-uhdi-instance-vars)))' %s | FileCheck %s

// An instance's ports have nothing describing them from the parent side, so a
// statement connecting to `c.a` has nothing to point at. Describe them here,
// while the aggregate structure is still visible: LowerFIRRTLTypes has not run
// yet, so field and element names are still distinguishable.

firrtl.circuit "Top" {
  firrtl.module private @Child(in %in: !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>,
                               in %unused: !firrtl.uint<1>,
                               out %out: !firrtl.uint<1>) {
    %0 = firrtl.subfield %in[a] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    firrtl.matchingconnect %out, %0 : !firrtl.uint<1>
  }

  // CHECK-LABEL: firrtl.module @Top
  firrtl.module @Top(in %x: !firrtl.uint<1>, out %y: !firrtl.uint<1>) {
    %c_in, %c_unused, %c_out = firrtl.instance c @Child(
      in in: !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>,
      in unused: !firrtl.uint<1>,
      out out: !firrtl.uint<1>)

    // The aggregate port keeps its source shape: a struct with the field names
    // and an array for the vector.
    // CHECK:      %[[B0:.+]] = firrtl.subindex %{{.+}}[0]
    // CHECK:      %[[B1:.+]] = firrtl.subindex %{{.+}}[1]
    // CHECK:      %[[ARR:.+]] = dbg.array [%[[B0]], %[[B1]]]
    // CHECK:      %[[IN:.+]] = dbg.struct {"a": %{{.+}}, "b": %[[ARR]]}
    // CHECK:      %[[ST:.+]] = dbg.struct {"in": %[[IN]], "out": %{{.+}}}
    // CHECK-NEXT: dbg.variable "c", %[[ST]] {uhdi.instance_view}

    // `unused` is connected to nothing, so it is left out: no statement could
    // name it, and a debug operand would keep the port alive.
    // CHECK-NOT: "unused"

    %0 = firrtl.subfield %c_in[a] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    firrtl.matchingconnect %0, %x : !firrtl.uint<1>
    firrtl.matchingconnect %y, %c_out : !firrtl.uint<1>
  }
}

// -----

// Re-running must not produce a second variable, and an instance whose name is
// already taken by a real variable is left alone.

firrtl.circuit "Taken" {
  firrtl.module private @Child(out %out: !firrtl.uint<1>) {
    %w = firrtl.wire : !firrtl.uint<1>
    firrtl.matchingconnect %out, %w : !firrtl.uint<1>
  }
  // CHECK-LABEL: firrtl.module @Taken
  firrtl.module @Taken(out %y: !firrtl.uint<1>) {
    %c_out = firrtl.instance c @Child(out out: !firrtl.uint<1>)
    // CHECK: dbg.variable "c", %{{.+}} : !firrtl.uint<1>
    // CHECK-NOT: uhdi.instance_view
    dbg.variable "c", %c_out : !firrtl.uint<1>
    firrtl.matchingconnect %y, %c_out : !firrtl.uint<1>
  }
}
