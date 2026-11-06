//===- LowerIntrinsics.cpp - Lower Intrinsics -------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file defines the LowerIntrinsics pass.  This pass processes FIRRTL
// generic intrinsic operations and rewrites to their implementation.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLIntrinsics.h"
#include "circt/Dialect/FIRRTL/FIRRTLUtils.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/TypeSwitch.h"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_LOWERINTRINSICS
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace circt;
using namespace firrtl;

//===----------------------------------------------------------------------===//
// Debug Intrinsics
//===----------------------------------------------------------------------===//

static constexpr StringLiteral oldProtocolHint =
    "; the FIRRTL may use an older Chisel debug protocol, update Chisel or "
    "compile without debug info";

static bool isDebugIntrinsic(Operation *op) {
  auto intrinsic = dyn_cast<GenericIntrinsicOp>(op);
  return intrinsic && intrinsic.getIntrinsic().starts_with("circt_debug_");
}

static ArrayAttr getParamsAttr(GenericIntrinsic &gi) {
  auto params = gi.getParamValue<StringAttr>("params");
  return params ? ArrayAttr::get(params.getContext(), {params}) : ArrayAttr();
}

/// Collect the FIRRTL leaves under a Debug value, with the flip parity of the
/// debug path from `value` down to each leaf.
static void collectLeaves(Value value, bool flip,
                          SmallVectorImpl<std::pair<Value, bool>> &leaves) {
  SmallVector<std::pair<Value, bool>> worklist = {{value, flip}};
  // Children are pushed in reverse to visit them in order.
  while (!worklist.empty()) {
    std::tie(value, flip) = worklist.pop_back_val();
    if (auto wrapper = value.getDefiningOp<debug::ValueOp>()) {
      worklist.push_back({wrapper.getValue(), flip});
    } else if (auto enumOp = value.getDefiningOp<debug::EnumOp>()) {
      worklist.push_back({enumOp.getValue(), flip});
    } else if (auto structOp = value.getDefiningOp<debug::StructOp>()) {
      auto flips = structOp.getFlips();
      for (size_t i = structOp.getFields().size(); i-- > 0;)
        worklist.push_back(
            {structOp.getFields()[i], flip ^ (flips && (*flips)[i])});
    } else if (auto arrayOp = value.getDefiningOp<debug::ArrayOp>()) {
      for (size_t i = arrayOp.getElements().size(); i-- > 0;)
        worklist.push_back({arrayOp.getElements()[i], flip});
    } else {
      leaves.push_back({value, flip});
    }
  }
}

/// Walk from a leaf up the indexing ops and casts that `getFieldRefFromValue`
/// looks through with `lookThroughCasts`. Return the root and the flip parity
/// of the FIRRTL type along the way.
static std::pair<Value, bool> getRootAndFlip(Value value) {
  bool flip = false;
  while (Operation *op = value.getDefiningOp()) {
    Value input = TypeSwitch<Operation *, Value>(op)
                      .Case<SubfieldOp, OpenSubfieldOp>([&](auto op) {
                        flip ^= op.isFieldFlipped();
                        return op.getInput();
                      })
                      .Case<SubindexOp, OpenSubindexOp, RefCastOp, ConstCastOp,
                            UninferredResetCastOp>(
                          [](auto op) { return op.getInput(); })
                      .Default(Value());
    if (!input)
      break;
    value = input;
  }
  return {value, flip};
}

/// What the FieldRef root of a leaf declares the variable as. A port with an
/// Analog leaf is an inout.
static debug::VariableKindAttr getVariableKind(Value root, bool hasAnalog) {
  std::optional<debug::VariableKind> kind;
  if (auto arg = dyn_cast<BlockArgument>(root)) {
    auto module = cast<FModuleLike>(arg.getOwner()->getParentOp());
    if (hasAnalog)
      kind = debug::VariableKind::InOut;
    else if (module.getPortDirection(arg.getArgNumber()) == Direction::In)
      kind = debug::VariableKind::Input;
    else
      kind = debug::VariableKind::Output;
  } else {
    kind = TypeSwitch<Operation *, std::optional<debug::VariableKind>>(
               root.getDefiningOp())
               .Case<WireOp>([](auto) { return debug::VariableKind::Wire; })
               .Case<RegOp, RegResetOp>(
                   [](auto) { return debug::VariableKind::Reg; })
               .Case<NodeOp>([](auto) { return debug::VariableKind::Node; })
               .Default([](auto) { return std::nullopt; });
  }
  if (!kind)
    return {};
  return debug::VariableKindAttr::get(root.getContext(), *kind);
}

