//===- DebugTypes.td - Debug dialect types -----------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_DEBUG_DEBUGTYPES_TD
#define CIRCT_DIALECT_DEBUG_DEBUGTYPES_TD

include "circt/Dialect/Debug/DebugDialect.td"
include "mlir/IR/AttrTypeBase.td"

class DebugTypeDef<string name> : TypeDef<DebugDialect, name> { }

def ScopeType : DebugTypeDef<"Scope"> {
  let mnemonic = "scope";
  let summary = "debug scope";
  let description = "The result of a `dbg.scope` operation.";
}

def StructType : DebugTypeDef<"Struct"> {
  let mnemonic = "struct";
  let summary = "debug struct aggregate";
  let description = "The result of a `dbg.struct` operation.";
}

def ArrayType : DebugTypeDef<"Array"> {
  let mnemonic = "array";
  let summary = "debug array aggregate";
  let description = "The result of a `dbg.array` operation.";
}

def SubFieldType : DebugTypeDef<"SubField"> {
  let mnemonic = "subfield";
  let summary = "debug variable subfield of an aggregate";
  let description = "The result of a `dbg.subfield` operation.";
}

def EnumDefType : DebugTypeDef<"EnumDef"> {
  let mnemonic = "enumdef";
  let summary = "debug enum definition";
  let description = "The result of a `dbg.enumdef` operation.";
}

def ExpressionType : DebugTypeDef<"Expression"> {
  let mnemonic = "expression";
  let summary = "debug expression handle";
  let description = [{
    The result of a `dbg.expression` operation. Used as an SSA handle so
    one expression can be an operand of another (recursive compound
    guards), without polluting the surrounding HW dialect with debug-only
    Value types.
  }];
}

#endif // CIRCT_DIALECT_DEBUG_DEBUGTYPES_TD
