// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// The module an instance was inlined from no longer exists, so its
// source-level type name and constructor params ride on the `dbg.scope` the
// inliner created. An inline scope reports them exactly like a module does.

hw.module @Parent(in %en : i1, out o : i1)
    attributes {dbg.moduleinfo = {params = [], typeName = "Parent"}} {
  %sc = dbg.scope "c0", "Child"
    {dbg.moduleinfo = {params = [{name = "width", value = "8"}],
                       typeName = "Child"}}
  dbg.variable "en", %en scope %sc : i1
  hw.output %en : i1
}

// CHECK:      "modules":
// CHECK:        "Parent":
// CHECK:          "source": {
// CHECK:            "typeName": "Parent"

// CHECK:          "scopes": [
// CHECK-NEXT:       {
// CHECK-NEXT:         "kind": "inline",
// CHECK:              "name": "c0",
// CHECK-NEXT:         "params": [
// CHECK-NEXT:           {
// CHECK-NEXT:             "name": "width",
// CHECK-NEXT:             "value": "8"
// CHECK:              "typeName": "Child"
