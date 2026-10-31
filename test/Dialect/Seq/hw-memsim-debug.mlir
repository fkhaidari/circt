// RUN: circt-opt -hw-memory-sim %s | FileCheck %s
// RUN: circt-opt -hw-memory-sim=repl-seq-mem %s | FileCheck %s --check-prefix=REPL

// A memory module that debug info describes gets a variable for its contents.

hw.generator.schema @FIRRTLMem, "FIRRTL_Memory", ["depth", "numReadPorts", "numWritePorts", "numReadWritePorts", "readLatency", "writeLatency", "width", "readUnderWrite", "writeUnderWrite", "writeClockIDs", "initFilename", "initIsBinary", "initIsInline"]

sv.macro.decl @RANDOM
sv.macro.decl @ENABLE_INITIAL_MEM_
sv.macro.decl @RANDOMIZE_REG_INIT
sv.macro.decl @RANDOMIZE_MEM_INIT

// A memory replaced by an external module has no contents to describe.

// REPL: hw.module.extern @described({{.*}}) attributes {dbg.lowered}
// REPL: hw.module.extern @plain({{.*}}){{$}}

// CHECK-LABEL: hw.module private @described
// CHECK:         %Memory = sv.reg : !hw.inout<uarray<16xi8>>
// CHECK-NEXT:    dbg.variable "Memory", %Memory mem : !hw.inout<uarray<16xi8>>
hw.module.generated @described, @FIRRTLMem(in %R0_addr: i4, in %R0_en: i1, in %R0_clk: i1, out R0_data: i8) attributes {dbg.memory, depth = 16 : i64, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 0 : ui32, readLatency = 1 : ui32, readUnderWrite = 0 : i32, width = 8 : ui32, writeClockIDs = [], writeLatency = 1 : ui32, writeUnderWrite = 0 : i32, initFilename = "", initIsBinary = false, initIsInline = false}

// CHECK-LABEL: hw.module private @plain
// CHECK-NOT:     dbg.variable
// CHECK:         hw.output
hw.module.generated @plain, @FIRRTLMem(in %R0_addr: i4, in %R0_en: i1, in %R0_clk: i1, out R0_data: i8) attributes {depth = 16 : i64, numReadPorts = 1 : ui32, numReadWritePorts = 0 : ui32, numWritePorts = 0 : ui32, readLatency = 1 : ui32, readUnderWrite = 0 : i32, width = 8 : ui32, writeClockIDs = [], writeLatency = 1 : ui32, writeUnderWrite = 0 : i32, initFilename = "", initIsBinary = false, initIsInline = false}
