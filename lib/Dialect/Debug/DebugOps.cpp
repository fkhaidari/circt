//===- DebugOps.cpp - Debug dialect operations ----------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "mlir/IR/OpImplementation.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"

using namespace circt;
using namespace debug;
using namespace mlir;

//===----------------------------------------------------------------------===//
// StructOp
//===----------------------------------------------------------------------===//

ParseResult StructOp::parse(OpAsmParser &parser, OperationState &result) {
  // Parse the struct fields.
  SmallVector<Attribute> names;
  SmallVector<OpAsmParser::UnresolvedOperand, 16> operands;
  std::string nameBuffer;
  auto parseField = [&]() {
    nameBuffer.clear();
    if (parser.parseString(&nameBuffer) || parser.parseColon() ||
        parser.parseOperand(operands.emplace_back()))
      return failure();
    names.push_back(StringAttr::get(parser.getContext(), nameBuffer));
    return success();
  };
  if (parser.parseCommaSeparatedList(AsmParser::Delimiter::Braces, parseField))
    return failure();

  // Parse the attribute dictionary.
  if (parser.parseOptionalAttrDict(result.attributes))
    return failure();

  // Parse the field types, if there are any fields.
  SmallVector<Type> types;
  if (!operands.empty()) {
    if (parser.parseColon())
      return failure();
    auto typesLoc = parser.getCurrentLocation();
    if (parser.parseTypeList(types))
      return failure();
    if (types.size() != operands.size())
      return parser.emitError(typesLoc,
                              "number of fields and types must match");
  }

  // Resolve the operands.
  for (auto [operand, type] : llvm::zip(operands, types))
    if (parser.resolveOperand(operand, type, result.operands))
      return failure();

  // Finalize the op.
  result.addAttribute("names", ArrayAttr::get(parser.getContext(), names));
  result.addTypes(StructType::get(parser.getContext()));
  return success();
}

void StructOp::print(OpAsmPrinter &printer) {
  printer << " {";
  llvm::interleaveComma(llvm::zip(getFields(), getNames()), printer.getStream(),
                        [&](auto pair) {
                          auto [field, name] = pair;
                          printer.printAttribute(name);
                          printer << ": ";
                          printer.printOperand(field);
                        });
  printer << '}';
  printer.printOptionalAttrDict(getOperation()->getAttrs(), {"names"});
  if (!getFields().empty()) {
    printer << " : ";
    printer << getFields().getTypes();
  }
}

//===----------------------------------------------------------------------===//
// ArrayOp
//===----------------------------------------------------------------------===//

ParseResult ArrayOp::parse(OpAsmParser &parser, OperationState &result) {
  // Parse the elements, attributes and types.
  SmallVector<OpAsmParser::UnresolvedOperand, 16> operands;
  if (parser.parseOperandList(operands, AsmParser::Delimiter::Square) ||
      parser.parseOptionalAttrDict(result.attributes))
    return failure();

  // Resolve the operands.
  if (!operands.empty()) {
    Type type;
    if (parser.parseColon() || parser.parseType(type))
      return failure();
    for (auto operand : operands)
      if (parser.resolveOperand(operand, type, result.operands))
        return failure();
  }

  // Finalize the op.
  result.addTypes(ArrayType::get(parser.getContext()));
  return success();
}

void ArrayOp::print(OpAsmPrinter &printer) {
  printer << " [";
  printer << getElements();
  printer << ']';
  printer.printOptionalAttrDict(getOperation()->getAttrs());
  if (!getElements().empty()) {
    printer << " : ";
    printer << getElements()[0].getType();
  }
}

//===----------------------------------------------------------------------===//
// Generated operation code
//===----------------------------------------------------------------------===//
#define GET_OP_CLASSES
#include "circt/Dialect/Debug/Debug.cpp.inc"

void DebugDialect::registerOps() {
  addOperations<
#define GET_OP_LIST
#include "circt/Dialect/Debug/Debug.cpp.inc"
      >();
}

//===----------------------------------------------------------------------===//
// ValueOp
//===----------------------------------------------------------------------===//

LogicalResult ValueOp::verify() {
  // Final IR is expected to have >=1 user (dbg.variable/dbg.struct/dbg.array).
  if (!llvm::all_of(getResult().getUsers(), [](Operation *user) {
        return isa<VariableOp, StructOp, ArrayOp>(user);
      }))
    return emitOpError(
        "must only be used as an operand of dbg.variable, dbg.struct, or "
        "dbg.array");

  return success();
}

//===----------------------------------------------------------------------===//
// EnumOp
//===----------------------------------------------------------------------===//

LogicalResult EnumOp::verify() {
  if (getVariantsMap().empty())
    return emitOpError("variantsMap must not be empty");

  llvm::SmallDenseSet<int64_t> seenValues{};
  for (auto namedAttr : getVariantsMap()) {
    auto intAttr = dyn_cast<IntegerAttr>(namedAttr.getValue());
    if (!intAttr)
      return emitOpError("variantsMap entry '")
             << namedAttr.getName().getValue()
             << "' must be an IntegerAttr, got " << namedAttr.getValue();
    if (!intAttr.getType().isSignlessInteger())
      return emitOpError() << "variant '" << namedAttr.getName().getValue()
                           << "' must have a signless integer value";
    auto value = intAttr.getInt();
    if (!seenValues.insert(value).second)
      return emitOpError("duplicate enum value ") << value;
  }
  return success();
}

