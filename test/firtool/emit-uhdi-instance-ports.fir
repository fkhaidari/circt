; Nothing describes an instance's ports from the parent side unless
; firrtl-uhdi-instance-vars runs: the parent sees a bare instance and the
; document has no entry for the signals crossing into it.
;
; This is also the one test that walks the whole chain the value mapping
; depends on: instance-vars builds the aggregate, LowerFIRRTLTypes scalarises
; the ports under it, LowerToHW carries it across, and the emitter resolves it
; against the pool it built.

; RUN: firtool -g --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv 2>%t.diag \
; RUN:   && FileCheck %s --input-file=%t.uhdi.json
; RUN: FileCheck %s --check-prefix=DIAG --input-file=%t.diag --allow-empty

FIRRTL version 4.0.0
circuit Top :
  module Child :
    input in : {a : UInt<8>, b : UInt<8>[2]}
    output out : UInt<8>
    connect out, in.a

  public module Top :
    input x : UInt<8>
    output y : UInt<8>

    inst c of Child
    connect c.in.a, x
    connect c.in.b[0], x
    connect c.in.b[1], x
    connect y, c.out

; The instance view is not a declaration the user wrote and says so, and its
; fields keep the source shape: `in.b[0]`, not the scalarised `in_b_0`.
; CHECK:      "variables":
; CHECK:        "bindKind": "instance"
; CHECK:              "name": "c"
; CHECK:        __in": {
; CHECK-NEXT:     "bindKind": "synthetic"
; CHECK:              "name": "in"
; CHECK:        __in__a": {
; CHECK-NEXT:     "bindKind": "synthetic"
; CHECK:              "name": "a"
; CHECK:        __in__b__0": {
; CHECK-NEXT:     "bindKind": "synthetic"
; CHECK:              "name": "0"

; DIAG-NOT: warning:
