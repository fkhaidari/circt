; Smoke test for `firtool --emit-uhdi`.  Verifies that the end-to-end
; pipeline wiring (UhdiInit, UhdiCaptureWhen, UhdiVerilogSnapshot, EmitUHDI)
; runs together with Verilog emission and produces a JSON document with
; the expected top-level structure.

; `-g` is what materialises the dbg ops the pipeline is meant to consume;
; without it the document only ever contains ports synthesised from the module
; signature, so the passes under test are never exercised.
; RUN: firtool -g --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv \
; RUN:   && FileCheck %s --input-file=%t.uhdi.json

; CHECK: "format"
; CHECK: "name": "uhdi"
; CHECK: "scopes"
; CHECK: "Top"
; CHECK: "variables"
; CHECK: "a"

; The document must name the Verilog file it describes; an empty entry leaves
; consumers unable to locate the netlist the debug info refers to.
; RUN: FileCheck %s --input-file=%t.uhdi.json --check-prefix=FILES
; FILES:      "verilog": {
; FILES-NEXT:   "files": [
; FILES-NEXT:     "{{.+\.sv}}"

; In split mode the same option holds a directory, not a file. Seeding the
; document with it names something that is not a netlist and, being a single
; entry, cannot name the several files split emission actually produces; the
; real names have to come from the emitted locations instead.
; RUN: rm -rf %t.split && mkdir -p %t.split
; RUN: firtool -g --emit-uhdi --uhdi-output-file=%t.split.json --split-verilog \
; RUN:   -o %t.split %s \
; RUN:   && FileCheck %s --input-file=%t.split.json --check-prefix=SPLIT
; SPLIT:      "verilog": {
; SPLIT-NEXT:   "files": [
; SPLIT-NEXT:     "{{.+\.sv}}"

; The output port must be described once, as an output, bound to its own
; signal. Reporting it as an input driven by `a`, plus a synthesised duplicate
; carrying the correct direction, gives consumers two conflicting records of
; one port.
; RUN: FileCheck %s --input-file=%t.uhdi.json --check-prefix=PORT
; PORT:      "direction": "output",
; PORT:      "chisel": {
; PORT:        "name": "b",
; PORT:      "verilog": {
; PORT:        "name": "b",
; PORT:        "sigName": "b"
; RUN: FileCheck %s --input-file=%t.uhdi.json --check-prefix=NODUP
; NODUP-NOT: "var_Top_b"

; --emit-uhdi requires real Verilog output. Each non-Verilog output mode must
; be rejected up front so the user does not get a JSON document referencing a
; file that contains MLIR or nothing at all.
; RUN: not firtool --emit-uhdi --ir-fir %s 2>&1 | FileCheck %s --check-prefix=ERROR
; RUN: not firtool --emit-uhdi --ir-hw %s 2>&1 | FileCheck %s --check-prefix=ERROR
; RUN: not firtool --emit-uhdi --ir-sv %s 2>&1 | FileCheck %s --check-prefix=ERROR
; RUN: not firtool --emit-uhdi --ir-verilog %s 2>&1 | FileCheck %s --check-prefix=ERROR
; ERROR: error: --emit-uhdi requires --verilog or --split-verilog
;
; --emit-uhdi without --uhdi-output-file is rejected up front.
; RUN: not firtool --emit-uhdi %s -o %t2.sv 2>&1 | FileCheck %s --check-prefix=NOFILE
; NOFILE: error: --emit-uhdi requires --uhdi-output-file=<path>

FIRRTL version 3.3.0
circuit Top :
  public module Top :
    input clock : Clock
    input reset : UInt<1>
    input a : UInt<8>
    output b : UInt<8>

    connect b, a
