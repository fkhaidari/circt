// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// A scope nested in another one reports that scope as its container, not the
// hardware module both sit in.

hw.module @Top(in %en : i1, out o : i1) {
  %outer = dbg.scope "c0", "Child" {uhdi.stable_id = "scope_outer"}
  %inner = dbg.scope "g0", "Grandchild" scope %outer
    {uhdi.stable_id = "scope_inner"}
  dbg.variable "en", %en scope %inner {uhdi.stable_id = "var_inner_en"} : i1
  dbg.variable "o", %en scope %inner {uhdi.stable_id = "var_inner_o"} : i1
  hw.output %en : i1
}

// CHECK:      "scopes":

// The nested scope names its parent scope, the outer one names the module.
// CHECK:        "scope_inner":
// CHECK:          "containerScopeRef": "scope_outer"
// CHECK:          "kind": "inline"
// CHECK:          "variableRefs":
// CHECK:            "var_inner_en"
// CHECK:            "var_inner_o"

// CHECK:        "scope_outer":
// CHECK:          "containerScopeRef": "Top"
// CHECK:          "kind": "inline"
