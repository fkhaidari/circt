// RUN: circt-opt --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-lower-types))' %s | FileCheck %s --check-prefix=TYPES
// RUN: circt-opt --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl-lower-signatures))' %s | FileCheck %s --check-prefix=SIG
// RUN: circt-opt --split-input-file --pass-pipeline='builtin.module(firrtl-imdeadcodeelim)' %s | FileCheck %s --check-prefix=IMDCE
// RUN: circt-opt --split-input-file -firrtl-add-seqmem-ports %s | FileCheck %s --check-prefix=SEQMEM

// Passes that rebuild an instance preserve its symbol-based debug description. Every instance
// below gets a port added, removed or changed by the pass under test.

firrtl.circuit "Top" {
  hw.hierpath private @c_path [@Top::@c]
  hw.hierpath private @sc_path [@Top::@sc]
  // lower-types: the bundle port is split.
  // imdce: the unused `dead` port is removed.
  firrtl.module private @Child(in %a: !firrtl.bundle<x: uint<1>, y: uint<2>>,
                               in %dead: !firrtl.uint<1>,
                               out %b: !firrtl.string) {
    %0 = firrtl.string "s"
    firrtl.propassign %b, %0 : !firrtl.string
    %1 = firrtl.subfield %a[x] : !firrtl.bundle<x: uint<1>, y: uint<2>>
    %w = firrtl.wire sym @keep : !firrtl.uint<1>
    firrtl.matchingconnect %w, %1 : !firrtl.uint<1>
  }

  // lower-signatures: only scalarized modules get their ports split.
  firrtl.module private @Scalarized(in %a: !firrtl.bundle<x: uint<1>, y: uint<2>>) attributes {convention = #firrtl<convention scalarized>} {
    %w = firrtl.wire : !firrtl.bundle<x: uint<1>, y: uint<2>>
  }

  firrtl.module @Top(in %a: !firrtl.bundle<x: uint<1>, y: uint<2>>,
                     in %d: !firrtl.uint<1>,
                     out %o: !firrtl.string) {
    // TYPES: [[S:%.+]] = dbg.scope "s"
    // TYPES: firrtl.instance c{{.*}} @Child(in a_x: {{.*}})
    // TYPES: firrtl.instance sc{{.*}} @Scalarized({{.*}})
    // SIG: [[S:%.+]] = dbg.scope "s"
    // SIG: firrtl.instance c{{.*}} @Child({{.*}})
    // SIG: firrtl.instance sc{{.*}} @Scalarized(in a_x: {{.*}})
    // IMDCE: [[S:%.+]] = dbg.scope "s"
    // IMDCE: firrtl.instance c{{.*}} @Child(in a: !firrtl.bundle<x: uint<1>, y: uint<2>>, out b: !firrtl.string)
    %s = dbg.scope "s"
    %iv1 = dbg.value path @c_path type "Child"
    dbg.variable "c", %iv1 scope %s : !dbg.value
    %c_a, %c_dead, %c_b = firrtl.instance c sym @c @Child(in a: !firrtl.bundle<x: uint<1>, y: uint<2>>, in dead: !firrtl.uint<1>, out b: !firrtl.string)
    %iv2 = dbg.value path @sc_path type "Scalarized"
    dbg.variable "sc", %iv2 scope %s : !dbg.value
    %sc_a = firrtl.instance sc sym @sc @Scalarized(in a: !firrtl.bundle<x: uint<1>, y: uint<2>>)
    firrtl.matchingconnect %c_a, %a : !firrtl.bundle<x: uint<1>, y: uint<2>>
    firrtl.matchingconnect %c_dead, %d : !firrtl.uint<1>
    firrtl.matchingconnect %sc_a, %a : !firrtl.bundle<x: uint<1>, y: uint<2>>
    firrtl.propassign %o, %c_b : !firrtl.string
  }
}

// -----

// add-seqmem-ports: Child gets the extra memory port, so its instance in Top is
// rebuilt.
firrtl.circuit "SeqMem" attributes {
  annotations = [
    {
      class = "sifive.enterprise.firrtl.AddSeqMemPortAnnotation",
      name = "user_input",
      input = true,
      width = 3
    }
  ]
} {
  hw.hierpath private @child_path [@SeqMem::@child]
  firrtl.memmodule @MWrite_ext(in W0_addr: !firrtl.uint<4>, in W0_en: !firrtl.uint<1>, in W0_clk: !firrtl.clock, in W0_data: !firrtl.uint<42>) attributes {dataWidth = 42 : ui32, depth = 12 : ui64, extraPorts = [], maskBits = 1 : ui32, numReadPorts = 0 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 1 : ui32, readLatency = 1 : ui32, writeLatency = 1 : ui32}
  firrtl.module @Child() {
    %0:4 = firrtl.instance MWrite_ext @MWrite_ext(in W0_addr: !firrtl.uint<4>, in W0_en: !firrtl.uint<1>, in W0_clk: !firrtl.clock, in W0_data: !firrtl.uint<42>)
  }
  firrtl.module @SeqMem() {
    // SEQMEM: [[S:%.+]] = dbg.scope "q"
    // SEQMEM: firrtl.instance child{{.*}} @Child({{.*}})
    %s = dbg.scope "q"
    %iv3 = dbg.value path @child_path type "Child"
    dbg.variable "child", %iv3 scope %s : !dbg.value
    firrtl.instance child sym @child @Child()
  }
}
