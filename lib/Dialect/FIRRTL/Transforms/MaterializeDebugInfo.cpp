//===- MaterializeDebugInfo.cpp - DI materialization ----------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLTypes.h"
#include "circt/Dialect/FIRRTL/FIRRTLUtils.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "circt/Support/Naming.h"
#include "mlir/IR/Attributes.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_MATERIALIZEDEBUGINFO
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace firrtl;

namespace {
struct MaterializeDebugInfoPass
    : public circt::firrtl::impl::MaterializeDebugInfoBase<
          MaterializeDebugInfoPass> {
  void runOnOperation() override;
  void materializeVariable(OpBuilder &builder, StringAttr name, Value value,
                           debug::VariableKind kind,
                           const DenseSet<Value> &describedRoots);
  Value convertToDebugAggregates(OpBuilder &builder, Value value,
                                 bool &hasEnum);
};
} // namespace

void MaterializeDebugInfoPass::runOnOperation() {
  auto module = getOperation();
  auto builder = OpBuilder::atBlockBegin(module.getBodyBlock());

  // Collect the FieldRef roots of the FIRRTL values that existing Debug ops
  // point at, for example those converted from the frontend's intrinsics.
  DenseSet<Value> describedRoots;
  module.walk([&](Operation *op) {
    if (!isa<debug::DebugDialect>(op->getDialect()))
      return;
    for (auto operand : op->getOperands())
      if (type_isa<FIRRTLBaseType>(operand.getType()))
        describedRoots.insert(getFieldRefFromValue(operand).getValue());
  });

  // Create DI variables for each port.
  for (const auto &[port, value] :
       llvm::zip(module.getPorts(), module.getArguments())) {
    auto kind = port.direction == Direction::In ? debug::VariableKind::Input
                                                : debug::VariableKind::Output;
    if (type_isa<AnalogType>(port.type))
      kind = debug::VariableKind::InOut;
    materializeVariable(builder, port.name, value, kind, describedRoots);
  }

  // Create DI variables for each declaration in the module body.
  module.walk([&](Operation *op) {
    TypeSwitch<Operation *>(op).Case<WireOp, NodeOp, RegOp, RegResetOp>(
        [&](auto op) {
          auto kind = isa<WireOp>(op)   ? debug::VariableKind::Wire
                      : isa<NodeOp>(op) ? debug::VariableKind::Node
                                        : debug::VariableKind::Reg;
          builder.setInsertionPointAfter(op);
          materializeVariable(builder, op.getNameAttr(), op.getResult(), kind,
                              describedRoots);
        });
  });
}

/// Materialize debug variable ops for a value.
void MaterializeDebugInfoPass::materializeVariable(OpBuilder &builder,
                                                   StringAttr name, Value value,
                                                   debug::VariableKind kind,
                                                   const DenseSet<Value> &describedRoots) {
  if (!name || isUselessName(name.getValue()))
    return;
  if (name.getValue().starts_with("_"))
    return;
  if (describedRoots.contains(value))
    return;
  bool hasEnum = false;
  auto dbgValue = convertToDebugAggregates(builder, value, hasEnum);
  if (hasEnum)
    mlir::emitWarning(value.getLoc())
        << "'" << name.getValue()
        << "' has enum-typed values without debug info; FIRRTL enums are not "
           "supported";
  if (dbgValue)
    debug::VariableOp::create(
        builder, value.getLoc(), name, dbgValue, /*scope=*/Value{},
        debug::VariableKindAttr::get(builder.getContext(), kind));
}

/// Unpack all aggregates in a FIRRTL value and repack them as debug aggregates.
/// For example, converts a FIRRTL vector `v` into `dbg.array [v[0],v[1],...]`.
Value MaterializeDebugInfoPass::convertToDebugAggregates(OpBuilder &builder,
                                                         Value value,
                                                         bool &hasEnum) {
  return FIRRTLTypeSwitch<Type, Value>(value.getType())
      .Case<BundleType>([&](auto type) {
        SmallVector<Value> fields;
        SmallVector<Attribute> names;
        SmallVector<bool> flips;
        SmallVector<Operation *> subOps;
        for (auto [index, element] : llvm::enumerate(type.getElements())) {
          auto subOp =
              SubfieldOp::create(builder, value.getLoc(), value, index);
          subOps.push_back(subOp);
          if (auto dbgValue = convertToDebugAggregates(builder, subOp, hasEnum)) {
            fields.push_back(dbgValue);
            names.push_back(element.name);
            flips.push_back(element.isFlip);
          }
        }
        auto flipsAttr = llvm::is_contained(flips, true)
                             ? builder.getDenseBoolArrayAttr(flips)
                             : DenseBoolArrayAttr();
        auto result =
            debug::StructOp::create(builder, value.getLoc(), fields,
                                    builder.getArrayAttr(names), flipsAttr);
        for (auto *subOp : subOps)
          if (subOp->use_empty())
            subOp->erase();
        return result;
      })
      .Case<FVectorType>([&](auto type) -> Value {
        SmallVector<Value> elements;
        SmallVector<Operation *> subOps;
        for (unsigned index = 0; index < type.getNumElements(); ++index) {
          auto subOp =
              SubindexOp::create(builder, value.getLoc(), value, index);
          subOps.push_back(subOp);
          if (auto dbgValue = convertToDebugAggregates(builder, subOp, hasEnum))
            elements.push_back(dbgValue);
        }
        Value result;
        if (!elements.empty() && elements.size() == type.getNumElements())
          result = debug::ArrayOp::create(builder, value.getLoc(), elements);
        for (auto *subOp : subOps)
          if (subOp->use_empty())
            subOp->erase();
        return result;
      })
      .Case<FEnumType>([&](auto) {
        hasEnum = true;
        return Value{};
      })
      .Case<FIRRTLBaseType>(
          [&](auto type) { return type.isGround() ? value : Value{}; })
      .Default({});
}
