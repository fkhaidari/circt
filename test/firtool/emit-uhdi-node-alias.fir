; A node is not a port because its value happens to be one. `alias` shares
; the input's value at -O=release and drives the output through its own wire
; at -O=debug; at both levels it is a node and the ports keep their own
; records, bound to themselves.

; RUN: firtool -g -O=debug --emit-uhdi --uhdi-output-file=%t.dbg.json %s -o %t.dbg.sv \
; RUN:   && FileCheck %s --check-prefixes=CHECK,DBG --input-file=%t.dbg.json
; RUN: firtool -g -O=release --emit-uhdi --uhdi-output-file=%t.rel.json %s -o %t.rel.sv \
; RUN:   && FileCheck %s --check-prefixes=CHECK,REL --input-file=%t.rel.json

FIRRTL version 4.0.0
circuit T :
  public module T :
    input a : UInt<8>
    output o : UInt<8>
    node alias = a
    connect o, alias

; CHECK:        "variables": {
; CHECK-NEXT:     "a": {
; CHECK-NEXT:       "direction": "input",
; CHECK-NEXT:       "source": {},
; CHECK-NEXT:       "target": {
; CHECK-NEXT:         "verilog": "a"
; CHECK:            "alias": {
; CHECK-NEXT:         "source": {},
; CHECK-NEXT:         "target": {
; DBG-NEXT:             "verilog": "alias_0"
; REL-NEXT:             "verilog": "a"
; CHECK:            "o": {
; CHECK-NEXT:         "direction": "output",
; CHECK-NEXT:         "source": {},
; CHECK-NEXT:         "target": {
; CHECK-NEXT:           "verilog": "o"
