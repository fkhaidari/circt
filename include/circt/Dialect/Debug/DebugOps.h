//===- DebugOps.h - Debug dialect operations ====----------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_DEBUG_DEBUGOPS_H
#define CIRCT_DIALECT_DEBUG_DEBUGOPS_H

#include "mlir/Bytecode/BytecodeOpInterface.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/Interfaces/InferTypeOpInterface.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

#include "circt/Dialect/Debug/DebugDialect.h"
#include "circt/Dialect/Debug/DebugTypes.h"

// Operation definitions generated from `Debug.td`
#define GET_OP_CLASSES
#include "circt/Dialect/Debug/Debug.h.inc"

namespace circt::debug {

/// The key EmitUHDI files the Verilog binding under.
inline constexpr llvm::StringLiteral kUhdiVerilogRepr = "verilog";

/// Source-level type name and constructor parameters of a module. The
/// `circt_debug_moduleinfo` intrinsic stamps it on each instance of the module,
/// since the class belongs to the instantiation and dedup may merge two classes
/// into one module; only the top module carries it on the module op. An inlined
/// instance carries it on its `dbg.scope`, whose module op no longer exists.
inline constexpr llvm::StringLiteral kDbgModuleInfoAttr = "dbg.moduleinfo";

/// Which fields of a `dbg.struct` are flipped relative to the struct, as a
/// bool array parallel to its fields. Stamped from the FIRRTL bundle type,
/// which lowering erases. Absent when no field is flipped.
inline constexpr llvm::StringLiteral kDbgFlipsAttr = "dbg.flips";

/// On a `dbg.variable` that declares a port of its module: `"in"` or `"out"`.
/// For a bundle it is the direction of the unflipped fields, as in FIRRTL.
/// Stamped while the variable's value is still the port's block argument;
/// lowering and inlining later turn ports into plain signals.
inline constexpr llvm::StringLiteral kDbgPortAttr = "dbg.port";

/// FIRRTL ground kind of a leaf operand that lowering turns into a plain
/// integer: `"sint"` or `"clock"`. On the debug op that takes the leaf: a
/// string covers every operand, an array has one string per operand (empty
/// for the rest). Absent when no operand is signed or a clock.
inline constexpr llvm::StringLiteral kDbgGroundAttr = "dbg.ground";

/// Name of the module a root debug op (`dbg.variable`, or a `dbg.scope`
/// without a parent scope) came from, when dedup moved it out of that module
/// into the module that replaced it. Absent means the enclosing module. On an
/// instance: the module it instantiated before dedup replaced that module.
inline constexpr llvm::StringLiteral kDbgOriginAttr = "dbg.origin";

/// On a module that dedup kept: maps the name of each module merged into it
/// to `{moduleinfo, loc}` of that module.
inline constexpr llvm::StringLiteral kDbgOriginsAttr = "dbg.origins";

/// The source variable a memory declares, as `{name, typeName?, params?}`
/// from its `circt_debug_var`. A memory has no SSA value for `dbg.variable`
/// to take, so the record rides on the memory op and follows it down to the
/// instance of the generated memory module.
inline constexpr llvm::StringLiteral kDbgMemoryAttr = "dbg.memory";

} // namespace circt::debug

#endif // CIRCT_DIALECT_DEBUG_DEBUGOPS_H
