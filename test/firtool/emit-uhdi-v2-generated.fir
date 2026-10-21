; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.json %s -o %t.sv
; RUN: FileCheck %s --input-file=%t.json

; Lowering turns the memory into a module of its own. The frontend never
; declared it, so it lives in the target only: no source module, no binding,
; and no variable stands for its instance.

FIRRTL version 4.0.0
circuit M :
  public module M :
    input clock : Clock
    input addr : UInt<2>
    input wdata : UInt<8>
    output data : UInt<8>
    mem m :
      data-type => UInt<8>
      depth => 4
      read-latency => 1
      write-latency => 1
      reader => r
      writer => w
      read-under-write => undefined
    connect m.r.addr, addr
    connect m.r.en, UInt<1>(1)
    connect m.r.clk, clock
    connect m.w.addr, addr
    connect m.w.en, UInt<1>(1)
    connect m.w.clk, clock
    connect m.w.data, wdata
    connect m.w.mask, UInt<1>(1)
    connect data, m.r.data

; CHECK:      "original": {
; CHECK-NEXT:   "M": {
; CHECK-NOT:    "m_
; CHECK:      "generated": {
; CHECK-NEXT:   "M": {
; CHECK-NEXT:     "loc": [
; CHECK-NEXT:       0,
; CHECK-NEXT:       {{[0-9]+}}
; CHECK-NEXT:     ]
; CHECK-NEXT:   },
; CHECK-NEXT:   "{{m_[0-9x]+}}": {
; CHECK-NEXT:     "loc": [
; CHECK-NEXT:       0,
; CHECK-NEXT:       {{[0-9]+}}
; CHECK-NEXT:     ]
; CHECK-NEXT:   }
; CHECK-NEXT: },
; CHECK:      "bindings": [
; CHECK-NEXT:   {
; CHECK-NEXT:     "generated": "M",
; CHECK-NEXT:     "original": "M",
; CHECK-NOT:    "original"
; CHECK:      ]
