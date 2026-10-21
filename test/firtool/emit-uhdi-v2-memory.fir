; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.json %s -o %t.sv
; RUN: FileCheck %s --input-file=%t.json

; A memory the frontend declared is a variable of its parent: a vector of the
; element type whose value is the array inside the generated memory module.

FIRRTL version 4.0.0
circuit M :
  public module M :
    input clock : Clock
    input addr : UInt<1>
    input wen : UInt<1>
    input ren : UInt<1>
    input wdata : UInt<8>
    output data : UInt<8>
    smem mem : UInt<8>[2] @[M.scala 3:16]
    when wen :
      write mport w = mem[addr], clock
      connect w, wdata
    wire raddr : UInt<1>
    invalidate raddr
    when ren :
      connect raddr, addr
      read mport r = mem[raddr], clock
    connect data, r
    intrinsic(circt_debug_var<typeName = "IO[UInt<8>]", name = "data">, data)
    intrinsic(circt_debug_var<typeName = "SyncReadMem[UInt<8>[2]]", name = "mem">) @[M.scala 3:16]

; CHECK:      "types": [
; CHECK:            "name": "UInt<8>",
; CHECK-NEXT:     "width": 8
; CHECK-NEXT:   },
; CHECK-NEXT:   {
; CHECK-NEXT:     "elem": 2,
; CHECK-NEXT:     "kind": "vector",
; CHECK-NEXT:     "name": "UInt<8>[2]",
; CHECK-NEXT:     "size": 2
; CHECK-NEXT:   }
; CHECK:      "original": {
; CHECK-NEXT:   "M": {
; CHECK-NEXT:     "vars": {
; CHECK:            "mem": {
; CHECK-NEXT:         "loc": [
; CHECK-NEXT:           0,
; CHECK-NEXT:           3,
; CHECK-NEXT:           16
; CHECK-NEXT:         ],
; CHECK-NEXT:         "type": 3,
; CHECK-NEXT:         "x-chisel": {
; CHECK-NEXT:           "binding": "SyncReadMem"
; CHECK-NEXT:         }
; CHECK-NEXT:       }
; CHECK:      "bindings": [
; CHECK-NEXT:   {
; CHECK-NEXT:     "generated": "M",
; CHECK-NEXT:     "original": "M",
; CHECK-NEXT:     "vars": {
; CHECK:            "mem": "mem_ext.Memory"
