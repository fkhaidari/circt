// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// The module an instance was inlined from no longer exists, so its
// source-level type name and parameters ride on the `dbg.scope` the inliner
// created. An inline scope reports them exactly like a module scope does.

hw.module @Parent(in %en : i1, out o : i1)
    attributes {dbg.moduleinfo = {params = [], typeName = "Parent"}} {
  %sc = dbg.scope "c0", "Child"
    {uhdi.stable_id = "scope_c0",
     dbg.moduleinfo = {params = [{name = "width", value = "8"}],
                       typeName = "Child"}}
  dbg.variable "en", %en scope %sc {uhdi.stable_id = "var_c0_en"} : i1
  hw.output %en : i1
}

// CHECK:      "scopes":
// CHECK:        "Parent":
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "sourceLangType":
// CHECK:                "typeName": "Parent"

// CHECK:        "scope_c0":
// CHECK:          "kind": "inline"
// CHECK:          "representations":
// CHECK:            "chisel":
// CHECK:              "name": "c0"
// CHECK:              "sourceLangType":
// CHECK:                "params":
// CHECK:                  "name": "width"
// CHECK:                  "value": "8"
// CHECK:                "typeName": "Child"
