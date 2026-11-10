//===- DebugScopeType.td - Debug scope type constraint -----*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// A constraint for `!dbg.scope` operands of ops in other dialects. Including
// DebugTypes.td there would clash with their own type defs.
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_DEBUG_DEBUGSCOPETYPE_TD
#define CIRCT_DIALECT_DEBUG_DEBUGSCOPETYPE_TD

include "mlir/IR/CommonTypeConstraints.td"

def DebugScopeType : Type<CPred<"::llvm::isa<::circt::debug::ScopeType>($_self)">,
                          "debug scope", "::circt::debug::ScopeType">;

#endif // CIRCT_DIALECT_DEBUG_DEBUGSCOPETYPE_TD
