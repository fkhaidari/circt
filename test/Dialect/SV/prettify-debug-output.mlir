// RUN: circt-opt %s --prettify-verilog | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s --check-prefix=UHDI

hw.module @Top(in %busy: i1, out ready: i1) {
  %true = hw.constant true
  %ready = comb.xor bin %busy, %true : i1
  %value = dbg.value %ready type "Bool" : i1
  dbg.variable "ready", %value : !dbg.value
  hw.output %ready : i1
}
// UHDI: "vars":{"ready":{"$op":"^","args":["busy",{"$const":"0b1"}]}}
