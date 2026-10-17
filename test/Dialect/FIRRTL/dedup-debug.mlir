// RUN: circt-opt --firrtl-dedup %s | FileCheck %s

// The debug ops of a deduplicated module are cloned into the module that
// replaces it. Root ops record the module they came from in `dbg.origin`, and
// the kept module records the merged ones in `dbg.origins`.

// CHECK: #[[LOCB:loc[0-9]*]] = loc("B.scala":7:12)
// CHECK: #[[LOCD:loc[0-9]*]] = loc("D.scala":1:1)

// CHECK-LABEL: firrtl.circuit "Scalar"
firrtl.circuit "Scalar" {
  // CHECK:      firrtl.module private @A(in %p: !firrtl.uint<8>, out %q: !firrtl.uint<8>)
  // CHECK-SAME:     attributes {dbg.origins = {B = {loc = #[[LOCB]]}}}
  // CHECK-NEXT:   %w = firrtl.node %p
  // CHECK-NEXT:   dbg.variable "alpha", %w : !firrtl.uint<8>
  // CHECK-NEXT:   dbg.variable "beta", %w {dbg.origin = "B"} : !firrtl.uint<8>
  // CHECK-NEXT:   dbg.variable "port", %p {dbg.origin = "B"} : !firrtl.uint<8>
  // CHECK-NEXT:   firrtl.matchingconnect %q, %w
  firrtl.module private @A(in %p: !firrtl.uint<8>, out %q: !firrtl.uint<8>) {
    %w = firrtl.node %p : !firrtl.uint<8>
    dbg.variable "alpha", %w : !firrtl.uint<8>
    firrtl.matchingconnect %q, %w : !firrtl.uint<8>
  } loc("A.scala":5:10)
  // CHECK-NOT: firrtl.module private @B
  firrtl.module private @B(in %p: !firrtl.uint<8>, out %q: !firrtl.uint<8>) {
    %w = firrtl.node %p : !firrtl.uint<8>
    dbg.variable "beta", %w : !firrtl.uint<8>
    dbg.variable "port", %p : !firrtl.uint<8>
    firrtl.matchingconnect %q, %w : !firrtl.uint<8>
  } loc("B.scala":7:12)
  firrtl.module @Scalar() {
    firrtl.instance a @A(in p: !firrtl.uint<8>, out q: !firrtl.uint<8>)
    firrtl.instance b @B(in p: !firrtl.uint<8>, out q: !firrtl.uint<8>)
  }
}

// A chain of debug ops is cloned with its operands remapped.
// CHECK-LABEL: firrtl.circuit "Aggregate"
firrtl.circuit "Aggregate" {
  // CHECK:      firrtl.module private @A(in %p: !firrtl.uint<8>, out %q: !firrtl.uint<8>)
  // CHECK-NEXT:   %w = firrtl.wire
  // CHECK-NEXT:   [[V:%.+]] = dbg.value %w typeName "UInt<8>"
  // CHECK-NEXT:   [[S:%.+]] = dbg.struct {"x": [[V]], "y": %p}
  // CHECK-NEXT:   dbg.variable "io", [[S]] {dbg.origin = "B"}
  // CHECK-NEXT:   firrtl.matchingconnect %w, %p
  firrtl.module private @A(in %p: !firrtl.uint<8>, out %q: !firrtl.uint<8>) {
    %w = firrtl.wire : !firrtl.uint<8>
    firrtl.matchingconnect %w, %p : !firrtl.uint<8>
    firrtl.matchingconnect %q, %w : !firrtl.uint<8>
  }
  // CHECK-NOT: firrtl.module private @B
  firrtl.module private @B(in %p: !firrtl.uint<8>, out %q: !firrtl.uint<8>) {
    %w = firrtl.wire : !firrtl.uint<8>
    %v = dbg.value %w typeName "UInt<8>" : !firrtl.uint<8>
    %s = dbg.struct {"x": %v, "y": %p} : !dbg.value, !firrtl.uint<8>
    dbg.variable "io", %s : !dbg.struct
    firrtl.matchingconnect %w, %p : !firrtl.uint<8>
    firrtl.matchingconnect %q, %w : !firrtl.uint<8>
  }
  firrtl.module @Aggregate() {
    firrtl.instance a @A(in p: !firrtl.uint<8>, out q: !firrtl.uint<8>)
    firrtl.instance b @B(in p: !firrtl.uint<8>, out q: !firrtl.uint<8>)
  }
}

