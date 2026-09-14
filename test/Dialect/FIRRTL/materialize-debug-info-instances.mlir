// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-materialize-debug-info)))' %s | FileCheck %s

// An instance's ports have nothing describing them from the parent side, so a
// statement connecting to `c.a` has nothing to point at. Describe them here,
// while the aggregate structure is still visible: LowerFIRRTLTypes has not run
// yet, so field and element names are still distinguishable.

firrtl.circuit "Top" {
  firrtl.module private @Child(in %in: !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>,
                               in %unused: !firrtl.uint<1>,
                               out %out: !firrtl.uint<1>,
                               out %o: !firrtl.bundle<x: uint<1>, y: uint<1>>) {
    %0 = firrtl.subfield %in[a] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    firrtl.matchingconnect %out, %0 : !firrtl.uint<1>
    %1 = firrtl.subfield %o[x] : !firrtl.bundle<x: uint<1>, y: uint<1>>
    %2 = firrtl.subfield %o[y] : !firrtl.bundle<x: uint<1>, y: uint<1>>
    firrtl.matchingconnect %1, %0 : !firrtl.uint<1>
    firrtl.matchingconnect %2, %0 : !firrtl.uint<1>
  }

  // CHECK-LABEL: firrtl.module @Top
  firrtl.module @Top(in %x: !firrtl.uint<1>, out %y: !firrtl.uint<1>) {
    %c_in, %c_unused, %c_out, %c_o = firrtl.instance c @Child(
      in in: !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>,
      in unused: !firrtl.uint<1>,
      out out: !firrtl.uint<1>,
      out o: !firrtl.bundle<x: uint<1>, y: uint<1>>)

    // The aggregate port keeps its source shape: a struct with the field names
    // and an array for the vector.
    // CHECK:      %[[B0:.+]] = firrtl.subindex %{{.+}}[0]
    // CHECK:      %[[B1:.+]] = firrtl.subindex %{{.+}}[1]
    // CHECK:      %[[ARR:.+]] = dbg.array [%[[B0]], %[[B1]]]
    // CHECK:      %[[IN:.+]] = dbg.struct {"a": %{{.+}}, "b": %[[ARR]]}
    // CHECK:      %[[O:.+]] = dbg.struct {"x": %{{.+}}}
    // CHECK:      %[[ST:.+]] = dbg.struct {"in": %[[IN]], "out": %{{.+}}, "o": %[[O]]}
    // CHECK-NEXT: dbg.variable "c", %[[ST]]

    // `unused` is connected to nothing, so it is left out: no statement could
    // name it, and a debug operand would keep the port alive. `o.y` is read by
    // nothing, so it is left out for the same reason, while `o.x` stays.
    // CHECK-NOT: "unused"
    // CHECK-NOT: "y"

    %0 = firrtl.subfield %c_in[a] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    firrtl.matchingconnect %0, %x : !firrtl.uint<1>
    %1 = firrtl.subfield %c_in[b] : !firrtl.bundle<a: uint<1>, b: vector<uint<1>, 2>>
    %2 = firrtl.subindex %1[0] : !firrtl.vector<uint<1>, 2>
    %3 = firrtl.subindex %1[1] : !firrtl.vector<uint<1>, 2>
    firrtl.matchingconnect %2, %x : !firrtl.uint<1>
    firrtl.matchingconnect %3, %x : !firrtl.uint<1>
    firrtl.matchingconnect %y, %c_out : !firrtl.uint<1>
    %4 = firrtl.subfield %c_o[x] : !firrtl.bundle<x: uint<1>, y: uint<1>>
    %5 = firrtl.node %4 : !firrtl.uint<1>
  }
}
