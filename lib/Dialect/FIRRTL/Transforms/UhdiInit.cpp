//===- UhdiInit.cpp - Assign stable IDs to dbg.* ops ----------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Stamps `uhdi.stable_id` onto every `dbg.*` op at FIRRTL level.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/SHA256.h"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_UHDIINIT
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace firrtl;

namespace {

/// dbg.* op kinds that uhdi-init stamps.
bool isUhdiStampable(Operation *op) {
  return isa<debug::VariableOp, debug::ScopeOp, debug::StructOp, debug::ArrayOp,
             debug::ExpressionOp>(op);
}

/// Human-readable leader of the stable_id (e.g. `var_1a2b3c4d_0001`).
StringRef kindPrefix(Operation *op) {
  if (isa<debug::VariableOp>(op))
    return "var";
  if (isa<debug::ScopeOp>(op))
    return "scope";
  if (isa<debug::StructOp>(op))
    return "struct";
  if (isa<debug::ArrayOp>(op))
    return "array";
  if (isa<debug::ExpressionOp>(op))
    return "expr";
  return "dbg";
}

/// Excludes walk position so upstream inserts/removes don't perturb sibling
/// prefixes; the per-prefix counter handles ordering.
std::string hashFingerprint(Operation *op, StringRef moduleName) {
  std::string out;
  llvm::raw_string_ostream os(out);
  os << kindPrefix(op) << '|' << moduleName << '|';
  if (auto var = dyn_cast<debug::VariableOp>(op)) {
    os << var.getName() << '|' << var.getValue().getType();
    if (auto typeName = var.getTypeName())
      os << '|' << *typeName;
  } else if (auto scope = dyn_cast<debug::ScopeOp>(op)) {
    os << scope.getInstanceName() << '|' << scope.getModuleName();
  } else if (auto expr = dyn_cast<debug::ExpressionOp>(op)) {
    os << expr.getName() << '|' << expr.getOpcode() << '|'
       << expr.getExprOperands().size();
  }
  return out;
}

/// First 8 hex chars of SHA-256 -- enough to disambiguate within a module
/// (and a per-prefix counter handles the residual collisions).
std::string hashPrefix(StringRef fp) {
  llvm::SHA256 h;
  h.update(llvm::arrayRefFromStringRef(fp));
  auto d = h.final();
  return llvm::toHex(llvm::ArrayRef<uint8_t>(d.data(), 4), /*LowerCase=*/true);
}

/// Per-prefix monotonic counter rendered as a 4-hex-char zero-padded suffix.
struct CounterTable {
  llvm::StringMap<unsigned> counts;
  std::string next(StringRef prefix) {
    std::string out;
    llvm::raw_string_ostream(out).write_hex(counts[prefix]++);
    if (out.size() < 4)
      out.insert(0, 4 - out.size(), '0');
    return out;
  }

  /// Bump `counters[prefix]` past `seenSuffix` (hex) so `next()` cannot
  /// collide with an already-stamped `<kind>_<prefix>_<seenSuffix>`. Required
  /// for the second pass-run that inherits IR from the first.
  void observe(StringRef prefix, StringRef seenSuffix) {
    unsigned parsed = 0;
    if (seenSuffix.getAsInteger(/*Radix=*/16, parsed))
      return;
    auto &slot = counts[prefix];
    if (parsed >= slot)
      slot = parsed + 1;
  }
};

struct UhdiInitPass : public circt::firrtl::impl::UhdiInitBase<UhdiInitPass> {
  void runOnOperation() override;
};

} // namespace

void UhdiInitPass::runOnOperation() {
  FModuleOp module = getOperation();
  StringAttr idAttr = StringAttr::get(&getContext(), debug::kUhdiStableIdAttr);
  CounterTable counters;

  // Seed pass: existing stable_ids bump `counters[prefix]` past their hex
  // suffix. The second invocation (after Inliner) can't then re-issue IDs
  // when freshly-inlined ops hash onto prefixes the first run populated.
  module.walk([&](Operation *op) {
    if (!isUhdiStampable(op))
      return;
    auto existing = op->getAttrOfType<StringAttr>(idAttr);
    if (!existing)
      return;
    StringRef s = existing.getValue();
    auto firstUnderscore = s.find('_');
    auto lastUnderscore = s.rfind('_');
    if (firstUnderscore == StringRef::npos || lastUnderscore == firstUnderscore)
      return;
    StringRef prefix = s.slice(firstUnderscore + 1, lastUnderscore);
    StringRef suffix = s.substr(lastUnderscore + 1);
    counters.observe(prefix, suffix);
  });

  module.walk([&](Operation *op) {
    if (!isUhdiStampable(op))
      return;
    if (op->hasAttr(idAttr))
      return;
    std::string prefix = hashPrefix(hashFingerprint(op, module.getName()));
    std::string id =
        (kindPrefix(op) + "_" + prefix + "_" + counters.next(prefix)).str();
    op->setAttr(idAttr, StringAttr::get(&getContext(), id));
  });
}
