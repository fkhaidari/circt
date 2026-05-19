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

def ValueType : DebugTypeDef<"Value"> {
  let mnemonic = "value";
  let summary = "debug value annotated with source-language metadata";
  let description = "The result of a `dbg.value` operation.";
}

def EnumType : DebugTypeDef<"Enum"> {
  let mnemonic = "enum";
  let summary = "debug enum value";
  let description = "The result of a `dbg.enum` operation.";
}

def RefType : DebugTypeDef<"Ref"> {
  let mnemonic = "ref";
  let summary = "debug reference handle";
  let description = [{
    An SSA handle naming a debug entity, so that one debug operation can
    refer to another without going through a name. Produced by
    `dbg.expression`; consumed by `dbg.subblock` as its condition and by
    `dbg.expression` itself for nested compound guards.

    Values of this type never reach hardware. An operand of this type is
    therefore free: it does not enter the use counts that drive
    ExportVerilog's inlining decisions, unlike an operand on a real
    hardware value.
  }];
}

#endif // CIRCT_DIALECT_DEBUG_DEBUGTYPES_TD
