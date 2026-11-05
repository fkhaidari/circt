; RUN: firtool -g %s --emit-uhdi=%t.uhdi.json -o %t.out.sv
; RUN: FileCheck %s < %t.uhdi.json
; RUN: firtool -g %s --emit-uhdi=%t.split.json --split-verilog -o %t.dir
; RUN: FileCheck %s --check-prefix=SPLIT < %t.split.json

; Each `instance_choice` alternative is its own instance under its Verilog
; name. The default target is not instantiated, so it is a root.
; A single Verilog file gives its locations no file name; UHDI names it after
; `-o`.

; CHECK-LABEL: "bindings": [
; CHECK:         "original": "Default",
; CHECK-NEXT:    "generated": "Default",
; CHECK:         "original": "Top",
; CHECK:           "proc_FPGA": {
; CHECK-NEXT:        "$inst": "proc_FPGA",
; CHECK-NEXT:        "module": "Fast"
; CHECK:           "proc_ASIC": {
; CHECK-NEXT:        "$inst": "proc_ASIC",
; CHECK-NEXT:        "module": "Small"
; CHECK-LABEL: "files": [
; CHECK-NEXT:    {
; CHECK-NEXT:      "path": "{{.+}}.out.sv",
; CHECK-NEXT:      "generated": true

; SPLIT-LABEL: "files": [
; SPLIT-NEXT:    {
; SPLIT-NEXT:      "path": "{{.+}}.dir{{/|\\\\}}Default.sv",

FIRRTL version 7.0.0
circuit Top :
  option Platform :
    FPGA
    ASIC

  module Default :
    input a : UInt<8>
    intrinsic(circt_debug_moduleinfo<typeName = "Default">)

  module Fast :
    input a : UInt<8>
    intrinsic(circt_debug_moduleinfo<typeName = "Fast">)

  module Small :
    input a : UInt<8>
    intrinsic(circt_debug_moduleinfo<typeName = "Small">)

  public module Top :
    input a : UInt<8>
    intrinsic(circt_debug_moduleinfo<typeName = "Top">)
    instchoice proc of Default, Platform :
      FPGA => Fast
      ASIC => Small
    connect proc.a, a
