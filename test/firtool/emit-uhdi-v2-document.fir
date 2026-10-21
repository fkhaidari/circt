; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.json %s -o %t.sv
; RUN: FileCheck %s --input-file=%t.json
; RUN: sed '/intrinsic/d' %s > %t.plain.fir
; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.plain.json %t.plain.fir -o %t.plain.sv
; RUN: FileCheck %s --check-prefix=PLAIN --input-file=%t.plain.json

; The document lists what it uses and nothing else: the profiles it needs,
; the types its variables reach, and the netlist each module lies in, even
; when ExportVerilog writes one file without naming it.

FIRRTL version 4.0.0
circuit T :
  public module T :
    output io : { flip a : UInt<1>, b : UInt<1> }
    intrinsic(circt_debug_subfield<typeName = "IO[Bool]", name = "io.a", parent = "io">, io.a)
    intrinsic(circt_debug_subfield<typeName = "IO[Bool]", name = "io.b", parent = "io">, io.b)
    intrinsic(circt_debug_var<typeName = "IO[Pair]", name = "io">)
    connect io.b, not(io.a)

; CHECK:      "profiles": [
; CHECK-NEXT:   "x-chisel"
; CHECK-NEXT: ],
; A type comes after the types it is built from.
; CHECK:      "types": [
; CHECK-NEXT:   {
; CHECK-NEXT:     "kind": "uint",
; CHECK-NEXT:     "name": "Bool",
; CHECK-NEXT:     "width": 1
; CHECK-NEXT:   },
; CHECK-NEXT:   {
; CHECK:          "type": 0
; CHECK:          "name": "Pair"
; CHECK-NEXT:   }
; CHECK-NEXT: ],
; CHECK:      "generated": {
; CHECK-NEXT:   "T": {
; CHECK-NEXT:     "loc": [
; CHECK-NEXT:       0,
; CHECK-NEXT:       2
; CHECK-NEXT:     ]
; CHECK-NEXT:   }
; CHECK-NEXT: },

; Without frontend data the document claims no frontend profile.
; PLAIN:      "profiles": [],
