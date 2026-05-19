//===- DebugOps.cpp - Debug dialect operations ----------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/PatternMatch.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
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
// SubFieldOp
//===----------------------------------------------------------------------===//

LogicalResult SubFieldOp::verify() {
  // Final IR is expected to have >=1 user (dbg.struct/dbg.array).
  if (getResult().use_empty())
    return success();

  if (!llvm::all_of(getResult().getUsers(), [](Operation *user) {
        return isa<StructOp, ArrayOp>(user);
      }))
    return emitOpError(
        "must only be used as an operand of dbg.struct or dbg.array");

  return success();
}

//===----------------------------------------------------------------------===//
// EnumDefOp
//===----------------------------------------------------------------------===//

LogicalResult EnumDefOp::verify() {
  if (getVariantsMap().empty())
    return emitOpError("variantsMap must not be empty");

  llvm::DenseSet<int64_t> seenValues{};
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
  return verifyBlock(getBody(), getOperation());
}

//===----------------------------------------------------------------------===//
// ModuleInfoOp
//===----------------------------------------------------------------------===//

LogicalResult ModuleInfoOp::verify() {
  auto *region = getOperation()->getParentRegion();
  if (!region)
    return success();

  for (auto &block : *region) {
    for (auto mi : block.getOps<ModuleInfoOp>()) {
      if (mi == *this)
        return success();
      return emitOpError("only one dbg.moduleinfo may appear in a region");
    }
  }
  return success();
}

//===----------------------------------------------------------------------===//
// EnumDefOp canonicalization
//===----------------------------------------------------------------------===//

namespace {
struct EnumDefDeduplication : public OpRewritePattern<EnumDefOp> {
  using OpRewritePattern<EnumDefOp>::OpRewritePattern;

  LogicalResult matchAndRewrite(EnumDefOp op,
                                PatternRewriter &rewriter) const override {
    // Block-local: intrusive list order is dominance order within a Block, so
    // no DominanceInfo is needed. No in-tree producer emits dbg.enumdef across
    // multiple blocks; any residual cross-block duplicates are collapsed by the
    // content-key dedup in DebugInfoBuilder (lib/Analysis/DebugInfo.cpp).
    // TODO(perf): O(N^2) per-op scan
    auto opKey = getEnumDefContentKey(op);
    auto opScope = op.getScope();

    for (auto *prev = op->getPrevNode(); prev; prev = prev->getPrevNode()) {
      auto otherEnumDef = dyn_cast<EnumDefOp>(prev);
      if (!otherEnumDef)
        continue;

      if (getEnumDefContentKey(otherEnumDef) == opKey &&
          otherEnumDef.getScope() == opScope) {
        rewriter.replaceOp(op, otherEnumDef.getResult());
        return success();
      }
    }
    return failure();
  }
};
} // namespace

void EnumDefOp::getCanonicalizationPatterns(RewritePatternSet &results,
                                            MLIRContext *context) {
  results.add<EnumDefDeduplication>(context);
}

//===----------------------------------------------------------------------===//
// UHDI statement-tree reference check
//===----------------------------------------------------------------------===//

unsigned debug::verifyUhdiStatementRefs(Operation *root) {
  unsigned diagnostics = 0;

  // Build the set of dbg.variable / dbg.expression names visible to each
  // enclosing scope in a single walk over `root`. After ModuleInliner there
  // may be multiple dbg.rootblock under one parent — caching by parent op
  // keeps the verifier O(N) over IR size instead of O(rootblocks · N).
  //
  // Key is (parentOp, scopeValue): two ops sharing a name but under distinct
  // dbg.scope handles are separate identities and must not collapse.
  // Lookup is scope-blind (scans all buckets for the parent) because the
  // reference ops — SubBlockOp, ConnectStmtOp, DeclStmtOp — carry no scope
  // operand and have no structural way to name a specific scope bucket.
  llvm::DenseMap<std::pair<Operation *, Value>, llvm::StringSet<>> knownByScope;
  root->walk([&](Operation *op) {
    if (auto var = dyn_cast<VariableOp>(op)) {
      if (Operation *parent = op->getParentOp())
        knownByScope[{parent, var.getScope()}].insert(var.getName());
    } else if (auto expr = dyn_cast<ExpressionOp>(op)) {
      // `dbg.expression` is a sibling value-tracker for compound when-guards;
      // count its name so guardRef into a materialised expression doesn't
      // false-positive.
      if (Operation *parent = op->getParentOp())
        knownByScope[{parent, expr.getScope()}].insert(expr.getName());
    }
  });

  root->walk([&](RootBlockOp rootBlock) {
    Operation *enclosingScope = rootBlock->getParentOp();
    if (!enclosingScope)
      return;
    // Count how many distinct scope-buckets under enclosingScope contain each
    // name. A count > 1 means the name is ambiguous: two expressions/variables
    // share it under different dbg.scope handles, and the scope-blind lookup
    // cannot distinguish them.
    llvm::StringMap<unsigned> knownNameCounts;
    for (auto &[key, names] : knownByScope)
      if (key.first == enclosingScope)
        for (auto &entry : names)
          ++knownNameCounts[entry.getKey()];

    auto checkRef = [&](Operation *stmt, StringRef refKind, StringRef name) {
      // The complex-guard sentinel is expected, not a defect.
      if (name.empty() || name == kUhdiComplexGuardSentinel ||
          name == kUhdiConstSentinel)
        return;
      auto it = knownNameCounts.find(name);
      if (it == knownNameCounts.end()) {
        stmt->emitWarning()
            << "uhdi: statement " << refKind << " '" << name
            << "' has no matching dbg.variable in the enclosing module; "
               "the emitter will fall back to the literal name";
        ++diagnostics;
        return;
      }
      if (it->second >= 2) {
        stmt->emitWarning()
            << "uhdi: statement " << refKind << " '" << name
            << "' is ambiguous: matches expressions/variables under "
            << it->second
            << " distinct dbg.scope handles; statement-tree refs are "
               "scope-blind, picking arbitrary identity";
        ++diagnostics;
      }
    };

    rootBlock.walk([&](Operation *op) {
      if (auto c = dyn_cast<ConnectStmtOp>(op)) {
        checkRef(op, "varRef", c.getVarRef());
        checkRef(op, "valueRef", c.getValueRef());
      } else if (auto b = dyn_cast<SubBlockOp>(op)) {
        checkRef(op, "guardRef", b.getGuardRef());
      } else if (auto d = dyn_cast<DeclStmtOp>(op)) {
        checkRef(op, "varRef", d.getVarRef());
      }
    });
  });

  return diagnostics;
}