namespace {
/// Converts the `circt_debug_*` intrinsics in one module body 1:1 into Debug
/// ops, or erases them. Each intrinsic but `circt_debug_var` and
/// `circt_debug_moduleinfo` returns a `UInt<0>` handle that its parent takes
/// as an operand, possibly through alias `firrtl.node`s. A handle is known by
/// its producer, never by its type.
class DebugIntrinsicConverter {
public:
  DebugIntrinsicConverter(FModuleLike module, bool emit)
      : module(module), emit(emit) {}

  /// Convert or erase all debug intrinsics and their alias nodes.
  LogicalResult run();

  bool changed = false;

private:
  /// A converted handle and the label its parent reads.
  struct Handle {
    GenericIntrinsicOp op;
    Value value;
    StringAttr name;
    bool flip = false;
    Operation *user = nullptr;
  };

  LogicalResult followAliases(Value handle,
                              SmallVectorImpl<Operation *> &nodes);
  LogicalResult convert(GenericIntrinsicOp op);
  LogicalResult checkParams(GenericIntrinsicOp op, ArrayRef<StringRef> allowed,
                            bool allowVariants = false);
  LogicalResult checkLeaf(GenericIntrinsicOp op, Value value);
  LogicalResult checkNoLabel(Handle &handle, StringRef where);
  FailureOr<Handle> useHandle(GenericIntrinsicOp op, Value value);
  LogicalResult checkVariable(GenericIntrinsicOp op, Value value,
                              debug::VariableKindAttr &kind);

  FModuleLike module;
  bool emit;
  bool hasModuleInfo = false;
  SmallVector<Handle> handles;
  /// Maps a handle and its alias nodes to an index into `handles`.
  DenseMap<Value, unsigned> handleIndex;
};
} // namespace

/// Register the alias `firrtl.node`s of a handle, following chains of them.
LogicalResult
DebugIntrinsicConverter::followAliases(Value handle,
                                       SmallVectorImpl<Operation *> &nodes) {
  unsigned index = handleIndex.lookup(handle);
  SmallVector<Value> worklist = {handle};
  while (!worklist.empty()) {
    Value value = worklist.pop_back_val();
    for (auto *user : value.getUsers()) {
      auto node = dyn_cast<NodeOp>(user);
      if (!node)
        continue;
      if (!node.getAnnotations().empty() || node.getInnerSym() ||
          node.getForceable())
        return node.emitOpError("aliases a debug handle and must not carry "
                                "annotations, a symbol or a probe");
      handleIndex[node.getResult()] = index;
      nodes.push_back(node);
      worklist.push_back(node.getResult());
    }
  }
  return success();
}

LogicalResult DebugIntrinsicConverter::run() {
  SmallVector<GenericIntrinsicOp> intrinsics;
  module->walk<mlir::WalkOrder::PreOrder>([&](GenericIntrinsicOp op) {
    if (isDebugIntrinsic(op))
      intrinsics.push_back(op);
  });

  bool isClass = isa<ClassOp>(module);
  bool warnedClass = false;
  SmallVector<Operation *> toErase;
  for (auto intrinsic : intrinsics) {
    if (emit && isClass && !warnedClass) {
      intrinsic.emitWarning("debug intrinsics in a class body are dropped");
      warnedClass = true;
    }
    if (emit && !isClass) {
      if (failed(convert(intrinsic)))
        return failure();
    } else if (intrinsic.getResult()) {
      handleIndex[intrinsic.getResult()] = handles.size();
      handles.emplace_back();
    }
    toErase.push_back(intrinsic);
    if (intrinsic.getResult() &&
        failed(followAliases(intrinsic.getResult(), toErase)))
      return failure();
  }

  // Users come after their producers, so check in reverse. A use that remains
  // is not a debug intrinsic or alias node.
  DenseSet<Operation *> erased(toErase.begin(), toErase.end());
  for (auto *op : llvm::reverse(toErase)) {
    for (auto *user : op->getUsers()) {
      if (erased.contains(user))
        continue;
      auto diag = op->emitOpError("has a debug handle used by a non-debug op");
      diag.attachNote(user->getLoc()) << "used here";
      return diag;
    }
  }
  if (emit && !isClass)
    for (auto &handle : handles)
      if (!handle.user)
        return handle.op.emitOpError("has a debug handle that nothing uses");

  for (auto *op : llvm::reverse(toErase)) {
    op->erase();
    changed = true;
  }

  // Without debug info, an extmodule keeps no source class name.
  if (auto ext = dyn_cast<FExtModuleOp>(*module);
      ext && !emit && ext.getSourceNameAttr()) {
    ext.removeSourceNameAttr();
    changed = true;
  }
  return success();
}

