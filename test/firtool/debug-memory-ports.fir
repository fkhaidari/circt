; RUN: firtool -g --disable-all-randomization --strip-debug-info %s --emit-uhdi=%t.json -o %t.debug.sv
; RUN: FileCheck %s --check-prefix=UHDI < %t.json
; RUN: %python -c "import json,sys; d=json.load(open(sys.argv[1])); v=next(m['vars'] for m in d['original'].values() if 'R0_addr' in m.get('vars',{})); expected={'R0_addr':2,'R0_en':1,'R0_clk':1,'R0_data':8,'W0_addr':2,'W0_en':1,'W0_clk':1,'W0_data':8}; assert {k:d['types'][x['type']]['width'] for k,x in v.items()} == expected" %t.json
; RUN: firtool --disable-all-randomization --strip-debug-info %s -o %t.plain.sv
; Debug port uses may retain output aliases; both Verilog variants are emitted.

FIRRTL version 4.0.0
circuit MemoryPorts:
  public module MemoryPorts:
    input clock: Clock
    input rAddr: UInt<2>
    input rEn: UInt<1>
    output rData: UInt<8>
    input wAddr: UInt<2>
    input wEn: UInt<1>
    input wData: UInt<8>
    mem memory:
      data-type => UInt<8>
      depth => 4
      reader => r
      writer => w
      read-latency => 1
      write-latency => 1
      read-under-write => undefined
    connect memory.r.clk, clock
    connect memory.r.en, rEn
    connect memory.r.addr, rAddr
    connect rData, memory.r.data
    connect memory.w.clk, clock
    connect memory.w.en, wEn
    connect memory.w.addr, wAddr
    connect memory.w.mask, UInt<1>(1)
    connect memory.w.data, wData

; UHDI-DAG: "memory_ext": {
; UHDI-DAG: "R0_addr": {
; UHDI-DAG: "R0_en": {
; UHDI-DAG: "R0_clk": {
; UHDI-DAG: "R0_data": {
; UHDI-DAG: "W0_addr": {
; UHDI-DAG: "W0_en": {
; UHDI-DAG: "W0_clk": {
; UHDI-DAG: "W0_data": {
