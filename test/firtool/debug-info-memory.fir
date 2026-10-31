; Without debug info, lowering marks nothing.
; RUN: firtool %s --ir-verilog | FileCheck %s --check-prefix=NODBG --implicit-check-not=dbg.
; RUN: firtool %s --repl-seq-mem --repl-seq-mem-file=%t.conf --ir-verilog | FileCheck %s --check-prefix=NODBG --implicit-check-not=dbg.
; NODBG: hw.module @Top

; RUN: firtool %s -g --ir-verilog | FileCheck %s --check-prefix=IR
; RUN: firtool %s -g --ir-verilog | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s
; RUN: firtool %s -g --repl-seq-mem --repl-seq-mem-file=%t.conf --ir-verilog | FileCheck %s --check-prefix=IR-REPL
; RUN: firtool %s -g --repl-seq-mem --repl-seq-mem-file=%t.conf --ir-verilog | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s --check-prefix=REPL

; A memory is an instance of the module that lowering makes for it. That
; module holds the contents as a `mem` variable.

; IR-LABEL: hw.module private @log_16x8
; IR:         %Memory = sv.reg
; IR:         dbg.variable "Memory", %Memory mem

; A memory replaced by an external module has no contents to show and stays
; out of `original`.

; IR-REPL: hw.module private @log({{.*}}) attributes {dbg.lowered}
; IR-REPL: hw.module.extern @log_ext({{.*}}) attributes {dbg.lowered

; REPL:      "original":{"Top":{
; REPL-NOT:    "log
; REPL:      "Wrap":{
; REPL-NOT:    "buf
; REPL:      "generated":{

; Each memory gets a module type, and its vector types are in the table.

; CHECK:      "types":[
; CHECK-SAME: "kind":"vector","size":16
; CHECK-SAME: "kind":"vector","size":8
; CHECK-SAME: "kind":"module","module":"log_16x8"
; CHECK-SAME: "kind":"module","module":"Wrap"
; CHECK-SAME: "kind":"module","module":"inner_buf_8x8"

; The memory module holds `Memory` as a `mem` variable, and each instance is
; a variable of the memory's module type. A memory in an inlined module (Wrap)
; is still found.

; CHECK:      "original":{"log_16x8":{
; CHECK-SAME: "Memory":{"type":1,
; CHECK-SAME: "storage":"mem"
; CHECK-SAME: "inner_buf_8x8":{
; CHECK-SAME: "Memory":{"type":2,
; CHECK-SAME: "storage":"mem"
; CHECK-SAME: "Top":{
; CHECK-SAME: "log":{"type":6,
; CHECK-SAME: "Wrap":{
; CHECK-SAME: "buf":{"type":8,

; Memory instances bind to their extern module by linkage name. The memory
; contents bind to the register of the same name.

; CHECK:      "bindings":[
; CHECK-SAME: "original":"log_16x8","generated":"log_16x8","vars":{"Memory":"Memory"}
; CHECK-SAME: "original":"Top"
; CHECK-SAME: "log":{"$inst":"log_ext","module":"log_16x8"}
; CHECK-SAME: "original":"Wrap"
; CHECK-SAME: "buf":{"$inst":"inner_buf_ext","module":"inner_buf_8x8"}

FIRRTL version 4.0.0
circuit Top: %[[
  {"class": "firrtl.passes.InlineAnnotation", "target": "~|Wrap"}
]]
  module Wrap:
    input clock: Clock
    input addr: UInt<4>
    input wdata: UInt<8>
    input wen: UInt<1>
    output rdata: UInt<8>
    smem buf: UInt<8>[8]
    when wen:
      write mport w = buf[addr], clock
      connect w, wdata
    wire raddr: UInt<4>
    invalidate raddr
    when UInt<1>(1):
      connect raddr, addr
      read mport r = buf[raddr], clock
    connect rdata, r

  public module Top:
    input clock: Clock
    input addr: UInt<4>
    input wdata: UInt<8>
    input wen: UInt<1>
    output rdata: UInt<8>
    output wrdata: UInt<8>
    smem log: UInt<8>[16]
    when wen:
      write mport w = log[addr], clock
      connect w, wdata
    wire raddr: UInt<4>
    invalidate raddr
    when UInt<1>(1):
      connect raddr, addr
      read mport r = log[raddr], clock
    connect rdata, r
    inst inner of Wrap
    connect inner.clock, clock
    connect inner.addr, addr
    connect inner.wdata, wdata
    connect inner.wen, wen
    connect wrdata, inner.rdata
