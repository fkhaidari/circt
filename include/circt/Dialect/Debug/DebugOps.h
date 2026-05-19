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

#include "circt/Dialect/Debug/DebugAttributes.h"
#include "circt/Dialect/Debug/DebugDialect.h"
#include "circt/Dialect/Debug/DebugTypes.h"

// Operation definitions generated from `Debug.td`
#define GET_OP_CLASSES
#include "circt/Dialect/Debug/Debug.h.inc"

namespace circt::debug {

/// UHDI attr names stamped on dbg.* ops by uhdi-init / verilog-snapshot
/// and consumed by EmitUHDI.
inline constexpr llvm::StringLiteral kUhdiStableIdAttr = "uhdi.stable_id";
inline constexpr llvm::StringLiteral kUhdiReprEntryAttr = "uhdi.repr_entry";
inline constexpr llvm::StringLiteral kUhdiVerilogRepr = "verilog";

/// Walk every `dbg.rootblock` and diagnose `#dbg.varref` references whose
/// root names no `dbg.variable` in the enclosing scope, or whose path does
/// not lead through the aggregate that variable wraps. Returns the
/// diagnostic count.
///
/// Not a verifier hook: a reference may legitimately outrun its variable
/// while a pass is mid-flight, and cross-module references are resolved
/// against a symbol rather than against anything visible here.
unsigned verifyUhdiStatementRefs(mlir::Operation *root);

} // namespace circt::debug

#endif // CIRCT_DIALECT_DEBUG_DEBUGOPS_H
