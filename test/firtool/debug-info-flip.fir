; RUN: firtool -g --ir-hw %s | circt-translate --emit-uhdi --uhdi-indent=0 | FileCheck %s

; A flipped bundle field keeps its flip through lowering.

; CHECK:      "types":[{"kind":"uint","width":1},
; CHECK-SAME: {"fields":[{"name":"x","type":0},{"flip":true,"name":"y","type":0}],"kind":"struct"},

; A flip inside a flipped field keeps its own flag.

; CHECK:      {"fields":[{"name":"b","type":0},{"flip":true,"name":"c","type":0}],"kind":"struct"},
; CHECK-SAME: {"fields":[{"name":"x","type":0},{"flip":true,"name":"a","type":2}],"kind":"struct"}]

; Output ports refer to the bundle types above.

; CHECK:      "original":{"Top":{
; CHECK-SAME: "fl":{"type":1,
; CHECK-SAME: "dir":"out"},
; CHECK-SAME: "nf":{"type":3,
; CHECK-SAME: "dir":"out"}

FIRRTL version 4.0.0
circuit Top:
  public module Top:
    input sel: UInt<1>
    output fl: { x: UInt<1>, flip y: UInt<1> }
    output nf: { x: UInt<1>, flip a: { b: UInt<1>, flip c: UInt<1> } }
    connect fl.x, sel
    connect nf.x, sel
    connect nf.a.c, sel
