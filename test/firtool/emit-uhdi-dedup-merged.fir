; RUN: firtool -g --emit-uhdi --uhdi-output-file=%t.uhdi.json %s -o %t.sv
; RUN: FileCheck %s --input-file=%t.uhdi.json --implicit-check-not=B.scala \
; RUN:   --implicit-check-not=beta --implicit-check-not='.1"'

; Dedup merges B into A and keeps B's variables for layout 2. Layout 1
; describes A as written, without B's variables.

FIRRTL version 4.0.0
circuit Top:
  module A :
    input p : UInt<8>
    output q : UInt<8>
    node w = add(p, UInt<8>(1)) @[A.scala 5:10]
    intrinsic(circt_debug_var<typeName = "Wire[UInt<8>]", name = "alpha">, w) @[A.scala 5:10]
    connect q, tail(w, 1)

  module B :
    input p : UInt<8>
    output q : UInt<8>
    node w = add(p, UInt<8>(1)) @[B.scala 7:12]
    intrinsic(circt_debug_var<typeName = "Wire[UInt<8>]", name = "beta">, w) @[B.scala 7:12]
    connect q, tail(w, 1)

  public module Top :
    input a : UInt<8>
    output x : UInt<8>
    output y : UInt<8>
    inst ia of A
    inst ib of B
    connect ia.p, a
    connect ib.p, a
    connect x, ia.q
    connect y, ib.q

; CHECK:      "files": [
; CHECK-NEXT:   "A.scala"
; CHECK-NEXT: ]
; CHECK:      "modules": {
; CHECK-NEXT:   "A": {
; CHECK-NEXT:     "variables": {
; CHECK-NEXT:       "alpha": {
; CHECK-NEXT:         "source": {
; CHECK-NEXT:           "loc": {
; CHECK-NEXT:             "beginColumn": 10,
; CHECK-NEXT:             "beginLine": 5,
; CHECK:            "p": {
; CHECK:            "q": {
; CHECK:        "Top": {
