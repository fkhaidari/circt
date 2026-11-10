// RUN: circt-opt --split-input-file --pass-pipeline='builtin.module(firrtl.circuit(firrtl.module(firrtl-lower-intrinsics{emit-debug-info=true})))' %s | FileCheck %s --implicit-check-not=firrtl.int.generic --implicit-check-not='!firrtl.uint<0>'

// The module from the debug intrinsics spec, plus one case per leaf root.
firrtl.circuit "Alu" {
  firrtl.layer @A bind {
  }
  // CHECK-LABEL: firrtl.module @Alu
  firrtl.module @Alu(in %clock: !firrtl.clock, out %io: !firrtl.bundle<a: uint<8>, b flip: uint<8>, c: bundle<d: sint<4>>>, in %opcode: !firrtl.uint<1>, in %an: !firrtl.analog<1>) {
    // CHECK: [[IO_C:%.+]] = firrtl.subfield %io[c]
    // CHECK: [[IO_C_D:%.+]] = firrtl.subfield [[IO_C]][d]
    // CHECK: [[IO_B:%.+]] = firrtl.subfield %io[b]
    // CHECK: [[IO_A:%.+]] = firrtl.subfield %io[a]
    %0 = firrtl.subfield %io[c] : !firrtl.bundle<a: uint<8>, b flip: uint<8>, c: bundle<d: sint<4>>>
    %1 = firrtl.subfield %0[d] : !firrtl.bundle<d: sint<4>>
    %2 = firrtl.subfield %io[b] : !firrtl.bundle<a: uint<8>, b flip: uint<8>, c: bundle<d: sint<4>>>
    %3 = firrtl.subfield %io[a] : !firrtl.bundle<a: uint<8>, b flip: uint<8>, c: bundle<d: sint<4>>>

    // CHECK-NEXT: dbg.moduleinfo "Alu" params ["{\22x-chisel\22:{\22params\22:[{\22name\22:\22width\22,\22value\22:\228\22}]}}"]
    firrtl.int.generic "circt_debug_moduleinfo" <typeName: none = "Alu", params: none = "{\22x-chisel\22:{\22params\22:[{\22name\22:\22width\22,\22value\22:\228\22}]}}"> : () -> ()

    // CHECK-NEXT: [[A:%.+]] = dbg.value [[IO_A]] typeName "UInt<8>" : !firrtl.uint<8>
    // CHECK-NEXT: [[B:%.+]] = dbg.value [[IO_B]] typeName "UInt<8>" : !firrtl.uint<8>
    // CHECK-NEXT: [[D:%.+]] = dbg.value [[IO_C_D]] typeName "SInt<4>" : !firrtl.sint<4>
    // CHECK-NEXT: [[CS:%.+]] = dbg.struct {"d": [[D]]} : !dbg.value
    // CHECK-NEXT: [[C:%.+]] = dbg.value [[CS]] typeName "Inner" : !dbg.struct
    // CHECK-NEXT: [[S:%.+]] = dbg.struct {"a": [[A]], "b": [[B]], "c": [[C]]} {flips = array<i1: false, true, false>}
    // CHECK-NEXT: [[IO:%.+]] = dbg.value [[S]] typeName "AluIO" : !dbg.struct
    // CHECK-NEXT: dbg.variable "io", [[IO]] kind output : !dbg.value
    %4 = firrtl.int.generic "circt_debug_value" <name: none = "a", typeName: none = "UInt<8>"> %3 : (!firrtl.uint<8>) -> !firrtl.uint<0>
    %io_a = firrtl.node interesting_name %4 : !firrtl.uint<0>
    %5 = firrtl.int.generic "circt_debug_value" <name: none = "b", flip: ui32 = 1, typeName: none = "UInt<8>"> %2 : (!firrtl.uint<8>) -> !firrtl.uint<0>
    %io_b = firrtl.node interesting_name %5 : !firrtl.uint<0>
    %6 = firrtl.int.generic "circt_debug_value" <name: none = "d", typeName: none = "SInt<4>"> %1 : (!firrtl.sint<4>) -> !firrtl.uint<0>
    %io_c_d = firrtl.node interesting_name %6 : !firrtl.uint<0>
    %7 = firrtl.int.generic "circt_debug_struct"  %io_c_d : (!firrtl.uint<0>) -> !firrtl.uint<0>
    %io_c_s = firrtl.node interesting_name %7 : !firrtl.uint<0>
    %8 = firrtl.int.generic "circt_debug_value" <name: none = "c", typeName: none = "Inner"> %io_c_s : (!firrtl.uint<0>) -> !firrtl.uint<0>
    %io_c = firrtl.node interesting_name %8 : !firrtl.uint<0>
    %9 = firrtl.int.generic "circt_debug_struct"  %io_a, %io_b, %io_c : (!firrtl.uint<0>, !firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
    %io_s = firrtl.node interesting_name %9 : !firrtl.uint<0>
    %10 = firrtl.int.generic "circt_debug_value" <typeName: none = "AluIO"> %io_s : (!firrtl.uint<0>) -> !firrtl.uint<0>
    %io_h = firrtl.node interesting_name %10 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "io"> %io_h : (!firrtl.uint<0>) -> ()

    // Enum tags are re-typed to signless i64.
    // CHECK-NEXT: %op = firrtl.node
    // CHECK-NEXT: [[OP:%.+]] = dbg.enum %op, "AluOp", {ADD = 0 : i64, SUB = 1 : i64} fqn "alu.AluOp" : !firrtl.uint<1>
    // CHECK-NEXT: dbg.variable "op", [[OP]] kind node : !dbg.enum
    %op = firrtl.node interesting_name %opcode : !firrtl.uint<1>
    %11 = firrtl.int.generic "circt_debug_enum" <typeName: none = "AluOp", fqn: none = "alu.AluOp", variant_ADD: ui32 = 0, variant_SUB: ui32 = 1> %op : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %op_h = firrtl.node interesting_name %11 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "op"> %op_h : (!firrtl.uint<0>) -> ()

    // A chain of alias nodes, and a variable that takes the value directly.
    // CHECK: %acc = firrtl.regreset
    // CHECK-NEXT: [[ACC:%.+]] = dbg.value %acc typeName "UInt<8>" : !firrtl.uint<8>
    // CHECK-NEXT: dbg.variable "acc", [[ACC]] kind reg : !dbg.value
    // CHECK-NEXT: dbg.variable "acc_direct", %acc kind reg : !firrtl.uint<8>
    %c0_ui1 = firrtl.constant 0 : !firrtl.const.uint<1>
    %c0_ui8 = firrtl.constant 0 : !firrtl.const.uint<8>
    %acc = firrtl.regreset interesting_name %clock, %c0_ui1, %c0_ui8 : !firrtl.clock, !firrtl.const.uint<1>, !firrtl.const.uint<8>, !firrtl.uint<8>
    %12 = firrtl.int.generic "circt_debug_value" <typeName: none = "UInt<8>"> %acc : (!firrtl.uint<8>) -> !firrtl.uint<0>
    %acc_h = firrtl.node interesting_name %12 : !firrtl.uint<0>
    %acc_h2 = firrtl.node interesting_name %acc_h : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "acc"> %acc_h2 : (!firrtl.uint<0>) -> ()
    firrtl.int.generic "circt_debug_var" <name: none = "acc_direct"> %acc : (!firrtl.uint<8>) -> ()

    // An empty wrapper lowers to its operand.
    // CHECK-NEXT: %r = firrtl.reg
    // CHECK-NEXT: dbg.variable "r", %r kind reg : !firrtl.uint<1>
    %r = firrtl.reg interesting_name %clock : !firrtl.clock, !firrtl.uint<1>
    %13 = firrtl.int.generic "circt_debug_value"  %r : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %r_h = firrtl.node interesting_name %13 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "r"> %r_h : (!firrtl.uint<0>) -> ()

    // An empty wrapper still gives its field name to the struct.
    // CHECK-NEXT: %w = firrtl.wire
    // CHECK-NEXT: [[W_Y:%.+]] = firrtl.subfield %w[y]
    // CHECK-NEXT: [[W_X:%.+]] = firrtl.subfield %w[x]
    // CHECK-NEXT: [[Y:%.+]] = dbg.value [[W_Y]] typeName "UInt<2>"
    // CHECK-NEXT: [[WS:%.+]] = dbg.struct {"x": [[W_X]], "y": [[Y]]} : !firrtl.uint<1>, !dbg.value
    // CHECK-NEXT: dbg.variable "w", [[WS]] kind wire : !dbg.struct
    %w = firrtl.wire interesting_name : !firrtl.bundle<x: uint<1>, y: uint<2>>
    %14 = firrtl.subfield %w[y] : !firrtl.bundle<x: uint<1>, y: uint<2>>
    %15 = firrtl.subfield %w[x] : !firrtl.bundle<x: uint<1>, y: uint<2>>
    %16 = firrtl.int.generic "circt_debug_value" <name: none = "x"> %15 : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %w_x = firrtl.node interesting_name %16 : !firrtl.uint<0>
    %17 = firrtl.int.generic "circt_debug_value" <name: none = "y", typeName: none = "UInt<2>"> %14 : (!firrtl.uint<2>) -> !firrtl.uint<0>
    %w_y = firrtl.node interesting_name %17 : !firrtl.uint<0>
    %18 = firrtl.int.generic "circt_debug_struct"  %w_x, %w_y : (!firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
    %w_s = firrtl.node interesting_name %18 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "w"> %w_s : (!firrtl.uint<0>) -> ()

    // Arrays; a dynamic index leaves the kind unknown.
    // CHECK-NEXT: %v = firrtl.wire
    // CHECK-NEXT: [[V1:%.+]] = firrtl.subindex %v[1]
    // CHECK-NEXT: [[V0:%.+]] = firrtl.subindex %v[0]
    // CHECK-NEXT: [[E0:%.+]] = dbg.value [[V0]] typeName "UInt<4>"
    // CHECK-NEXT: [[E1:%.+]] = dbg.value [[V1]] typeName "UInt<4>"
    // CHECK-NEXT: [[ARR:%.+]] = dbg.array [[[E0]], [[E1]]] : !dbg.value
    // CHECK-NEXT: dbg.variable "v", [[ARR]] kind wire : !dbg.array
    // CHECK-NEXT: [[DYN:%.+]] = firrtl.subaccess %v[%opcode]
    // CHECK-NEXT: dbg.variable "v_dyn", [[DYN]] : !firrtl.uint<4>
    %v = firrtl.wire interesting_name : !firrtl.vector<uint<4>, 2>
    %19 = firrtl.subindex %v[1] : !firrtl.vector<uint<4>, 2>
    %20 = firrtl.subindex %v[0] : !firrtl.vector<uint<4>, 2>
    %21 = firrtl.int.generic "circt_debug_value" <typeName: none = "UInt<4>"> %20 : (!firrtl.uint<4>) -> !firrtl.uint<0>
    %v_0 = firrtl.node interesting_name %21 : !firrtl.uint<0>
    %22 = firrtl.int.generic "circt_debug_value" <typeName: none = "UInt<4>"> %19 : (!firrtl.uint<4>) -> !firrtl.uint<0>
    %v_1 = firrtl.node interesting_name %22 : !firrtl.uint<0>
    %23 = firrtl.int.generic "circt_debug_array"  %v_0, %v_1 : (!firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
    %v_a = firrtl.node interesting_name %23 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "v"> %v_a : (!firrtl.uint<0>) -> ()
    %24 = firrtl.subaccess %v[%opcode] : !firrtl.vector<uint<4>, 2>, !firrtl.uint<1>
    firrtl.int.generic "circt_debug_var" <name: none = "v_dyn"> %24 : (!firrtl.uint<4>) -> ()

    // A zero-width wire is a leaf, not a handle.
    // CHECK-NEXT: %zero = firrtl.wire interesting_name : !firrtl.uint<0>
    // CHECK-NEXT: [[ZERO:%.+]] = dbg.value %zero typeName "UInt<0>" : !firrtl.uint<0>
    // CHECK-NEXT: dbg.variable "zero", [[ZERO]] kind wire : !dbg.value
    // CHECK-NEXT: dbg.variable "zero_direct", %zero kind wire : !firrtl.uint<0>
    %zero = firrtl.wire interesting_name : !firrtl.uint<0>
    %25 = firrtl.int.generic "circt_debug_value" <typeName: none = "UInt<0>"> %zero : (!firrtl.uint<0>) -> !firrtl.uint<0>
    %zero_h = firrtl.node interesting_name %25 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "zero"> %zero_h : (!firrtl.uint<0>) -> ()
    firrtl.int.generic "circt_debug_var" <name: none = "zero_direct"> %zero : (!firrtl.uint<0>) -> ()

    // An empty aggregate has no leaf, so no kind.
    // CHECK-NEXT: [[EMPTY:%.+]] = dbg.struct {}
    // CHECK-NEXT: dbg.variable "empty", [[EMPTY]] : !dbg.struct
    %26 = firrtl.int.generic "circt_debug_struct"  : () -> !firrtl.uint<0>
    %empty = firrtl.node interesting_name %26 : !firrtl.uint<0>
    firrtl.int.generic "circt_debug_var" <name: none = "empty"> %empty : (!firrtl.uint<0>) -> ()

    // CHECK-NEXT: dbg.variable "an", %an kind inout : !firrtl.analog<1>
    firrtl.int.generic "circt_debug_var" <name: none = "an"> %an : (!firrtl.analog<1>) -> ()

    // Nested regions are converted in place.
    // CHECK-NEXT: firrtl.when
    // CHECK-NEXT: %inner = firrtl.wire
    // CHECK-NEXT: dbg.variable "inner", %inner kind wire : !firrtl.uint<1>
    firrtl.when %opcode : !firrtl.uint<1> {
      %inner = firrtl.wire interesting_name : !firrtl.uint<1>
      firrtl.int.generic "circt_debug_var" <name: none = "inner"> %inner : (!firrtl.uint<1>) -> ()
    }
    // CHECK: firrtl.layerblock @A
    // CHECK: %sum = firrtl.node
    // CHECK-NEXT: dbg.variable "sum", %sum kind node : !firrtl.uint<9>
    firrtl.layerblock @A {
      %27 = firrtl.add %acc, %acc : (!firrtl.uint<8>, !firrtl.uint<8>) -> !firrtl.uint<9>
      %sum = firrtl.node interesting_name %27 : !firrtl.uint<9>
      firrtl.int.generic "circt_debug_var" <name: none = "sum"> %sum : (!firrtl.uint<9>) -> ()
    }
  }
}

// -----

// The flip check follows the FIRRTL type of an input port too, and a flipped
// struct gives its flip to every leaf below it.
// CHECK-LABEL: firrtl.module @Flips
firrtl.circuit "Flips" {
  firrtl.module @Flips(in %in: !firrtl.bundle<x flip: bundle<y: uint<1>, z flip: uint<1>>>) {
    %x = firrtl.subfield %in[x] : !firrtl.bundle<x flip: bundle<y: uint<1>, z flip: uint<1>>>
    %y = firrtl.subfield %x[y] : !firrtl.bundle<y: uint<1>, z flip: uint<1>>
    %z = firrtl.subfield %x[z] : !firrtl.bundle<y: uint<1>, z flip: uint<1>>
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "y"> %y : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_value" <name: none = "z", flip: ui32 = 1> %z : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %2 = firrtl.int.generic "circt_debug_struct" <name: none = "x", flip: ui32 = 1> %0, %1 : (!firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
    %3 = firrtl.int.generic "circt_debug_struct" %2 : (!firrtl.uint<0>) -> !firrtl.uint<0>
    // CHECK: [[X:%.+]] = dbg.struct {"y": {{%.+}}, "z": {{%.+}}} {flips = array<i1: false, true>}
    // CHECK: [[IN:%.+]] = dbg.struct {"x": [[X]]} {flips = array<i1: true>}
    // CHECK: dbg.variable "in", [[IN]] kind input
    firrtl.int.generic "circt_debug_var" <name: none = "in"> %3 : (!firrtl.uint<0>) -> ()
  }
}

// -----

// A port with an Analog leaf is an inout, whatever its root type.
// CHECK-LABEL: firrtl.module @AnalogField
firrtl.circuit "AnalogField" {
  firrtl.module @AnalogField(in %p: !firrtl.bundle<a: analog<1>, b: uint<1>>) {
    %a = firrtl.subfield %p[a] : !firrtl.bundle<a: analog<1>, b: uint<1>>
    %b = firrtl.subfield %p[b] : !firrtl.bundle<a: analog<1>, b: uint<1>>
    %0 = firrtl.int.generic "circt_debug_value" <name: none = "a"> %a : (!firrtl.analog<1>) -> !firrtl.uint<0>
    %1 = firrtl.int.generic "circt_debug_value" <name: none = "b"> %b : (!firrtl.uint<1>) -> !firrtl.uint<0>
    %2 = firrtl.int.generic "circt_debug_struct" %0, %1 : (!firrtl.uint<0>, !firrtl.uint<0>) -> !firrtl.uint<0>
    // CHECK: dbg.variable "p", {{%.+}} kind inout
    firrtl.int.generic "circt_debug_var" <name: none = "p"> %2 : (!firrtl.uint<0>) -> ()
  }
}
