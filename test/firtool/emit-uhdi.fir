; Smoke test for `firtool --emit-uhdi`.  Verifies that the end-to-end
; pipeline wiring (UhdiInit, UhdiCaptureWhen, UhdiVerilogSnapshot, EmitUHDI)
; runs together with Verilog emission and produces a JSON document with
; the expected top-level structure.

; RUN: firtool --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv \
; RUN:   && FileCheck %s --input-file=%t.uhdi.json

; CHECK: "format"
; CHECK: "name": "uhdi"
; CHECK: "scopes"
; CHECK: "Top"
; CHECK: "variables"
; CHECK: "a"

; --emit-uhdi requires real Verilog output. Each non-Verilog output mode must
; be rejected up front so the user does not get a JSON document referencing a
; file that contains MLIR or nothing at all.
; RUN: not firtool --emit-uhdi --ir-fir %s 2>&1 | FileCheck %s --check-prefix=ERROR
; RUN: not firtool --emit-uhdi --ir-hw %s 2>&1 | FileCheck %s --check-prefix=ERROR
; RUN: not firtool --emit-uhdi --ir-sv %s 2>&1 | FileCheck %s --check-prefix=ERROR
; RUN: not firtool --emit-uhdi --ir-verilog %s 2>&1 | FileCheck %s --check-prefix=ERROR
; ERROR: error: --emit-uhdi requires --verilog or --split-verilog

FIRRTL version 3.3.0
circuit Top :
  public module Top :
    input clock : Clock
    input reset : UInt<1>
    input a : UInt<8>
    output b : UInt<8>

    connect b, a
