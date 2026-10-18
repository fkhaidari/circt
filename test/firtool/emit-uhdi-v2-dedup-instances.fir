; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.json %s -o %t.sv
; RUN: FileCheck %s --check-prefix=KEEP --input-file=%t.json
; RUN: sed 's/^circuit Top:$/circuit Top: %%[[{"class":"firrtl.passes.InlineAnnotation","target":"~Top|A"}]]/' %s > %t.inline.fir
; RUN: firtool -g --emit-uhdi --uhdi-format=2 --uhdi-output-file=%t.inline.json %t.inline.fir -o %t.inline.sv
; RUN: FileCheck %s --check-prefix=INLINE --input-file=%t.inline.json

; Dedup merges B into A. Each instance still names the source module it stood
; for, kept or inlined.

; KEEP:      "ia": {
; KEEP-NEXT:   "module": "A",
; KEEP-NEXT:   "source": "A"
; KEEP:      "ib": {
; KEEP-NEXT:   "module": "A",
; KEEP-NEXT:   "source": "B"

; INLINE:      "scope": "ia",
; INLINE-NEXT: "source": "A",
; INLINE-NEXT: "target": "Top",
; INLINE-NEXT: "vars": {
; INLINE-NEXT:   "alpha": "ia_w",
; INLINE-NEXT:   "p": "a",
; INLINE-NEXT:   "q": "x"
; INLINE-NEXT: }
; INLINE:      "scope": "ib",
; INLINE-NEXT: "source": "B",
; INLINE-NEXT: "target": "Top",
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
    intrinsic(circt_debug_moduleinfo<typeName = "ClassA">)
    intrinsic(circt_debug_var<typeName = "Wire[UInt<8>]", name = "alpha">, w) @[A.scala 5:10]
    connect q, tail(w, 1)

  module B :
    input p : UInt<8>
    output q : UInt<8>
    node w = add(p, UInt<8>(1)) @[B.scala 7:12]
    intrinsic(circt_debug_moduleinfo<typeName = "ClassB">)
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
