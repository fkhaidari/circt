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
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/InferTypeOpInterface.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

#include "circt/Dialect/Debug/DebugDialect.h"
#include "circt/Dialect/Debug/DebugTypes.h"
#include "circt/Dialect/HW/HWAttributes.h"
#include "circt/Dialect/HW/HWOpInterfaces.h"

// Enum definitions generated from `DebugOps.td`
#include "circt/Dialect/Debug/DebugEnums.h.inc"

// Operation definitions generated from `Debug.td`
#define GET_OP_CLASSES
#include "circt/Dialect/Debug/Debug.h.inc"

namespace circt::debug {
ModuleInfoOp getModuleDescription(mlir::Operation *module);
ModuleInfoOp getOrCreateModuleDescription(mlir::Operation *module,
                                          mlir::StringAttr typeName,
                                          mlir::StringAttr ext = {});
/// Attach an implicit scope to debug variables and scopes without a parent.
/// Returns true for Debug operations, whose source names must not be prefixed.
bool updateImplicitScope(mlir::Operation *op, mlir::Value scope);
void finalizeInstanceDescriptions(mlir::Operation *root);
} // namespace circt::debug

#endif // CIRCT_DIALECT_DEBUG_DEBUGOPS_H
