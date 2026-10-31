// RUN: circt-translate %s --emit-hgldd --split-input-file | FileCheck %s --check-prefix=HGLDD
// RUN: circt-translate %s --emit-uhdi --uhdi-indent=0 --split-input-file | FileCheck %s --check-prefix=UHDI

// A `dbg.instance` describes an instance and is not a hierarchy level of its
// own. An optimized-away instance ("gone") is left out of UHDI, also from the
// type table.

// HGLDD-LABEL: "module_name": "Top"
// HGLDD:       "children": [
// HGLDD-NEXT:    {
// HGLDD-NEXT:      "name": "c",
// HGLDD-NEXT:      "obj_name": "Child",
// HGLDD-NEXT:      "module_name": "Child",
// HGLDD-NEXT:      "hgl_loc": {
// HGLDD:           }
// HGLDD-NEXT:    }
// HGLDD-NEXT:  ]

// UHDI:      "types":[{"kind":"uint","width":8},{"kind":"module","module":"Child"}],"original"
// UHDI-SAME: "Top":{
// UHDI-SAME: "a":{"type":0,
// UHDI-SAME: "c":{"type":1,
// UHDI-NOT:  "gone"
// UHDI-NOT:  "Gone"
// UHDI-SAME: "bindings"
// UHDI-SAME: "c":{"$inst":"c","module":"Child"}
hw.module private @Child(in %a: i8) {
  dbg.variable "a", %a dir in : i8
} loc("F":1:1)

hw.module @Top(in %a: i8) {
  dbg.variable "a", %a dir in : i8
  dbg.instance "c", "Child"
  hw.instance "c" @Child(a: %a: i8) -> ()
  dbg.instance "gone", "Child" typeName "Gone"
} loc("F":2:1)

// -----

// An instance description in an inlined scope places the instance there under
// its source name. The linkage name finds the instance.

// HGLDD-LABEL: "module_name": "Outer"
// HGLDD:       "name": "m",
// HGLDD:       "children": [
// HGLDD-NEXT:    {
// HGLDD-NEXT:      "name": "c",
// HGLDD-NEXT:      "hdl_obj_name": "m_c",
// HGLDD-NEXT:      "obj_name": "Child",

// UHDI:      "Outer":{"loc"
// UHDI-SAME: "m":{"type":1,
// UHDI-SAME: "Mid":{"vars":{"c":{"type":2,
// UHDI-SAME: "bindings"
// UHDI-SAME: {"original":"Mid","generated":"Outer","inline_path":["m"],"vars":{"c":{"$inst":"m_c","module":"Child"}}}
hw.module private @Child(in %a: i8) {
  dbg.variable "a", %a dir in : i8
} loc("F":1:1)

hw.module @Outer(in %a: i8) {
  %0 = dbg.scope "m", "Mid"
  dbg.instance "c", "Child" linkage "m_c" scope %0
  hw.instance "m_c" @Child(a: %a: i8) -> ()
} loc("F":2:1)
