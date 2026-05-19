// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s
// RUN: circt-translate %s --emit-uhdi 2>&1 >/dev/null | FileCheck %s --check-prefix=DIAG --allow-empty

// Two instances of one module, each with its own scope. The variables under
// them must stay apart: sharing a name across instances is the normal case,
// and merging them would make the document describe one instance twice.

hw.module @Parent(in %en : i1, in %valid : i1, out o : i1) {
  %sc0 = dbg.scope "c0", "Child" {uhdi.stable_id = "scope_c0"}
  dbg.variable "en", %en scope %sc0 {uhdi.stable_id = "var_c0_en"} : i1

  %sc1 = dbg.scope "c1", "Child" {uhdi.stable_id = "scope_c1"}
  dbg.variable "en", %valid scope %sc1 {uhdi.stable_id = "var_c1_en"} : i1

  dbg.variable "en", %en {uhdi.stable_id = "var_par_en"} : i1
  dbg.variable "o", %en {uhdi.stable_id = "var_par_o"} : i1

  hw.output %en : i1
}

// CHECK: "scopes":

// Each instance scope lists only its own variable, and both name the module
// as their container rather than each other.
// CHECK: "scope_c0":
// CHECK:   "containerScopeRef": "Parent"
// CHECK:   "variableRefs":
// CHECK:     "var_c0_en"

// CHECK: "scope_c1":
// CHECK:   "containerScopeRef": "Parent"
// CHECK:   "variableRefs":
// CHECK:     "var_c1_en"

// CHECK: "variables":
// CHECK-DAG: "var_c0_en":
// CHECK-DAG: "var_c1_en":

// Same name in three scopes is not a collision.
// DIAG-NOT: warning:
