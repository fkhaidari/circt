; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.json %s -o %t.sv
; RUN: FileCheck %s --check-prefix=KEEP --input-file=%t.json
; RUN: sed 's/^circuit Top:$/circuit Top: %%[[{"class":"firrtl.passes.InlineAnnotation","target":"~Top|A"}]]/' %s > %t.inline.fir
; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.inline.json %t.inline.fir -o %t.inline.sv
; RUN: FileCheck %s --check-prefix=INLINE --input-file=%t.inline.json

; Dedup merges B into A. Each instance is still typed by the source module it
; stood for, kept or inlined: types 2 and 3 are modules A and B.

; KEEP:      "types": [
; KEEP:          "kind": "module",
; KEEP-NEXT:     "module": "A"
; KEEP-NEXT:   },
; KEEP-NEXT:   {
; KEEP-NEXT:     "kind": "module",
; KEEP-NEXT:     "module": "B"
; KEEP-NEXT:   }
; KEEP-NEXT: ],
; KEEP:      "Top": {
; KEEP:        "ia": {
; KEEP-NEXT:     "type": 2
; KEEP:        "ib": {
; KEEP-NEXT:     "type": 3
; KEEP:      "original": "Top",
; KEEP:        "ia": {
; KEEP-NEXT:     "$inst": "ia",
; KEEP-NEXT:     "module": "A"
; KEEP:        "ib": {
; KEEP-NEXT:     "$inst": "ib",
; KEEP-NEXT:     "module": "A"

; INLINE:      "types": [
; INLINE:          "kind": "module",
; INLINE-NEXT:     "module": "A"
; INLINE-NEXT:   },
; INLINE-NEXT:   {
; INLINE-NEXT:     "kind": "module",
; INLINE-NEXT:     "module": "B"
; INLINE-NEXT:   }
; INLINE-NEXT: ],
; INLINE:      "Top": {
; INLINE:        "ia": {
; INLINE-NEXT:     "type": 2
; INLINE:        "ib": {
; INLINE-NEXT:     "type": 3
; INLINE:      "original": "Top",
; INLINE:        "ia": {
; INLINE-NEXT:     "$inline": "ia"
; INLINE:        "ib": {
; INLINE-NEXT:     "$inline": "ib"

; INLINE:      "generated": "Top",
; INLINE-NEXT: "original": "A",
; INLINE-NEXT: "scope": "ia",
; INLINE-NEXT: "vars": {
; INLINE-NEXT:   "alpha": "ia_w",
; INLINE-NEXT:   "p": "a",
; INLINE-NEXT:   "q": "x"
; INLINE-NEXT: }
; INLINE:      "generated": "Top",
; INLINE-NEXT: "original": "B",
; INLINE-NEXT: "scope": "ib",
; INLINE-NEXT: "vars": {
; INLINE-NEXT:   "beta": "ib_w",
; INLINE-NEXT:   "p": "a",
; INLINE-NEXT:   "q": "y"
; INLINE-NEXT: }

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
    intrinsic(circt_debug_moduleinfo<typeName = "ClassA", instance = "ia">)
    inst ib of B
    intrinsic(circt_debug_moduleinfo<typeName = "ClassB", instance = "ib">)
    connect ia.p, a
    connect ib.p, a
    connect x, ia.q
    connect y, ib.q