// CHECK-LABEL: firrtl.circuit "Enum"
firrtl.circuit "Enum" {
  // CHECK:      firrtl.module private @A(in %p: !firrtl.uint<2>)
  // CHECK-NEXT:   [[E:%.+]] = dbg.enum %p, "State", {Busy = 1 : i64, Idle = 0 : i64}
  // CHECK-NEXT:   dbg.variable "state", [[E]] {dbg.origin = "B"} : !dbg.enum
  firrtl.module private @A(in %p: !firrtl.uint<2>) {}
  // CHECK-NOT: firrtl.module private @B
  firrtl.module private @B(in %p: !firrtl.uint<2>) {
    %e = dbg.enum %p, "State", {Idle = 0 : i64, Busy = 1 : i64} : !firrtl.uint<2>
    dbg.variable "state", %e : !dbg.enum
  }
  firrtl.module @Enum() {
    firrtl.instance a @A(in p: !firrtl.uint<2>)
    firrtl.instance b @B(in p: !firrtl.uint<2>)
  }
}

// The class info of the merged module lands in `dbg.origins`, even if it has
// no debug ops. The kept module keeps its own.
// CHECK-LABEL: firrtl.circuit "ModuleInfo"
firrtl.circuit "ModuleInfo" {
  // CHECK:      firrtl.module private @A()
  // CHECK-SAME:   dbg.moduleinfo = {typeName = "ClassA"}
  // CHECK-SAME:   dbg.origins = {B = {loc = {{.+}}, moduleinfo = {typeName = "ClassB"}}}
  firrtl.module private @A() attributes {dbg.moduleinfo = {typeName = "ClassA"}} {}
  // CHECK-NOT: firrtl.module private @B
  firrtl.module private @B() attributes {dbg.moduleinfo = {typeName = "ClassB"}} {}
  firrtl.module @ModuleInfo() {
    firrtl.instance a @A()
    firrtl.instance b @B()
  }
}

// Class info already moved onto the instances is taken back from there.
// CHECK-LABEL: firrtl.circuit "InstanceInfo"
firrtl.circuit "InstanceInfo" {
  // CHECK:      firrtl.module private @A()
  // CHECK-SAME:   dbg.origins = {B = {loc = {{.+}}, moduleinfo = {typeName = "ClassB"}}}
  firrtl.module private @A() {}
  firrtl.module private @B() {}
  firrtl.module @InstanceInfo() {
    // CHECK: firrtl.instance a {dbg.moduleinfo = {typeName = "ClassA"}} @A()
    // CHECK: firrtl.instance b {dbg.moduleinfo = {typeName = "ClassB"}} @A()
    firrtl.instance a {dbg.moduleinfo = {typeName = "ClassA"}} @A()
    firrtl.instance b {dbg.moduleinfo = {typeName = "ClassB"}} @B()
    firrtl.instance b2 {dbg.moduleinfo = {typeName = "ClassB"}} @B()
  }
}

