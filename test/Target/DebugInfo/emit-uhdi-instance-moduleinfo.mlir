// RUN: circt-translate %s --emit-uhdi 2>/dev/null | FileCheck %s

// The source-language class of an instantiated module rides on the instance.
// Deduplication merges structurally equal definitions, so a definition cannot
// say which class it came from; an instantiation site can. A module with no
// instantiation site keeps its own record.

hw.module private @Alu(in %a : i8, out q : i8) {
  hw.output %a : i8
}

hw.module @Cpu(in %a : i8, out q : i8)
    attributes {dbg.moduleinfo = {params = [], typeName = "Cpu"}} {
  %alu.q = hw.instance "alu" @Alu(a: %a: i8) -> (q: i8)
      {dbg.moduleinfo = {params = [{name = "width", typeName = "Int",
                                    value = "8"}],
                         typeName = "Alu"}}
  hw.output %alu.q : i8
}

// CHECK:      "modules":
// CHECK:        "Alu":
// CHECK-NOT:      "typeName"
// CHECK:        "Cpu":
// CHECK:          "source":
// CHECK:            "x-chisel":
// CHECK-NEXT:         "typeName": "Cpu"
// CHECK:          "instances":
// CHECK:            "alu":
// CHECK-NEXT:         "moduleRef": "Alu"
// CHECK:              "source":
// CHECK:                "x-chisel":
// CHECK-NEXT:             "params":
// CHECK:                  "name": "width"
// CHECK-NEXT:             "type": "Int"
// CHECK-NEXT:             "value": "8"
// CHECK:                "typeName": "Alu"