LogicalResult DebugIntrinsicConverter::checkParams(GenericIntrinsicOp op,
                                                   ArrayRef<StringRef> allowed,
                                                   bool allowVariants) {
  for (auto param : op.getParameters().getAsRange<ParamDeclAttr>()) {
    StringRef name = param.getName().getValue();
    bool isVariant = allowVariants && name.starts_with("variant_");
    if (!isVariant && !llvm::is_contained(allowed, name))
      return op.emitOpError("has unknown parameter '")
             << name << "'" << oldProtocolHint;
    bool isInt = isVariant || name == "flip";
    if (isInt ? !isa<IntegerAttr>(param.getValue())
              : !isa<StringAttr>(param.getValue()))
      return op.emitOpError("parameter '")
             << name << "' must be " << (isInt ? "an integer" : "a string");
  }
  return success();
}

LogicalResult DebugIntrinsicConverter::checkLeaf(GenericIntrinsicOp op,
                                                 Value value) {
  if (type_isa<FEnumType>(value.getType()))
    return op.emitOpError("FIRRTL enum operands are not supported");
  auto type = type_dyn_cast<FIRRTLBaseType>(value.getType());
  if (!type || !type.isGround())
    return op.emitOpError("operand must be a debug handle or a ground "
                          "hardware value, got ")
           << value.getType();
  return success();
}

LogicalResult DebugIntrinsicConverter::checkNoLabel(Handle &handle,
                                                    StringRef where) {
  if (handle.name || handle.flip)
    return handle.op.emitOpError("must not have 'name' or 'flip' on ") << where;
  return success();
}

FailureOr<DebugIntrinsicConverter::Handle>
DebugIntrinsicConverter::useHandle(GenericIntrinsicOp op, Value value) {
  auto it = handleIndex.find(value);
  if (it == handleIndex.end())
    return op.emitOpError("operand must be a debug handle");
  auto &handle = handles[it->second];
  if (handle.user) {
    auto diag = op.emitOpError("uses a debug handle that is already used");
    diag.attachNote(handle.user->getLoc()) << "first used here";
    return diag;
  }
  handle.user = op;
  return handle;
}

/// Check the flips of the leaves under `value` against their FIRRTL types and
/// derive the variable kind from their shared FieldRef root.
LogicalResult
DebugIntrinsicConverter::checkVariable(GenericIntrinsicOp op, Value value,
                                       debug::VariableKindAttr &kind) {
  SmallVector<std::pair<Value, bool>> leaves;
  collectLeaves(value, false, leaves);
  Value root;
  bool hasAnalog = false;
  for (auto [leaf, flip] : leaves) {
    auto [leafRoot, typeFlip] = getRootAndFlip(leaf);
    if (root && leafRoot != root) {
      auto diag = op.emitOpError("has leaves with different roots");
      diag.attachNote(root.getLoc()) << "first root here";
      diag.attachNote(leafRoot.getLoc()) << "other root here";
      return diag;
    }
    root = leafRoot;
    hasAnalog |= type_isa<AnalogType>(leaf.getType());
    if (typeFlip != flip) {
      auto diag = op.emitOpError("has a 'flip' that does not match the FIRRTL "
                                 "type of a leaf");
      diag.attachNote(leaf.getLoc()) << "leaf here";
      return diag;
    }
  }
  if (root)
    kind = getVariableKind(root, hasAnalog);
  return success();
}

