; RUN: firtool %s --ir-hw | FileCheck %s --check-prefix=NODEBUG --implicit-check-not=dbg.
; RUN: firtool -g %s --ir-hw 2>&1 | FileCheck %s --check-prefix=DEBUG

; Debug intrinsics in a class body are erased, with a warning under -g.
; Without -g the Verilog is that of the input without the intrinsics.
; RUN: firtool %s --strip-debug-info -o %t.a.sv
; RUN: sed '/intrinsic(/d' %s > %t.stripped.fir
; RUN: firtool %t.stripped.fir --strip-debug-info -o %t.b.sv
; RUN: diff %t.a.sv %t.b.sv

; NODEBUG-LABEL: hw.module @Top
; NODEBUG-LABEL: om.class private @C

; DEBUG:       warning: debug intrinsics in a class body are dropped
; DEBUG-LABEL: hw.module @Top
; DEBUG:       dbg.moduleinfo "Top"
; DEBUG-LABEL: om.class private @C
; DEBUG-NOT:   dbg.

FIRRTL version 6.0.0
circuit Top :
  class C :
    output x : Integer
    intrinsic(circt_debug_moduleinfo<typeName = "C">)
    intrinsic(circt_debug_var<name = "v">, UInt<1>(0))
    propassign x, Integer(1)
  public module Top :
    input a : UInt<8>
    output b : UInt<8>
    output o : Inst<C>
    object obj of C
    propassign o, obj
    connect b, a
    intrinsic(circt_debug_moduleinfo<typeName = "Top">)
