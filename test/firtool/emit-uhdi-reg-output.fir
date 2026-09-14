; RUN: firtool -g -O=release --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv \
; RUN:   && FileCheck %s --input-file=%t.uhdi.json

; An output port driven by a register: the port variable MaterializeDebugInfo
; declares reads the register, and by emit time the port and the variable
; read it through two different `sv.read_inout`s. The port is still the
; variable named after it, not a second record synthesised from the
; signature beside a nameless one.

FIRRTL version 4.0.0
circuit T :
  public module T :
    input clock : Clock
    input a : UInt<8>
    output o : UInt<8>
    reg r : UInt<8>, clock
    connect r, a
    connect o, r

; CHECK:      "o": {
; CHECK-NEXT:   "direction": "output",
; CHECK-NEXT:   "source": {},
; CHECK-NEXT:   "target": {
; CHECK-NEXT:     "verilog": "o"
; CHECK-NOT:  "o.1"
; CHECK:      "r": {
; CHECK-NEXT:   "source": {},
; CHECK-NEXT:   "target": {
; CHECK-NEXT:     "verilog": "r"
