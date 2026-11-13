; RUN: firtool -g --disable-all-randomization %s --emit-uhdi=%t.json -o %t.sv
; RUN: %python -c "import json,sys; d=json.load(open(sys.argv[1])); root=d['original']['LayerMemory']['vars']; assert 'readData' in root; children={k:v for k,v in root.items() if d['types'][v['type']]['kind']=='module'}; assert set(children)=={'memory_ext'}; m=d['original'][d['types'][children['memory_ext']['type']]['module']]['vars']; assert len(m)==8 and 'R0_data' in m" %t.json

FIRRTL version 7.0.0
circuit LayerMemory:
  layer Verification, bind:
  public module LayerMemory:
    input clock: Clock
    input rAddr: UInt<2>
    input rEn: UInt<1>
    input wAddr: UInt<2>
    input wEn: UInt<1>
    input wData: UInt<8>
    intrinsic(circt_debug_moduleinfo<typeName = "LayerMemory">)
    layerblock Verification:
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
      node readData = memory.r.data
      connect memory.w.clk, clock
      connect memory.w.en, wEn
      connect memory.w.addr, wAddr
      connect memory.w.mask, UInt<1>(1)
      connect memory.w.data, wData