LogicalResult DebugIntrinsicConverter::convert(GenericIntrinsicOp op) {
  GenericIntrinsic gi(op);
  OpBuilder builder(op);
  auto loc = op.getLoc();
  StringRef intrinsic = op.getIntrinsic();

  if (intrinsic == "circt_debug_moduleinfo") {
    if (failed(checkParams(op, {"typeName", "params"})) ||
        gi.namedParam("typeName") || gi.hasNInputs(0) || gi.hasNoOutput())
      return failure();
    if (op->getParentOp() != module)
      return op.emitOpError("must be directly in the module body");
    if (hasModuleInfo)
      return op.emitOpError("must appear at most once per module");
    hasModuleInfo = true;
    debug::ModuleInfoOp::create(builder, loc,
                                gi.getParamValue<StringAttr>("typeName"),
                                getParamsAttr(gi), Value());
    return success();
  }

  if (intrinsic == "circt_debug_var") {
    // Memories are not supported yet; their variable has no operand.
    if (op.getNumOperands() == 0) {
      op.emitWarning("debug info for memories is not supported yet, dropped");
      return success();
    }
    if (failed(checkParams(op, {"name"})) || gi.namedParam("name") ||
        gi.hasNInputs(1) || gi.hasNoOutput())
      return failure();
    Value value = op.getOperand(0);
    if (handleIndex.contains(value)) {
      auto child = useHandle(op, value);
      if (failed(child) || failed(checkNoLabel(*child, "a variable root")))
        return failure();
      value = child->value;
    } else if (failed(checkLeaf(op, value))) {
      return failure();
    }
    debug::VariableKindAttr kind;
    if (failed(checkVariable(op, value, kind)))
      return failure();
    debug::VariableOp::create(builder, loc,
                              gi.getParamValue<StringAttr>("name"), value,
                              Value(), kind);
    return success();
  }

  // All other debug intrinsics return a handle.
  Handle handle;
  handle.op = op;
  if (intrinsic == "circt_debug_value") {
    if (failed(checkParams(op, {"typeName", "params", "name", "flip"})) ||
        gi.hasNInputs(1) || gi.sizedOutput<UIntType>(0))
      return failure();
    auto typeName = gi.getParamValue<StringAttr>("typeName");
    auto params = getParamsAttr(gi);
    Value value = op.getOperand(0);
    if (handleIndex.contains(value)) {
      auto child = useHandle(op, value);
      if (failed(child) || failed(checkNoLabel(*child, "a wrapped handle")))
        return failure();
      value = child->value;
      if ((typeName || params) && value.getDefiningOp<debug::ValueOp>())
        return op.emitOpError("must not wrap another non-empty "
                              "circt_debug_value");
    } else if (failed(checkLeaf(op, value))) {
      return failure();
    }
    // An empty wrapper lowers to its operand.
    handle.value =
        typeName || params
            ? debug::ValueOp::create(builder, loc, value, typeName, params)
                  .getResult()
            : value;
  } else if (intrinsic == "circt_debug_struct") {
    if (failed(checkParams(op, {"name", "flip"})) ||
        gi.sizedOutput<UIntType>(0))
      return failure();
    SmallVector<Value> fields;
    SmallVector<Attribute> names;
    SmallVector<bool> flips;
    for (auto operand : op.getOperands()) {
      auto child = useHandle(op, operand);
      if (failed(child))
        return failure();
      if (!child->name)
        return child->op.emitOpError("must have a 'name' as a struct field");
      fields.push_back(child->value);
      names.push_back(child->name);
      flips.push_back(child->flip);
    }
    auto flipsAttr = llvm::is_contained(flips, true)
                         ? builder.getDenseBoolArrayAttr(flips)
                         : mlir::DenseBoolArrayAttr();
    handle.value = debug::StructOp::create(
        builder, loc, fields, builder.getArrayAttr(names), flipsAttr);
  } else if (intrinsic == "circt_debug_array") {
    if (failed(checkParams(op, {"name", "flip"})) ||
        gi.sizedOutput<UIntType>(0))
      return failure();
    SmallVector<Value> elements;
    for (auto operand : op.getOperands()) {
      auto child = useHandle(op, operand);
      if (failed(child) || failed(checkNoLabel(*child, "an array element")))
        return failure();
      if (!elements.empty() && child->value.getType() != elements[0].getType())
        return op.emitOpError("has elements of different types: ")
               << elements[0].getType() << " and " << child->value.getType();
      elements.push_back(child->value);
    }
    handle.value = debug::ArrayOp::create(builder, loc, elements);
  } else if (intrinsic == "circt_debug_enum") {
    if (failed(checkParams(op, {"typeName", "fqn", "name", "flip"},
                           /*allowVariants=*/true)) ||
        gi.namedParam("typeName") || gi.hasNInputs(1) ||
        gi.sizedOutput<UIntType>(0))
      return failure();
    Value value = op.getOperand(0);
    if (handleIndex.contains(value))
      return op.emitOpError("operand must be a hardware value, not a debug "
                            "handle");
    if (type_isa<FEnumType>(value.getType()))
      return op.emitOpError("FIRRTL enum operands are not supported");
    if (!type_isa<UIntType>(value.getType()))
      return op.emitOpError("operand must be a UInt, got ") << value.getType();
    SmallVector<NamedAttribute> variants;
    auto i64 = builder.getI64Type();
    for (auto param : op.getParameters().getAsRange<ParamDeclAttr>()) {
      StringRef name = param.getName().getValue();
      if (!name.consume_front("variant_"))
        continue;
      auto tag = cast<IntegerAttr>(param.getValue());
      APInt tagValue = tag.getValue();
      if ((!tag.getType().isUnsignedInteger() && tagValue.isNegative()) ||
          tagValue.getActiveBits() > 63)
        return op.emitOpError("has tag ")
               << tag << " for variant '" << name
               << "' that is negative or does not fit in i64";
      variants.push_back(builder.getNamedAttr(
          name, IntegerAttr::get(i64, tagValue.getZExtValue())));
    }
    if (variants.empty())
      return op.emitOpError("must have at least one 'variant_' parameter");
    handle.value = debug::EnumOp::create(
        builder, loc, value, gi.getParamValue<StringAttr>("typeName"),
        builder.getDictionaryAttr(variants),
        gi.getParamValue<StringAttr>("fqn"));
  } else {
    return op.emitOpError("'")
           << intrinsic << "' is not a known debug intrinsic"
           << oldProtocolHint;
  }

  handle.name = gi.getParamValue<StringAttr>("name");
  if (auto flip = gi.getParamValue<IntegerAttr>("flip")) {
    if (!flip.getValue().isZero() && !flip.getValue().isOne())
      return op.emitOpError("has 'flip' ")
             << flip << " that is neither 0 nor 1";
    handle.flip = !flip.getValue().isZero();
  }
  handleIndex[op.getResult()] = handles.size();
  handles.push_back(handle);
  return success();
}

