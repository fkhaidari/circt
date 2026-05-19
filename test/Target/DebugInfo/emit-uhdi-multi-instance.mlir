// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s
// RUN: circt-translate %s --emit-uhdi 2>&1 >/dev/null | FileCheck %s --check-prefix=DIAG --allow-empty

hw.module @Parent(in %en : i1, in %valid : i1, out o : i1) {
  %sc0 = dbg.scope "c0", "Child" {uhdi.stable_id = "scope_c0"}
  %e0 = dbg.expression "g_and", opcode "&", operands(%en, %valid : i1, i1) scope %sc0 {uhdi.stable_id = "expr_c0_guard"}
  dbg.rootblock scope %sc0 {
    dbg.subblock condition %e0 {
    }
  }

  %sc1 = dbg.scope "c1", "Child" {uhdi.stable_id = "scope_c1"}
  %e1 = dbg.expression "g_and", opcode "&", operands(%en, %valid : i1, i1) scope %sc1 {uhdi.stable_id = "expr_c1_guard"}
  dbg.rootblock scope %sc1 {
    dbg.subblock condition %e1 {
    }
  }

  dbg.variable "en", %en {uhdi.stable_id = "var_par_en"} : i1
  dbg.variable "o", %en {uhdi.stable_id = "var_par_o"} : i1
  dbg.rootblock {
    dbg.connect_stmt #dbg.varref<"o"> = #dbg.varref<"en">
  }

  hw.output %en : i1
}

// CHECK: "expressions":
// CHECK-DAG: "expr_c0_guard":
// CHECK-DAG: "expr_c1_guard":

// CHECK: "Parent":
// CHECK:   "body":
// CHECK:     "kind": "connect"

// CHECK: "scope_c0":
// CHECK:   "body":
// CHECK:     "guardRef": "expr_c0_guard"
// CHECK:     "kind": "block"

// CHECK: "scope_c1":
// CHECK:   "body":
// CHECK:     "guardRef": "expr_c1_guard"
// CHECK:     "kind": "block"

// Both sides of the connect name a variable the document has, and each
// subblock points at the expression from its own instance, so nothing is
// reported.
// DIAG-NOT: warning:
