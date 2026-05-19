//===- VerilogName.h - Resolve Verilog-side names for SSA values -*- C++ -*-=//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_SV_VERILOGNAME_H
#define CIRCT_DIALECT_SV_VERILOGNAME_H

#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/SV/SVOps.h"
#include "mlir/IR/Value.h"

namespace circt::sv {

/// Best-effort Verilog signal name for `value`: HW/SV module port name for
/// block-args; `hw.verilogName` or `name` on hw.wire / sv.wire / sv.reg /
/// sv.logic; `hw.verilogName` on any other op; the destination port name
/// when the value flows into `hw.output`. Walks through `sv.read_inout` so
/// inout chains from LowerToHW resolve. Empty StringAttr if nothing applies.
///
/// `hw.verilogName` is assigned by `legalizeGlobalNames`, which runs inside
/// `ExportVerilogPass::runOnOperation`. Callers scheduled before ExportVerilog
/// observe pre-legalization names — `_0`-suffix renames driven by
/// SV-keyword / sibling-decl collisions are not reflected.
inline mlir::StringAttr resolveVerilogName(mlir::Value value) {
  // Iterative loop with a depth cap to guard against malformed IR chains.
  // Well-formed inout chains form a DAG, so 32 iterations is unreachable in
  // practice but prevents stack overflow if a buggy lowering introduces a
  // cycle (misc-no-recursion).
  for (unsigned depth = 0; depth < 32; ++depth) {
    if (auto blockArg = mlir::dyn_cast<mlir::BlockArgument>(value)) {
      if (auto mod = mlir::dyn_cast<hw::HWModuleOp>(
              blockArg.getOwner()->getParentOp())) {
        auto inputIdx = blockArg.getArgNumber();
        auto pId = mod.getHWModuleType().getPortIdForInputId(inputIdx);
        if (auto attrs = mlir::dyn_cast_or_null<mlir::DictionaryAttr>(
                mod.getPortAttrs(pId)))
          if (auto vname = attrs.getAs<mlir::StringAttr>("hw.verilogName"))
            return vname;
        return mod.getInputNameAttr(inputIdx);
      }
      return {};
    }
    auto *op = mlir::cast<mlir::OpResult>(value).getOwner();
    auto pickName = [&](mlir::StringRef key) -> mlir::StringAttr {
      if (auto a = op->getAttrOfType<mlir::StringAttr>(key); a && !a.empty())
        return a;
      return {};
    };
    if (auto readInout = mlir::dyn_cast<sv::ReadInOutOp>(op)) {
      value = readInout.getInput();
      continue;
    }
    // Aggregate inout indexing ops are not a name source (leaf-only
    // resolution).
    if (mlir::isa<sv::ArrayIndexInOutOp, sv::IndexedPartSelectInOutOp,
                  sv::StructFieldInOutOp>(op))
      return {};
    // hw.instance result: <inst-vname>.<port-name>. Must precede the generic
    // hw.verilogName branch — that attribute on an instance is the instance
    // name (no port suffix), so the generic branch would drop the port.
    if (auto inst = mlir::dyn_cast<hw::HWInstanceLike>(op)) {
      auto result = mlir::cast<mlir::OpResult>(value);
      auto vname = inst->getAttrOfType<mlir::StringAttr>("hw.verilogName");
      auto instName = vname ? vname : inst.getInstanceNameAttr();
      auto portName = inst.getOutputName(result.getResultNumber());
      if (!instName || !portName)
        return {};
      llvm::SmallString<32> joined(instName.getValue());
      joined += '.';
      joined += portName.getValue();
      return mlir::StringAttr::get(op->getContext(), joined);
    }
    if (auto a = pickName("hw.verilogName"))
      return a;
    if (mlir::isa<hw::WireOp, sv::WireOp, sv::RegOp, sv::LogicOp>(op))
      if (auto b = pickName("name"))
        return b;
    for (auto &use : op->getUses())
      if (auto out = mlir::dyn_cast<hw::OutputOp>(use.getOwner()))
        if (auto mod = out->getParentOfType<hw::HWModuleOp>()) {
          auto outputIdx = use.getOperandNumber();
          auto pId = mod.getHWModuleType().getPortIdForOutputId(outputIdx);
          if (auto attrs = mlir::dyn_cast_or_null<mlir::DictionaryAttr>(
                  mod.getPortAttrs(pId)))
            if (auto vname = attrs.getAs<mlir::StringAttr>("hw.verilogName"))
              return vname;
          return mod.getOutputNameAttr(outputIdx);
        }
    return {};
  }
  return {};
}

} // namespace circt::sv

#endif // CIRCT_DIALECT_SV_VERILOGNAME_H