//===----------------------------------------------------------------------===//
// Pass Infrastructure
//===----------------------------------------------------------------------===//

namespace {
struct LowerIntrinsicsPass
    : public circt::firrtl::impl::LowerIntrinsicsBase<LowerIntrinsicsPass> {
  using LowerIntrinsicsBase::LowerIntrinsicsBase;
  LogicalResult initialize(MLIRContext *context) override;
  void runOnOperation() override;

  std::shared_ptr<IntrinsicLowerings> lowering;
};
} // namespace

/// Initialize the conversions for use during execution.
LogicalResult LowerIntrinsicsPass::initialize(MLIRContext *context) {
  IntrinsicLowerings lowering(context);

  IntrinsicLoweringInterfaceCollection loweringCollection(context);
  loweringCollection.populateIntrinsicLowerings(lowering);

  this->lowering = std::make_shared<IntrinsicLowerings>(std::move(lowering));
  return success();
}

// This is the main entrypoint for the lowering pass.
void LowerIntrinsicsPass::runOnOperation() {
  DebugIntrinsicConverter debugConverter(getOperation(), emitDebugInfo);
  if (failed(debugConverter.run()))
    return signalPassFailure();

  size_t numLowered = 0;
  if (auto module = dyn_cast<FModuleOp>(getOperation().getOperation())) {
    auto result = lowering->lower(module);
    if (failed(result))
      return signalPassFailure();
    numLowered = *result;
  }

  numConverted += numLowered;

  if (numLowered == 0 && !debugConverter.changed)
    markAllAnalysesPreserved();
}
