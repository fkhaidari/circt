//===- UhdiInstanceVars.cpp - Debug variables for instance ports ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Describes an instance's ports from its parent module, so that the signals
// crossing an instance boundary carry a source-level name there.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLUtils.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/StringSet.h"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_UHDIINSTANCEVARS
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace firrtl;

namespace {
struct UhdiInstanceVarsPass
    : public circt::firrtl::impl::UhdiInstanceVarsBase<UhdiInstanceVarsPass> {
  void runOnOperation() override;
};
} // namespace

void UhdiInstanceVarsPass::runOnOperation() {
  FModuleOp module = getOperation();
  if (!module.getBodyBlock())
    return;

  // Pre-collect the names already spoken for so the per-instance loop can check
  // in O(1). Also what makes a re-run a no-op.
  llvm::StringSet<> existingVars;
  module.walk(
      [&](debug::VariableOp var) { existingVars.insert(var.getName()); });

  module.walk([&](InstanceOp inst) {
    StringRef instName = inst.getName();
    if (instName.empty() || existingVars.contains(instName))
      return;

    OpBuilder b(module.getContext());
    b.setInsertionPointAfter(inst);

    SmallVector<Value> fields;
    SmallVector<Attribute> names;
    for (size_t i = 0, e = inst->getNumResults(); i != e; ++i) {
      Value port = inst->getResult(i);
      // An unconnected port carries no signal to name, while a debug operand
      // on it would keep an otherwise dead port alive.
      if (port.use_empty())
        continue;
      // Null for a port the debug dialect cannot describe, a probe say.
      if (auto dbgValue = convertToDebugAggregates(b, port)) {
        fields.push_back(dbgValue);
        names.push_back(inst.getPortNameAttr(i));
      }
    }
    if (fields.empty())
      return;

    auto structOp = debug::StructOp::create(b, inst.getLoc(), fields,
                                            b.getArrayAttr(names));
    auto var = debug::VariableOp::create(b, inst.getLoc(),
                                         b.getStringAttr(instName), structOp,
                                         /*scope=*/Value());
    var->setAttr(debug::kUhdiInstanceViewAttr, b.getUnitAttr());
    existingVars.insert(instName);
  });
}
