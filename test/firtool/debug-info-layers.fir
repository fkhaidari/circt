; RUN: firtool -g --ir-hw %s | FileCheck %s

; The module extracted from a layer block is marked as artificial in debug info.

FIRRTL version 4.0.0
circuit Top:
  layer A, bind:

  ; CHECK: hw.module private @Top_A({{.*}}) attributes {dbg.artificial}
  ; CHECK: hw.module @Top(
  public module Top:
    input a: UInt<1>
    layerblock A:
      node n = a
