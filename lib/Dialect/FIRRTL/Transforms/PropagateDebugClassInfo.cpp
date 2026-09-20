//===- PropagateDebugClassInfo.cpp - Move class info onto instances -------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the PropagateDebugClassInfo pass, which moves the
// `dbg.moduleinfo` record from a module onto the instances of that module.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLInstanceGraph.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "mlir/Pass/Pass.h"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_PROPAGATEDEBUGCLASSINFO
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace circt;
using namespace firrtl;

namespace {
class PropagateDebugClassInfoPass
    : public impl::PropagateDebugClassInfoBase<PropagateDebugClassInfoPass> {
public:
  void runOnOperation() override {
    auto attrName = StringAttr::get(&getContext(), debug::kDbgModuleInfoAttr);
    auto &instanceGraph = getAnalysis<InstanceGraph>();

    // Copy the record of the instantiated module onto the instance.
    getOperation().walk([&](igraph::InstanceOpInterface instance) {
      Attribute info;
      bool first = true;
      // An `instance_choice` names several modules. Only a record all of them
      // agree on describes the instance.
      for (auto name : instance.getReferencedModuleNamesAttr()) {
        auto *node = instanceGraph.lookupOrNull(cast<StringAttr>(name));
        Attribute candidate;
        if (node)
          if (auto module = node->getModule())
            candidate = module->getAttr(attrName);
        if (first) {
          info = candidate;
          first = false;
        } else if (candidate != info) {
          info = {};
          break;
        }
      }
      if (info)
        instance->setAttr(attrName, info);
    });

    // Drop the record from a module once every instantiation site carries it.
    // A module keeps it when it has no instantiation site, or when one of them
    // reaches several modules that disagree.
    for (auto *node : instanceGraph) {
      auto module = node->getModule();
      if (!module || node->noUses())
        continue;
      auto info = module->getAttr(attrName);
      if (!info)
        continue;
      if (llvm::all_of(node->uses(), [&](auto *use) {
            return use->getInstance()->getAttr(attrName) == info;
          }))
        module->removeAttr(attrName);
    }

    markAllAnalysesPreserved();
  }
};
} // namespace