// Three equal modules all merge into the first one. A merged module that kept
// other modules earlier passes on their `dbg.origins` and `dbg.origin` tags.
// CHECK-LABEL: firrtl.circuit "Chain"
firrtl.circuit "Chain" {
  // CHECK:      firrtl.module private @A()
  // CHECK-SAME:   dbg.origins = {B = {loc = {{.+}}}, C = {loc = {{.+}}}, D = {loc = #[[LOCD]], moduleinfo = {typeName = "ClassD"}}}
  // CHECK-NEXT:   firrtl.constant
  // CHECK-NEXT:   dbg.variable "a", {{%.+}} : !firrtl.uint<1>
  // CHECK-NEXT:   dbg.variable "b", {{%.+}} {dbg.origin = "B"}
  // CHECK-NEXT:   dbg.variable "d", {{%.+}} {dbg.origin = "D"}
  // CHECK-NEXT:   dbg.variable "c", {{%.+}} {dbg.origin = "C"}
  firrtl.module private @A() {
    %c = firrtl.constant 0 : !firrtl.uint<1>
    dbg.variable "a", %c : !firrtl.uint<1>
  }
  // CHECK-NOT: firrtl.module private @B
  firrtl.module private @B() {
    %c = firrtl.constant 0 : !firrtl.uint<1>
    dbg.variable "b", %c : !firrtl.uint<1>
  }
  // CHECK-NOT: firrtl.module private @C
  firrtl.module private @C() attributes {
      dbg.origins = {D = {loc = loc("D.scala":1:1), moduleinfo = {typeName = "ClassD"}}}} {
    %c = firrtl.constant 0 : !firrtl.uint<1>
    dbg.variable "d", %c {dbg.origin = "D"} : !firrtl.uint<1>
    dbg.variable "c", %c : !firrtl.uint<1>
  }
  firrtl.module @Chain() {
    firrtl.instance a @A()
    firrtl.instance b @B()
    firrtl.instance c @C()
  }
}

// Debug ops inside nested regions may use debug ops of the enclosing block.
// Parents that become equal after their children merged dedup in turn.
// CHECK-LABEL: firrtl.circuit "Nested"
firrtl.circuit "Nested" {
  // CHECK:      firrtl.module private @A(in %c: !firrtl.uint<1>, in %p: !firrtl.uint<8>)
  // CHECK-NEXT:   [[SCOPE:%.+]] = dbg.scope "inner", "Inner" {dbg.origin = "B"}
  // CHECK-NEXT:   [[SUB:%.+]] = dbg.scope "sub", "Sub" scope [[SCOPE]]{{$}}
  // CHECK-NEXT:   firrtl.when %c
  // CHECK-NEXT:     %w = firrtl.node %p
  // CHECK-NEXT:     dbg.variable "w", %w scope [[SUB]] {dbg.origin = "B"}
  firrtl.module private @A(in %c: !firrtl.uint<1>, in %p: !firrtl.uint<8>) {
    firrtl.when %c : !firrtl.uint<1> {
      %w = firrtl.node %p : !firrtl.uint<8>
    }
  }
  // CHECK-NOT: firrtl.module private @B
  firrtl.module private @B(in %c: !firrtl.uint<1>, in %p: !firrtl.uint<8>) {
    %scope = dbg.scope "inner", "Inner"
    %sub = dbg.scope "sub", "Sub" scope %scope
    firrtl.when %c : !firrtl.uint<1> {
      %w = firrtl.node %p : !firrtl.uint<8>
      dbg.variable "w", %w scope %sub : !firrtl.uint<8>
    }
  }
  // CHECK:      firrtl.module private @PA()
  // CHECK-SAME:   dbg.origins = {PB = {loc = {{.+}}}}
  // CHECK-NEXT:   %x_c, %x_p = firrtl.instance x @A
  // CHECK-NEXT:   dbg.variable "pa", %x_p : !firrtl.uint<8>
  // CHECK-NEXT:   dbg.variable "pb", %x_p {dbg.origin = "PB"} : !firrtl.uint<8>
  firrtl.module private @PA() {
    %x_c, %x_p = firrtl.instance x @A(in c: !firrtl.uint<1>, in p: !firrtl.uint<8>)
    dbg.variable "pa", %x_p : !firrtl.uint<8>
  }
  // CHECK-NOT: firrtl.module private @PB
  firrtl.module private @PB() {
    %x_c, %x_p = firrtl.instance x @B(in c: !firrtl.uint<1>, in p: !firrtl.uint<8>)
    dbg.variable "pb", %x_p : !firrtl.uint<8>
  }
  firrtl.module @Nested() {
    firrtl.instance pa @PA()
    firrtl.instance pb @PB()
  }
}

// Nothing is recorded when neither module has debug info.
// CHECK-LABEL: firrtl.circuit "NoDebug"
firrtl.circuit "NoDebug" {
  // CHECK: firrtl.module private @A() {
  firrtl.module private @A() {}
  firrtl.module private @B() {}
  firrtl.module @NoDebug() {
    firrtl.instance a @A()
    firrtl.instance b @B()
  }
}
