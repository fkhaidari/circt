//===- DebugAttributes.cpp - Debug dialect attributes ---------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugAttributes.h"
#include "circt/Dialect/Debug/DebugDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace circt;
using namespace debug;
using namespace mlir;

//===----------------------------------------------------------------------===//
// Table Gen
//===----------------------------------------------------------------------===//

#define GET_ATTRDEF_CLASSES
#include "circt/Dialect/Debug/DebugAttributes.cpp.inc"

LogicalResult VarRefAttr::verify(function_ref<InFlightDiagnostic()> emitError,
                                 StringAttr root, ArrayRef<Attribute> path) {
  if (!root || root.getValue().empty())
    return emitError() << "root name must not be empty";
  for (auto [index, step] : llvm::enumerate(path)) {
    if (auto field = dyn_cast<StringAttr>(step)) {
      if (field.getValue().empty())
        return emitError() << "path step " << index
                           << " is an empty field name";
      continue;
    }
    // An array index. Negative indices would not name an element.
    if (auto element = dyn_cast<IntegerAttr>(step)) {
      if (element.getValue().isNegative())
        return emitError() << "path step " << index << " has a negative index";
      continue;
    }
    return emitError() << "path step " << index
                       << " must be a field name or an element index";
  }
  return success();
}

void DebugDialect::registerAttributes() {
  addAttributes<
#define GET_ATTRDEF_LIST
#include "circt/Dialect/Debug/DebugAttributes.cpp.inc"
      >();
}
