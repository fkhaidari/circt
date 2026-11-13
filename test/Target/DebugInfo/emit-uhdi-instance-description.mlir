// RUN: circt-translate %s --emit-uhdi --uhdi-indent=0 > %t
// RUN: FileCheck %s < %t
// RUN: %python %S/check-instance-descriptions.py %t

dbg.module @debug1 type "example.Child" ext "{\"x-chisel\":{\"params\":{\"width\":8}}}" impl @Child
dbg.module @debug2 type "example.Wrapper" impl @Wrapper
dbg.module @debug3 type "example.External" ext "{\"x-chisel\":{\"params\":{\"width\":8}}}" impl @External
dbg.module @debug4 type "example.Top" impl @Top
hw.hierpath private @child_path [@Transparent::@child, @Child]
hw.hierpath private @external_path [@Top::@external, @External]
hw.hierpath private @left_path [@Top::@left, @Child]
hw.hierpath private @right_path [@Top::@right, @Child]

// CHECK: "leftSource"
// CHECK: "rightSource"
// CHECK: "leftSource":{"$inst":"left_hw","module":"Child"}
// CHECK: "rightSource":{"$inst":"right_hw","module":"Child"}
// CHECK: "nestedSource":{"$inst":"wrapper_hw.inner_hw","module":"Child"}

hw.hierpath private @nested [@Top::@wrapper, @Wrapper::@inner, @Child]
hw.module @Child(in %i: i8) {
  dbg.variable "input", %i kind input : i8
}
hw.module @Wrapper(in %i: i8) {
  hw.instance "inner_hw" sym @inner @Child(i: %i: i8) -> ()
}
hw.module.extern @External(in %i: i8)
hw.module @Transparent(in %i: i8) {
  %child = dbg.value path @child_path
  dbg.variable "transparentChild", %child : !dbg.value
  hw.instance "transparent_child_hw" sym @child @Child(i: %i: i8) -> ()
}
hw.module @Top(in %i: i8) {
  hw.instance "transparent_hw" @Transparent(i: %i: i8) -> ()
  %external = dbg.value path @external_path
  dbg.variable "externalSource", %external : !dbg.value
  hw.instance "external_hw" sym @external @External(i: %i: i8) -> ()
  %left = dbg.value path @left_path
  dbg.variable "leftSource", %left : !dbg.value
  %right = dbg.value path @right_path
  dbg.variable "rightSource", %right : !dbg.value
  %nested = dbg.value path @nested
  dbg.variable "nestedSource", %nested : !dbg.value
  hw.instance "left_hw" sym @left @Child(i: %i: i8) -> ()
  hw.instance "right_hw" sym @right @Child(i: %i: i8) -> ()
  hw.instance "wrapper_hw" sym @wrapper @Wrapper(i: %i: i8) -> ()
  hw.instance "other_wrapper_hw" @Wrapper(i: %i: i8) -> ()
}
