; RUN: firtool -g --disable-all-randomization %s --emit-uhdi=%t.json -o %t.sv
; RUN: %python -c "import json,sys; d=json.load(open(sys.argv[1])); root=d['original']['MemoryNested']['vars']; child=d['original'][d['types'][root['left']['type']]['module']]['vars']; assert 'memory_ext' in child; assert 'left_memory_ext' not in root; m=d['original'][d['types'][child['memory_ext']['type']]['module']]['vars']; assert len(m)==8 and 'R0_data' in m" %t.json
; RUN: firtool -g --disable-all-randomization --repl-seq-mem --repl-seq-mem-file=%t.conf %s --emit-uhdi=%t.external.json -o %t.external.sv
; RUN: %python -c "import json,sys; d=json.load(open(sys.argv[1])); root=d['original']['MemoryNested']['vars']; child=d['original'][d['types'][root['left']['type']]['module']]['vars']; assert 'memory_ext' in child; assert 'left_memory_ext' not in root; m=d['original'][d['types'][child['memory_ext']['type']]['module']]['vars']; assert len(m)==8 and 'R0_data' in m" %t.external.json

FIRRTL version 4.0.0
circuit MemoryNested: %[[{"class":"firrtl.passes.InlineAnnotation","target":"~MemoryNested|Child"}]]
  public module MemoryNested:
    input clock: Clock
    input rAddr: UInt<2>
    input rEn: UInt<1>
    output rData: UInt<8>
    input wAddr: UInt<2>
    input wEn: UInt<1>
    input wData: UInt<8>
    inst left of Child
    connect left.clock, clock
    connect left.rAddr, rAddr
    connect left.rEn, rEn
    connect rData, left.rData
    connect left.wAddr, wAddr
    connect left.wEn, wEn
    connect left.wData, wData
  module Child:
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
