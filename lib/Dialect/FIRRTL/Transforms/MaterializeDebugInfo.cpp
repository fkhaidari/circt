//===- MaterializeDebugInfo.cpp - DI materialization ----------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass must run BEFORE `firrtl-lower-intrinsics`. The skip-set built
// from `circt_debug_var`-intrinsics keeps us from duplicating debug variables
// that the intrinsic lowering will materialize. If the intrinsics have already
// been lowered, this pass detects the presence of `dbg.variable` ops and
// bails out per-module to avoid creating duplicates.
//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLIntrinsics.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLTypes.h"
#include "circt/Dialect/FIRRTL/FIRRTLUtils.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "circt/Support/Naming.h"
#include "mlir/IR/Attributes.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/BitVector.h"
#include "llvm/ADT/DenseSet.h"

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
  void materializeVariable(OpBuilder &builder, StringAttr name, Value value);
  void markLiveLeaves(Value value, uint64_t base, llvm::BitVector &live);
  static uint64_t maxFieldID(Type type);
};
} // namespace

void MaterializeDebugInfoPass::runOnOperation() {
  auto module = getOperation();

  // 1-operand vars are keyed by SSA Value (no cross-scope name collisions);
  // 0-operand (memory) vars are keyed by name.
  bool hasExistingVariables = false;
  DenseSet<Value> coveredByIntrinsic;
  DenseSet<StringAttr> coveredNameByIntrinsic;
  module.walk([&](Operation *op) -> WalkResult {
    if (isa<debug::VariableOp>(op)) {
      hasExistingVariables = true;
      return WalkResult::interrupt();
    }
    auto gi = dyn_cast<firrtl::GenericIntrinsicOp>(op);
    if (!gi || gi.getIntrinsic() != "circt_debug_var")
      return WalkResult::advance();
    auto varName = GenericIntrinsic(gi).getParamValue<StringAttr>("name");
    if (!varName || varName.getValue().empty())
      return WalkResult::advance();
    if (gi.getNumOperands() == 1)
      coveredByIntrinsic.insert(gi.getOperand(0));
    else if (gi.getNumOperands() == 0)
      coveredNameByIntrinsic.insert(varName);
    return WalkResult::advance();
  });
  if (hasExistingVariables) {
    module.emitWarning()
        << "MaterializeDebugInfo: dbg.variable ops already present "
           "(LowerIntrinsics likely ran first); skipping to avoid duplicates";
    return;
  }

  auto builder = OpBuilder::atBlockBegin(module.getBodyBlock());

  for (const auto &[port, value] :
       llvm::zip(module.getPorts(), module.getArguments())) {
    if (!coveredByIntrinsic.contains(value) &&
        !coveredNameByIntrinsic.contains(port.name))
      materializeVariable(builder, port.name, value);
  }

  module.walk([&](Operation *op) {
    TypeSwitch<Operation *>(op).Case<WireOp, NodeOp, RegOp, RegResetOp>(
        [&](auto op) {
          if (!coveredByIntrinsic.contains(op.getResult()) &&
              !coveredNameByIntrinsic.contains(op.getNameAttr())) {
            builder.setInsertionPointAfter(op);
            materializeVariable(builder, op.getNameAttr(), op.getResult());
          }
        });
  });

  // An instance's ports have no declaration on this side of the boundary, so
  // the signals crossing it would carry no name here; the child's own port
  // variables belong to its scope, not this one. Describe them as one struct
  // named after the instance, while the aggregate structure is still visible:
  // LowerTypes scalarises a bundle port into names in which a field and an
  // index are no longer distinguishable.
  module.walk([&](InstanceOp inst) {
    if (inst.getName().empty() ||
        coveredNameByIntrinsic.contains(inst.getNameAttr()))
      return;
    builder.setInsertionPointAfter(inst);
    SmallVector<Value> fields;
    SmallVector<Attribute> names;
    for (size_t i = 0, e = inst->getNumResults(); i != e; ++i) {
      Value port = inst->getResult(i);
      // A leaf nothing here drives or reads carries no signal to name, and a
      // debug operand on it would keep an otherwise dead port alive. Asking
      // the port as a whole is not enough: an aggregate with one live field
      // has uses, and the operand would go on every leaf.
      llvm::BitVector live(maxFieldID(port.getType()) + 1);
      markLiveLeaves(port, 0, live);
      if (live.none())
        continue;
      // Null for a port the debug dialect cannot describe, a probe say.
      if (auto dbgValue =
              convertToDebugAggregates(builder, port, [&](uint64_t fieldID) {
                return live.test(fieldID);
              })) {
        fields.push_back(dbgValue);
        names.push_back(inst.getPortNameAttr(i));
      }
    }
    if (fields.empty())
      return;
    auto structOp = debug::StructOp::create(builder, inst.getLoc(), fields,
                                            builder.getArrayAttr(names));
    debug::VariableOp::create(builder, inst.getLoc(), inst.getNameAttr(),
                              structOp, /*scope=*/Value());
  });
}

/// Mark the leaves of `value` that some op other than a subfield or subindex
/// walk reaches, by field ID relative to `base`.
void MaterializeDebugInfoPass::markLiveLeaves(Value value, uint64_t base,
                                              llvm::BitVector &live) {
  for (Operation *user : value.getUsers()) {
    if (auto sub = dyn_cast<SubfieldOp>(user)) {
      auto type = type_cast<BundleType>(value.getType());
      markLiveLeaves(sub, base + type.getFieldID(sub.getFieldIndex()), live);
    } else if (auto sub = dyn_cast<SubindexOp>(user)) {
      auto type = type_cast<FVectorType>(value.getType());
      markLiveLeaves(sub, base + type.getFieldID(sub.getIndex()), live);
    } else {
      live.set(base, base + maxFieldID(value.getType()) + 1);
    }
  }
}

/// Field IDs a type spans: only aggregates carry the interface, a ground type
/// is its own single leaf.
uint64_t MaterializeDebugInfoPass::maxFieldID(Type type) {
  if (auto fieldIDType = type_dyn_cast<hw::FieldIDTypeInterface>(type))
    return fieldIDType.getMaxFieldID();
  return 0;
}

/// Materialize debug variable ops for a value.
void MaterializeDebugInfoPass::materializeVariable(OpBuilder &builder,
                                                   StringAttr name,
                                                   Value value) {
  if (!name || isUselessName(name.getValue()))
    return;
  if (name.getValue().starts_with("_"))
    return;
  if (auto dbgValue = convertToDebugAggregates(builder, value))
    debug::VariableOp::create(builder, value.getLoc(), name, dbgValue,
                              /*scope=*/Value{});
}
