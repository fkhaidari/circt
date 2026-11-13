// RUN: circt-translate %s --emit-uhdi --uhdi-indent=0 --split-input-file | FileCheck %s

// CHECK: "original":{"Top":{"name":"demo.Top","vars":{"input":{"type":0},"left":{"type":1},"right":{"type":1}}},"demo.Leaf":{"name":"demo.Leaf","vars":{"data":{"type":0}}}}
// CHECK: "inline_path":["left"],"vars":{"data":"a"}
// CHECK: "inline_path":["right"],"vars":{"data":"b"}
dbg.module @TopDebug type "demo.Top" impl @Top loc(unknown)
dbg.module @LeafDebug type "demo.Leaf" loc(unknown)
hw.module @Top(in %a: i8, in %b: i8) {
  dbg.variable "input", %a : i8 loc(unknown)
  %left = dbg.scope "left" def @LeafDebug loc(unknown)
  dbg.variable "data", %a scope %left : i8 loc(unknown)
  %right = dbg.scope "right" def @LeafDebug loc(unknown)
  dbg.variable "data", %b scope %right : i8 loc(unknown)
} loc(unknown)

// -----

// CHECK: "name":"demo.BB","x-chisel":{"params":{"w":8}}
// CHECK: "original":"Top","generated":"Top","vars":{"e":{"$inst":"e","module":"Ext"}}}
dbg.module @ExtDebug type "demo.BB" ext "{\"x-chisel\":{\"params\":{\"w\":8}}}" impl @Ext loc(unknown)
dbg.module @TopDebug type "demo.Top" impl @Top loc(unknown)
hw.module.extern @Ext(in %p: i8 loc(unknown)) loc(unknown)
hw.hierpath private @ePath [@Top::@e]
hw.module @Top(in %a: i8) {
  hw.instance "e" sym @e @Ext(p: %a: i8) -> () loc(unknown)
  %e = dbg.value path @ePath def @ExtDebug
  dbg.variable "e", %e kind instance : !dbg.value loc(unknown)
} loc(unknown)

// -----

// CHECK: "original":{"Top":{"loc":[0,1,1],"name":"demo.Top","vars":{
// CHECK-SAME: "left":{"type":{{[0-9]+}},"loc":[0,20,3]},"right":{"type":{{[0-9]+}},"loc":[0,30,3]}
// CHECK-SAME: "demo.Leaf":{"loc":[0,10,1],"name":"demo.Leaf"
// CHECK: "files":[{"path":"Design.scala"}]
dbg.module @TopDebug type "demo.Top" impl @Top loc("Design.scala":1:1)
dbg.module @LeafDebug type "demo.Leaf" loc("Design.scala":10:1)
hw.module @Top(in %a: i8) {
  %left = dbg.scope "left" def @LeafDebug loc("Design.scala":20:3)
  dbg.variable "data", %a scope %left : i8 loc("Design.scala":11:3)
  %right = dbg.scope "right" def @LeafDebug loc("Design.scala":30:3)
  dbg.variable "data", %a scope %right : i8 loc("Design.scala":11:3)
} loc(unknown)