//===----------------------------------------------------------------------===//
// RootBlockOp
//===----------------------------------------------------------------------===//

static LogicalResult verifyBlock(Region &body, Operation *op) {
  for (auto &block : body) {
    auto &ops = block.getOperations();
    auto odd = llvm::find_if_not(ops, [](auto &op) {
      return isa<SubBlockOp, ConnectStmtOp, DeclStmtOp>(&op);
    });

    if (odd != ops.end()) {
      return op->emitOpError() << "body may only contain dbg.subblock, "
                                  "dbg.connect_stmt, or dbg.decl_stmt; got '"
                               << odd->getName() << "'";
    }
  }
  return success();
}

LogicalResult RootBlockOp::verify() {
  return verifyBlock(getBody(), getOperation());
}

//===----------------------------------------------------------------------===//
// SubBlockOp
//===----------------------------------------------------------------------===//

LogicalResult SubBlockOp::verify() {
  // A subblock always states what it is conditional on. Allowing neither
  // would leave a consumer unable to tell a guarded group from an
  // unconditional one; allowing both would leave it two answers.
  if (getCondition() && getConditionRef())
    return emitOpError("condition given both as an operand and as an "
                       "attribute; expected exactly one");
  if (!getCondition() && !getConditionRef())
    return emitOpError("missing condition; expected a `dbg.expression` "
                       "operand, a `#dbg.varref`, or `#dbg.opaque_cond`");
  return verifyBlock(getBody(), getOperation());
}

//===----------------------------------------------------------------------===//
// UHDI statement-tree reference check
//===----------------------------------------------------------------------===//

/// Follow one step of a `#dbg.varref` path through the aggregate a variable
/// wraps. Returns the value the step selects, or null if the step does not
/// apply to what is actually there.
static Value stepIntoAggregate(Value aggregate, Attribute step) {
  // A `dbg.value` wrapper carries source-language metadata and is
  // transparent to path traversal.
  while (auto wrapper = aggregate.getDefiningOp<ValueOp>())
    aggregate = wrapper.getValue();

  if (auto field = dyn_cast<StringAttr>(step)) {
    auto structOp = aggregate.getDefiningOp<StructOp>();
    if (!structOp)
      return {};
    for (auto [name, value] :
         llvm::zip(structOp.getNames(), structOp.getFields()))
      if (cast<StringAttr>(name) == field)
        return value;
    return {};
  }

  auto index = dyn_cast<IntegerAttr>(step);
  if (!index)
    return {};
  auto arrayOp = aggregate.getDefiningOp<ArrayOp>();
  if (!arrayOp)
    return {};
  uint64_t position = index.getValue().getZExtValue();
  if (position >= arrayOp.getElements().size())
    return {};
  return arrayOp.getElements()[position];
}

unsigned debug::verifyUhdiStatementRefs(Operation *root) {
  unsigned diagnostics = 0;

  // Index every `dbg.variable` by the scope it belongs to. The key includes
  // the scope handle because two variables may share a name under distinct
  // `dbg.scope`s -- that is what keeps inlined copies of one module apart.
  llvm::DenseMap<std::pair<Value, StringRef>, VariableOp> variables;
  root->walk([&](VariableOp var) {
    variables.try_emplace({var.getScope(), var.getName()}, var);
  });

  root->walk([&](RootBlockOp rootBlock) {
    // Statements carry no scope of their own; they inherit the one on the
    // rootblock that encloses them. Looking a name up without it is what
    // used to make this check report inlined copies as ambiguous.
    Value scope = rootBlock.getScope();

    auto checkRef = [&](Operation *stmt, StringRef role, VarRefAttr ref) {
      auto it = variables.find({scope, ref.getRoot().getValue()});
      if (it == variables.end()) {
        stmt->emitWarning()
            << "uhdi: statement " << role << " names '"
            << ref.getRoot().getValue()
            << "', which is not a dbg.variable in this scope";
        ++diagnostics;
        return;
      }

      Value current = it->second.getValue();
      for (auto [index, step] : llvm::enumerate(ref.getPath())) {
        current = stepIntoAggregate(current, step);
        if (!current) {
          stmt->emitWarning()
              << "uhdi: statement " << role << " path step " << index
              << " does not select anything in '" << ref.getRoot().getValue()
              << "'";
          ++diagnostics;
          return;
        }
      }
    };

    rootBlock.walk([&](Operation *op) {
      if (auto connect = dyn_cast<ConnectStmtOp>(op)) {
        checkRef(op, "dest", connect.getDest());
        // A constant source or a cross-module symbol names nothing here.
        if (auto src = dyn_cast<VarRefAttr>(connect.getSrc()))
          checkRef(op, "src", src);
      } else if (auto block = dyn_cast<SubBlockOp>(op)) {
        if (auto cond =
                dyn_cast_or_null<VarRefAttr>(block.getConditionRefAttr()))
          checkRef(op, "condition", cond);
      } else if (auto decl = dyn_cast<DeclStmtOp>(op)) {
        checkRef(op, "target", decl.getTarget());
      }
    });
  });

  return diagnostics;
}
