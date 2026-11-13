// RUN: circt-opt %s --firrtl-extract-instances | FileCheck %s

firrtl.circuit "Top" {
  hw.hierpath private @debug_Sub_box [@Sub::@box]
  hw.hierpath private @left [@Top::@left]
  hw.hierpath private @right [@Top::@right]
  firrtl.extmodule @BBox() attributes {
    annotations = [{class = "sifive.enterprise.firrtl.ExtractBlackBoxAnnotation", filename = "boxes.txt", prefix = "", dest = "Extracted"}],
    defname = "BBox"
  }
  dbg.module @debug1 type "SubSource" impl @Sub
  dbg.module @debug2 type "Owner"
  firrtl.module private @Sub(in %x: !firrtl.uint<8>) {

    %owner = dbg.scope "owner" def @debug2

    dbg.variable "x", %x scope %owner : !firrtl.uint<8>
    %bbox = dbg.value path @debug_Sub_box type "BoxSource" ext "{\22x-test\22:1}"
    dbg.variable "box", %bbox scope %owner kind instance : !dbg.value
    firrtl.instance box sym @box @BBox()
  }
  dbg.module @debug3 type "TopSource" impl @Top
  firrtl.module @Top(in %x: !firrtl.uint<8>) attributes {
    annotations = [{class = "sifive.enterprise.firrtl.MarkDUTAnnotation"}]
  } {

    %left = dbg.value path @left type "SubSource"
    dbg.variable "left", %left kind instance : !dbg.value
    %right = dbg.value path @right type "SubSource"
    dbg.variable "right", %right kind instance : !dbg.value
    %left_x = firrtl.instance left sym @left @Sub(in x: !firrtl.uint<8>)
    %right_x = firrtl.instance right sym @right @Sub(in x: !firrtl.uint<8>)
    firrtl.matchingconnect %left_x, %x : !firrtl.uint<8>
    firrtl.matchingconnect %right_x, %x : !firrtl.uint<8>
  }
}
// CHECK-LABEL: firrtl.module private @Sub
// CHECK: %[[OWNER:.*]] = dbg.scope "owner"
// CHECK: dbg.variable "x", %x scope %[[OWNER]]
// CHECK-NOT: firrtl.instance
// CHECK-LABEL: firrtl.module private @Extracted
// CHECK-DAG: firrtl.instance box sym @box @BBox()
// CHECK-DAG: firrtl.instance box sym @box_0 @BBox()
// CHECK-LABEL: firrtl.module @Top
// CHECK: %[[LEFT:.*]] = dbg.scope "left"
// CHECK: %[[LC:.*]] = dbg.scope "owner" scope %[[LEFT]]
// CHECK: %[[LV:.*]] = dbg.value path @debug_extracted{{.*}} type "BoxSource" ext "{\22x-test\22:1}"
// CHECK: dbg.variable "box", %[[LV]] scope %[[LC]] kind instance
// CHECK: %[[RIGHT:.*]] = dbg.scope "right"
// CHECK: %[[RC:.*]] = dbg.scope "owner" scope %[[RIGHT]]
// CHECK: %[[RV:.*]] = dbg.value path @debug_extracted{{.*}} type "BoxSource" ext "{\22x-test\22:1}"
// CHECK: dbg.variable "box", %[[RV]] scope %[[RC]] kind instance
