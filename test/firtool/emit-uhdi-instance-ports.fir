; Nothing describes an instance's ports from the parent side unless
; MaterializeDebugInfo adds a view of them: the parent sees a bare instance
; and the document has no entry for the signals crossing into it.
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

; Child's own aggregate port binds every leaf under its dotted source path:
; `in.b.0`, not the scalarised `in_b_0`. The scalarised ports it covers do not
; also show up as records of their own.
; The view is not a type either: nothing in the document refers to a struct
; over Child's ports, so the pool must not carry one.
; CHECK-NOT:  "Top_c"
; CHECK:      "modules":
; CHECK:        "Child":
; CHECK:          "variables": {
; CHECK-NEXT:       "in": {
; CHECK-NEXT:         "source": {},
; CHECK-NEXT:         "target": {
; CHECK-NEXT:           "verilog": {
; CHECK-NEXT:             "a": "in_a",
; CHECK-NEXT:             "b.0": "in_b_0",
; CHECK-NEXT:             "b.1": "in_b_1"
; CHECK:            "out": {
; CHECK:              "direction": "output",
; CHECK-NOT:        "in_a"

; The instance view is not a declaration the user wrote, so it is not a
; variable of the parent: it binds the instance's ports to the parent signals
; driving them, keyed by port, under the instance itself. The parent's own
; ports feed the instance and keep their records all the same.
; CHECK:        "Top":
; CHECK:          "variables": {
; CHECK-NEXT:       "x": {
; CHECK-NEXT:         "direction": "input",
; CHECK:            "y": {
; CHECK-NEXT:         "direction": "output",
; CHECK:          "instances": {
; CHECK-NEXT:       "c": {
; CHECK-NEXT:         "moduleRef": "Child",
; CHECK-NEXT:         "target": {
; CHECK-NEXT:           "verilog": {
; CHECK-NEXT:             "in": {
; CHECK-NEXT:               "a": "x",
; CHECK-NEXT:               "b.0": "x",
; CHECK-NEXT:               "b.1": "x"
; CHECK:                  "out": "y"

; DIAG-NOT: warning:
