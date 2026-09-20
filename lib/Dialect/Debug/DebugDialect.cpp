//===- DebugDialect.cpp - Debug dialect implementation --------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugDialect.h"
#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Support/LLVM.h"

using namespace circt;
using namespace debug;

void DebugDialect::initialize() {
  registerOps();
  registerTypes();
}

/// Check the shape of the discardable attributes this dialect defines.
/// `dbg.moduleinfo` is a raw dictionary written by the frontend lowering and
/// read by the debug-info emitters, which resolve its fields by name; checking
/// it here keeps a malformed record from reaching them as a silent null.
LogicalResult DebugDialect::verifyOperationAttribute(Operation *op,
                                                     NamedAttribute attr) {
  if (attr.getName() != kDbgModuleInfoAttr)
    return success();

  auto dict = dyn_cast<DictionaryAttr>(attr.getValue());
  if (!dict)
    return op->emitOpError()
           << "'" << kDbgModuleInfoAttr << "' must be a dictionary";

  if (auto typeName = dict.get("typeName");
      typeName && !isa<StringAttr>(typeName))
    return op->emitOpError()
           << "'" << kDbgModuleInfoAttr << "' type name must be a string";

  auto params = dict.get("params");
  if (!params)
    return success();
  auto array = dyn_cast<ArrayAttr>(params);
  if (!array)
    return op->emitOpError()
           << "'" << kDbgModuleInfoAttr << "' params must be an array";
  for (auto param : array) {
    auto paramDict = dyn_cast<DictionaryAttr>(param);
    if (!paramDict || !isa_and_nonnull<StringAttr>(paramDict.get("name")))
      return op->emitOpError()
             << "'" << kDbgModuleInfoAttr
             << "' params must be dictionaries with a string name";
  }
  return success();
}

// Dialect implementation generated from `DebugDialect.td`
#include "circt/Dialect/Debug/DebugDialect.cpp.inc"
