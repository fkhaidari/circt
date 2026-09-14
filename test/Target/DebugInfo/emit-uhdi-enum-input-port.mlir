// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// An enum-typed input port reaches the variable through a `dbg.enum` cast on
// top of the block argument. The port check has to look through the cast, or
// the variable loses its direction and a second, synthesized record for the
// same port shows up under a suffixed key.

hw.module @Fsm(in %in : i2, out out : i2) attributes {dbg.moduleinfo = {typeName = "Fsm"}} {
  %e = dbg.enum %in, "State", {idle = 0 : i2, run = 1 : i2} fqn "pkg.State" : i2
  %v = dbg.value %e typeName "IO[State]" : !dbg.enum
  dbg.variable "in", %v : !dbg.value
  hw.output %in : i2
}

// CHECK:      "variables":
// CHECK-NEXT:   "in":
// CHECK-NEXT:     "direction": "input"
// CHECK:          "typeRef": "pkg.State"
// CHECK-NOT:    "in.1"
// CHECK:        "out":
// CHECK-NEXT:     "direction": "output"
