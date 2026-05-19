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

#include <tuple>

// Operation definitions generated from `Debug.td`
#define GET_OP_CLASSES
#include "circt/Dialect/Debug/Debug.h.inc"

namespace circt {
namespace debug {

/// Content-identity key for a `dbg.enumdef`: (enumTypeName, fqn, variantsMap)
using EnumDefContentKey =
    std::tuple<mlir::StringAttr, mlir::StringAttr, mlir::DictionaryAttr>;

inline EnumDefContentKey getEnumDefContentKey(EnumDefOp op) {
  return {op.getEnumTypeNameAttr(), op.getFqnAttr(), op.getVariantsMapAttr()};
}

/// UHDI attr names stamped on dbg.* ops by uhdi-init / verilog-snapshot
/// and consumed by EmitUHDI.
inline constexpr llvm::StringLiteral kUhdiStableIdAttr = "uhdi.stable_id";
inline constexpr llvm::StringLiteral kUhdiReprEntryAttr = "uhdi.repr_entry";
inline constexpr llvm::StringLiteral kUhdiVerilogRepr = "verilog";
/// Sentinel placed in `guardRef` when capture-when cannot reduce a compound
/// when-guard to a single name. Resolvers treat it as an explicit "complex
/// guard" marker rather than an unknown reference.
inline constexpr llvm::StringLiteral kUhdiComplexGuardSentinel = "<complex>";
/// Sentinel placed in `valueRef` when capture-when sees a constant- or
/// temp-wire-driven connect with no source-level dbg.variable naming it.
/// Resolvers treat it as an explicit "constant source" marker.
inline constexpr llvm::StringLiteral kUhdiConstSentinel = "<const>";

/// Walk every `dbg.rootblock` and diagnose statement-tree references
/// (varRef / valueRef / guardRef) that don't resolve to a `dbg.variable`
/// in the enclosing module. Returns the diagnostic count.
///
/// Not a verifier hook: literal-string fallback is *intentional* for
/// mem-port subfields, XMR refs, and names capture-when synthesises
/// before the corresponding `dbg.variable` exists.
unsigned verifyUhdiStatementRefs(mlir::Operation *root);

} // namespace debug
} // namespace circt

#endif // CIRCT_DIALECT_DEBUG_DEBUGOPS_H
