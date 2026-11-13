//===- DebugOps.cpp - Debug dialect operations ----------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "mlir/IR/OpImplementation.h"
#include "llvm/ADT/DenseSet.h"

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
#include "circt/Dialect/Debug/DebugEnums.cpp.inc"

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
  if (getDefAttr() && getTypeAttr())
    return emitOpError("def and type are mutually exclusive");
  if (auto ref = getDefAttr())
    if (!SymbolTable::lookupNearestSymbolFrom<ModuleInfoOp>(*this, ref))
      return emitOpError("def must reference a dbg.module");
  if (static_cast<bool>(getValue()) == static_cast<bool>(getPathAttr()))
    return emitOpError("requires exactly one of value or path");
  // Final IR is expected to have >=1 user (dbg.variable/dbg.struct/dbg.array).
  if (!llvm::all_of(getResult().getUsers(), [](Operation *user) {
        return isa<VariableOp, StructOp, ArrayOp>(user);
      }))
    return emitOpError(
        "must only be used as an operand of dbg.variable, dbg.struct, or "
        "dbg.array");

  return success();
}

LogicalResult ValueOp::verifyInnerRefs(hw::InnerRefNamespace &ns) {
  auto ref = getPathAttr();
  if (!ref)
    return success();
  auto path = ns.symTable.lookup<hw::HierPathOp>(ref.getValue());
  if (!path)
    return emitOpError("path must reference hw.hierpath");
  if (failed(path.verifyInnerRefs(ns)))
    return failure();
  auto names = path.getNamepath();
  auto last = names[names.size() - 1];
  if (isa<FlatSymbolRefAttr>(last)) {
    if (names.size() < 2)
      return emitOpError("path must target an operation with an inner symbol");
    last = names[names.size() - 2];
  }
  auto inner = dyn_cast<hw::InnerRefAttr>(last);
  auto *target = inner ? ns.lookupOp(inner) : nullptr;
  if (!isa_and_nonnull<hw::InnerSymbolOpInterface>(target))
    return emitOpError("path must target an operation with an inner symbol");
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

LogicalResult ScopeOp::verify() {
  if (auto ref = getDefAttr())
    if (!SymbolTable::lookupNearestSymbolFrom<ModuleInfoOp>(*this, ref))
      return emitOpError("def must reference a dbg.module");
  if (auto parent = getScope())
    if (!parent.getDefiningOp<ScopeOp>())
      return emitOpError("scope must be defined by dbg.scope");
  return success();
}

bool ModuleInfoOp::canDiscardOnUseEmpty() { return !getImplAttr(); }

LogicalResult ModuleInfoOp::verify() {
  if (!(*this)->getParentOp()->hasTrait<OpTrait::SymbolTable>())
    return emitOpError("must be directly inside a symbol table");
  if (auto ref = getImplAttr()) {
    auto *target = SymbolTable::lookupNearestSymbolFrom(*this, ref);
    if (!isa_and_nonnull<igraph::ModuleOpInterface>(target))
      return emitOpError("impl must reference a module operation");
  }
  return success();
}

ModuleInfoOp circt::debug::getModuleDescription(Operation *module) {
  auto name = SymbolTable::getSymbolName(module);
  for (auto info :
       module->getParentOp()->getRegion(0).front().getOps<ModuleInfoOp>())
    if (auto ref = info.getImplAttr(); ref && ref.getAttr() == name)
      return info;
  return {};
}

ModuleInfoOp circt::debug::getOrCreateModuleDescription(Operation *module,
                                                        StringAttr typeName,
                                                        StringAttr ext) {
  if (auto info = getModuleDescription(module)) {
    if (typeName)
      info.setTypeAttr(typeName);
    if (ext)
      info.setExtAttr(ext);
    return info;
  }
  OpBuilder builder(module);
  auto name = SymbolTable::getSymbolName(module);
  auto info = ModuleInfoOp::create(
      builder, module->getLoc(),
      builder.getStringAttr((name.getValue() + "Debug").str()),
      typeName ? typeName : name, ext, FlatSymbolRefAttr::get(name),
      StringAttr());
  SymbolTable symbols(module->getParentOp());
  symbols.insert(info);
  return info;
}

std::optional<size_t> ScopeOp::getTargetResultIndex() { return std::nullopt; }

bool circt::debug::updateImplicitScope(Operation *op, Value scope) {
  auto update = [&](auto op) {
    if (scope && !op.getScope())
      op.getScopeMutable().assign(scope);
  };
  if (auto variable = dyn_cast<VariableOp>(op))
    update(variable);
  else if (auto nested = dyn_cast<ScopeOp>(op))
    update(nested);
  return isa_and_nonnull<DebugDialect>(op->getDialect());
}

void circt::debug::finalizeInstanceDescriptions(Operation *root) {
  SmallVector<VariableOp> descriptions;
  DenseMap<Attribute, unsigned> localAliases;
  root->walk([&](VariableOp variable) {
    auto value = variable.getValue().getDefiningOp<ValueOp>();
    if (!value || !value.getPathAttr())
      return;
    descriptions.push_back(variable);
    auto path = SymbolTable::lookupNearestSymbolFrom<hw::HierPathOp>(
        value, value.getPathAttr());
    if (path && path.getNamepath().size() == 1)
      ++localAliases[path.getNamepath()[0]];
  });
  for (auto variable : descriptions) {
    auto value = variable.getValue().getDefiningOp<ValueOp>();
    auto path = SymbolTable::lookupNearestSymbolFrom<hw::HierPathOp>(
        value, value.getPathAttr());
    if (!path)
      continue;
    auto names = path.getNamepath();
    if (names.empty())
      continue;
    Attribute last = names[names.size() - 1];
    if (isa<FlatSymbolRefAttr>(last) && names.size() > 1)
      last = names[names.size() - 2];
    auto ref = dyn_cast<hw::InnerRefAttr>(last);
    if (!ref)
      continue;
    auto *module = SymbolTable::lookupNearestSymbolFrom(
        path, FlatSymbolRefAttr::get(ref.getModule()));
    if (!module)
      continue;
    ScopeOp target;
    module->walk([&](ScopeOp scope) {
      if (auto sym = scope.getInnerSymAttr();
          sym && sym.getSymName() == ref.getName())
        target = scope;
    });
    if (!target)
      continue;

    // Nonlocal paths retain the instance route to the inlined body.
    if (names.size() != 1 || target->getBlock() != variable->getBlock())
      continue;
    if (localAliases.lookup(last) != 1)
      continue;
    ScopeOp scope = target;
    if (auto parent = variable.getScope()) {
      SmallVector<ScopeOp> parents;
      for (auto current = parent.getDefiningOp<ScopeOp>(); current;
           current = current.getScope().getDefiningOp<ScopeOp>()) {
        parents.push_back(current);
        if (current == target)
          break;
        if (!current.getScope())
          break;
      }
      if (llvm::is_contained(parents, target))
        continue;
      for (auto parentScope : llvm::reverse(parents))
        if (parentScope->getBlock() == target->getBlock() &&
            target->isBeforeInBlock(parentScope))
          parentScope->moveBefore(target);
    }
    if (auto parent = variable.getScope())
      scope.getScopeMutable().assign(parent);
    else
      scope.getScopeMutable().clear();
    scope.setNameAttr(variable.getNameAttr());
    if (auto definition = value.getDefAttr())
      scope.setDefAttr(definition);
    if (auto ref = value.getDefAttr()) {
      auto info =
          SymbolTable::lookupNearestSymbolFrom<ModuleInfoOp>(value, ref);
      if (info &&
          ((value.getTypeAttr() && value.getTypeAttr() != info.getTypeAttr()) ||
           (value.getExtAttr() && value.getExtAttr() != info.getExtAttr())))
        continue;
    } else if (value.getTypeAttr() || value.getExtAttr())
      continue;
    variable.erase();
    if (value->use_empty())
      value.erase();
    if (path.isPrivate() && SymbolTable::symbolKnownUseEmpty(path, root))
      path.erase();
  }
}
