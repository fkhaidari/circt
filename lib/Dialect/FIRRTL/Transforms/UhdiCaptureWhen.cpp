//===- UhdiCaptureWhen.cpp - Record control flow into dbg.rootblock ------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Capture each FIRRTL module's when/connect tree into a `dbg.rootblock`
// before `firrtl-expand-whens` flattens it into muxes.
//
// References into the debug variables are typed by what they point at: an
// SSA handle where a `dbg.expression` was materialised, a `#dbg.varref`
// naming a variable and the path into whatever aggregate it wraps, a symbol
// where the target lives in another module, and an explicit marker where a
// value has no source-level identity at all.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "circt/Dialect/HW/HWOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Pass/Pass.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "firrtl-uhdi-capture-when"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_UHDICAPTUREWHEN
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace firrtl;

namespace {

/// A statement-tree reference resolved from an SSA value: either a
/// structured reference to a debug variable, or a symbol naming a path that
/// leaves this module. Both empty when the value has no source-level
/// identity at all.
struct ResolvedRef {
  debug::VarRefAttr var;
  FlatSymbolRefAttr xmr;
  explicit operator bool() const { return var || xmr; }
};

/// Walk up a chain of firrtl.subfield ops; returns true if the root is
/// a `firrtl.mem` op.
bool isMemRootedSubfield(firrtl::SubfieldOp sub) {
  Operation *cur = sub.getInput().getDefiningOp();
  while (auto parentSub = dyn_cast_or_null<firrtl::SubfieldOp>(cur))
    cur = parentSub.getInput().getDefiningOp();
  return isa_and_nonnull<firrtl::MemOp>(cur);
}

/// Walk a FIRRTL XMR chain (`ref.resolve -> ref.sub* -> xmr.ref @sym`) to the
/// `hw.hierpath` it names. The path itself is not flattened here: a symbol
/// survives the renaming that a joined string would not, and the consumer
/// resolves it once, at serialization time.
FlatSymbolRefAttr xmrSymbol(mlir::Value value) {
  Value cur = value;
  if (auto resolve = cur.getDefiningOp<firrtl::RefResolveOp>())
    cur = resolve.getRef();
  while (auto sub = cur.getDefiningOp<firrtl::RefSubOp>())
    cur = sub.getInput();
  auto xmr = cur.getDefiningOp<firrtl::XMRRefOp>();
  if (!xmr)
    return {};
  // Confirm the symbol resolves here rather than emitting a reference the
  // consumer would have to discover is dangling.
  if (!SymbolTable::lookupNearestSymbolFrom<hw::HierPathOp>(xmr,
                                                            xmr.getRefAttr()))
    return {};
  return xmr.getRefAttr();
}

/// Find the `dbg.variable` that owns `value`, following the aggregate ops
/// that wrap it and recording the path taken. Returns null if no variable
/// claims the value.
///
/// The walk goes towards users because that is the direction the ownership
/// runs: a field value is an operand of the `dbg.struct`, which is in turn
/// the operand of the variable.
debug::VariableOp findDebugRoot(mlir::Value value,
                                SmallVectorImpl<Attribute> &path,
                                MLIRContext *ctx) {
  SmallVector<Attribute> reversed;
  Value current = value;
  // Aggregates nest finitely and every step moves strictly closer to the
  // owning variable, but bound the walk anyway rather than trust that.
  for (unsigned depth = 0; depth < 64; ++depth) {
    Value next;
    Attribute step;
    for (Operation *user : current.getUsers()) {
      if (auto var = dyn_cast<debug::VariableOp>(user)) {
        if (var.getValue() != current)
          continue;
        path.assign(reversed.rbegin(), reversed.rend());
        return var;
      }
      if (auto wrapper = dyn_cast<debug::ValueOp>(user)) {
        if (wrapper.getValue() == current) {
          next = wrapper.getResult();
          break;
        }
        continue;
      }
      if (auto structOp = dyn_cast<debug::StructOp>(user)) {
        for (auto [name, field] :
             llvm::zip(structOp.getNames(), structOp.getFields()))
          if (field == current) {
            step = name;
            next = structOp.getResult();
            break;
          }
        if (next)
          break;
        continue;
      }
      if (auto arrayOp = dyn_cast<debug::ArrayOp>(user)) {
        for (auto [index, element] : llvm::enumerate(arrayOp.getElements()))
          if (element == current) {
            step = IntegerAttr::get(IntegerType::get(ctx, 64), index);
            next = arrayOp.getResult();
            break;
          }
        if (next)
          break;
      }
    }
    if (!next)
      return {};
    if (step)
      reversed.push_back(step);
    current = next;
  }
  return {};
}

static debug::VarRefAttr plainRef(MLIRContext *ctx, StringRef name) {
  return debug::VarRefAttr::get(ctx, StringAttr::get(ctx, name), {});
}

/// Resolve the source-level identity of an SSA value.
ResolvedRef resolveRef(mlir::Value value, MLIRContext *ctx) {
  // A value that sits inside an aggregate can only be named through it.
  // After LowerTypes such a field is an ordinary scalar whose own name
  // ("io_a") says nothing about where it came from, while the `dbg.struct`
  // still wrapping it says exactly that. Reading the name in that case would
  // produce a reference matching nothing in the emitted document.
  //
  // A value the debug ops name directly is a different matter: several
  // variables may alias one value (a register and the output port reading
  // it), and picking whichever the use list yields first would name the
  // wrong one. Its own declaration is the reliable answer, so that is tried
  // first below and this walk is the fallback.
  SmallVector<Attribute> path;
  debug::VariableOp owner = findDebugRoot(value, path, ctx);
  if (owner && !path.empty())
    return {debug::VarRefAttr::get(ctx, owner.getNameAttr(), path), {}};

  auto fromOwner = [&]() -> ResolvedRef {
    if (!owner)
      return {};
    return {debug::VarRefAttr::get(ctx, owner.getNameAttr(), {}), {}};
  };

  if (auto blockArg = dyn_cast<BlockArgument>(value)) {
    auto mod = dyn_cast<firrtl::FModuleOp>(blockArg.getOwner()->getParentOp());
    if (!mod)
      return fromOwner();
    return {plainRef(ctx, mod.getPortName(blockArg.getArgNumber())), {}};
  }

  auto opResult = dyn_cast<OpResult>(value);
  if (!opResult)
    return fromOwner();
  Operation *defOp = opResult.getOwner();

  if (auto name = defOp->getAttrOfType<StringAttr>("name");
      name && !name.getValue().empty())
    return {debug::VarRefAttr::get(ctx, name, {}), {}};

  // Prevents a silent drop on `connect dest, otherModule.signal`.
  if (isa<firrtl::RefResolveOp>(defOp))
    if (auto sym = xmrSymbol(value))
      return {{}, sym};

  if (auto sub = dyn_cast<firrtl::SubfieldOp>(defOp)) {
    auto bundle = dyn_cast<firrtl::BundleType>(sub.getInput().getType());
    if (!bundle)
      return {};
    ResolvedRef parent = resolveRef(sub.getInput(), ctx);
    if (!parent.var)
      return {};
    StringRef field = bundle.getElementName(sub.getFieldIndex());
    if (field.empty())
      return parent;
    // A memory port field is synthesised as one flat `dbg.variable` named
    // "<mem>_<port>_<field>" (see synthesizeMemPortVariables), so name that
    // variable directly rather than stepping into an aggregate nobody built.
    if (isMemRootedSubfield(sub))
      return {
          plainRef(ctx, (parent.var.getRoot().getValue() + "_" + field).str()),
          {}};
    SmallVector<Attribute> steps(parent.var.getPath());
    steps.push_back(StringAttr::get(ctx, field));
    return {debug::VarRefAttr::get(ctx, parent.var.getRoot(), steps), {}};
  }

  if (auto idx = dyn_cast<firrtl::SubindexOp>(defOp)) {
    ResolvedRef parent = resolveRef(idx.getInput(), ctx);
    if (!parent.var)
      return {};
    SmallVector<Attribute> steps(parent.var.getPath());
    steps.push_back(
        IntegerAttr::get(IntegerType::get(ctx, 64), idx.getIndex()));
    return {debug::VarRefAttr::get(ctx, parent.var.getRoot(), steps), {}};
  }

  // A dynamic index selects no statically known element, so the reference
  // names the aggregate itself. Less precise than the element, but true --
  // the alternative would be inventing a step that does not resolve.
  if (auto acc = dyn_cast<firrtl::SubaccessOp>(defOp))
    return resolveRef(acc.getInput(), ctx);

  return fromOwner();
}

/// Map a FIRRTL primop to its UHDI spec §5 opcode string. Empty when the
/// op isn't one we materialise into a `dbg.expression`.
StringRef firrtlOpcode(Operation *op) {
  if (isa<firrtl::AndPrimOp>(op))
    return "&";
  if (isa<firrtl::OrPrimOp>(op))
    return "|";
  if (isa<firrtl::XorPrimOp>(op))
    return "^";
  if (isa<firrtl::NotPrimOp>(op))
    return "!";
  if (isa<firrtl::EQPrimOp>(op))
    return "==";
  if (isa<firrtl::NEQPrimOp>(op))
    return "!=";
  if (isa<firrtl::LTPrimOp>(op))
    return "<";
  if (isa<firrtl::LEQPrimOp>(op))
    return "<=";
  if (isa<firrtl::GTPrimOp>(op))
    return ">";
  if (isa<firrtl::GEQPrimOp>(op))
    return ">=";
  return "";
}

/// Look up an SSA value at module-body scope that carries the same
/// runtime value as `value`. Returns `value` itself if it's already at
/// module body (block-arg or top-level op result), or if a `dbg.variable`
/// wrapping it lives there. Null otherwise; caller breaks the chain.
mlir::Value findModuleBodyProxy(mlir::Value value, FModuleOp module) {
  Block *moduleBody = module.getBodyBlock();
  // A module-body constant is a valid operand for the expression we build at
  // module-body level. We still require its defining block to BE the module
  // body: although constants are pure, MLIR SSA dominance is structural, so a
  // constant defined inside a when-block (child region) does not dominate the
  // module-body insertion point. Such a leaf is left unresolved here, which
  // breaks the chain and falls back to the `<complex>` sentinel.
  if (auto opResult = dyn_cast<OpResult>(value))
    if (isa<firrtl::ConstantOp>(opResult.getOwner()) &&
        opResult.getOwner()->getBlock() == moduleBody)
      return value;
  // Direct: the value itself is at module body.
  Block *owner = isa<BlockArgument>(value)
                     ? cast<BlockArgument>(value).getOwner()
                     : cast<OpResult>(value).getOwner()->getBlock();
  if (owner == moduleBody)
    return value;
  // Search for a dbg.variable consuming this value whose own scope is the
  // module body.
  bool annotated = llvm::any_of(value.getUsers(), [&](Operation *user) {
    auto var = dyn_cast<debug::VariableOp>(user);
    return var && var.getValue() == value && var->getBlock() == moduleBody;
  });
  return annotated ? value : Value{};
}

/// Materialise a `dbg.expression` tree at module-body level for a compound
/// when-condition. Each operand is either an existing module-body proxy or
/// the result of a recursive call. Returns null on unsupported shapes
/// (caller falls back to `<complex>` sentinel).
mlir::Value materializeExpression(mlir::Value cond,
                                  debug::RootBlockOp rootBlock,
                                  FModuleOp module, unsigned &counter) {
  auto opResult = dyn_cast<OpResult>(cond);
  if (!opResult)
    return {};
  Operation *defOp = opResult.getOwner();

  // Peel through `firrtl.node` wrappers: Chisel compiles `when(expr)` into
  // a named node wrapping the actual primop. `firrtlOpcode` won't recognise
  // NodeOp, so we'd fall back to `<complex>` without this peel.
  while (auto node = dyn_cast<firrtl::NodeOp>(defOp)) {
    auto inner = dyn_cast<OpResult>(node.getInput());
    if (!inner)
      return {};
    defOp = inner.getOwner();
  }

  // No block check on `defOp` itself: we never reference its result, only
  // rebuild the expression from resolved operands. The primop may live in a
  // child region (e.g. computed inside an outer `when`); what must dominate
  // the module-body insertion point are the *leaves*, which
  // `findModuleBodyProxy` and the recursion below already enforce (an
  // unresolvable leaf breaks the chain and falls back to `<complex>`).
  StringRef opcode = firrtlOpcode(defOp);
  if (opcode.empty())
    return {};

  // Resolve each operand to a dominating handle.
  SmallVector<Value, 2> operands;
  for (Value operand : defOp->getOperands()) {
    if (Value proxy = findModuleBodyProxy(operand, module)) {
      operands.push_back(proxy);
      continue;
    }
    // Recurse: maybe operand is a nested compound primop.
    Value sub = materializeExpression(operand, rootBlock, module, counter);
    if (!sub)
      return {};
    operands.push_back(sub);
  }

  auto *ctx = rootBlock.getContext();
  std::string name =
      ("__uhdi_expr_" + module.getName() + "_" + std::to_string(counter++))
          .str();
  OpBuilder b(rootBlock);
  auto expr = debug::ExpressionOp::create(
      b, module.getLoc(),
      debug::RefType::get(ctx), // result type
      StringAttr::get(ctx, name), StringAttr::get(ctx, opcode), operands,
      /*scope=*/Value());
  return expr.getResult();
}

/// Synthesize `dbg.variable "<mem>_<port>_<field>"` per `firrtl.mem`
/// port-field. Names match post-LowerCHIRRTL flat-wire / native HGLDD
/// convention so statement-tree refs and the snapshot pass agree.
/// Idempotent: skips variables whose names already exist in the module,
/// so a second run (e.g. after ModuleInliner) does not produce duplicates.
void synthesizeMemPortVariables(FModuleOp module) {
  // Pre-collect names of existing dbg.variable ops once so the per-field
  // loop can do an O(1) existence check without re-walking.
  llvm::StringSet<> existingVars;
  module.walk(
      [&](debug::VariableOp var) { existingVars.insert(var.getName()); });

  module.walk([&](firrtl::MemOp memOp) {
    StringRef memName = memOp.getName();
    OpBuilder b(module.getContext());
    b.setInsertionPointAfter(memOp);
    for (size_t i = 0, e = memOp->getNumResults(); i < e; ++i) {
      Value port = memOp->getResult(i);
      StringRef portName = memOp.getPortName(i);
      auto bundleType = dyn_cast<firrtl::BundleType>(port.getType());
      if (!bundleType)
        continue;
      for (size_t f = 0, fe = bundleType.getNumElements(); f < fe; ++f) {
        StringRef fieldName = bundleType.getElementName(f);
        std::string varName =
            (memName + "_" + portName + "_" + fieldName).str();
        // Skip if a variable with this name was already synthesised on a
        // prior run (idempotency for re-runs after ModuleInliner).
        if (existingVars.contains(varName))
          continue;
        auto subfield = firrtl::SubfieldOp::create(b, memOp.getLoc(), port, f);
        debug::VariableOp::create(b, memOp.getLoc(), b.getStringAttr(varName),
                                  subfield.getResult(),
                                  /*scope=*/Value());
      }
    }
  });
}

static Value getAggregateRoot(Value v) {
  while (auto *def = v.getDefiningOp()) {
    if (auto s = dyn_cast<firrtl::SubfieldOp>(def)) {
      v = s.getInput();
      continue;
    }
    if (auto i = dyn_cast<firrtl::SubindexOp>(def)) {
      v = i.getInput();
      continue;
    }
    if (auto a = dyn_cast<firrtl::SubaccessOp>(def)) {
      v = a.getInput();
      continue;
    }
    break;
  }
  return v;
}

void emitConnectStmt(firrtl::FConnectLike connect, OpBuilder &b) {
  auto *ctx = b.getContext();
  ResolvedRef dest = resolveRef(connect.getDest(), ctx);
  if (!dest.var) {
    // Anonymous LHS -- there is no assignment target to name. Drop and log
    // under -debug-only.
    LLVM_DEBUG(llvm::dbgs() << "uhdi: drop connect at " << connect.getLoc()
                            << " (unnamed destination)\n");
    return;
  }

  ResolvedRef source = resolveRef(connect.getSrc(), ctx);
  Attribute src;
  if (source.var)
    src = source.var;
  else if (source.xmr)
    src = source.xmr;
  else
    // Constant- or temp-wire-driven: nothing names the source. Record that
    // rather than dropping the statement, so the assignment still shows up.
    src = debug::ConstSourceAttr::get(ctx);

  // A regreset connect only takes effect while reset is low, because reset
  // has implicit priority over it. That is a condition like any other, so it
  // is recorded the same way -- as an enclosing subblock -- rather than as a
  // field only this one statement kind would carry.
  //
  // NOTE: async and synchronous resets are treated identically. Async resets
  // are level-sensitive and should deactivate the data path whenever the
  // signal is high, so `!reset` is the right condition under UHDI's
  // over-approximating capture semantics either way.
  //
  // The destination may be a field or element of an aggregate register, so
  // walk to the root declaration before asking whether it is a regreset.
  Value rootDest = getAggregateRoot(connect.getDest());
  if (auto regreset = rootDest.getDefiningOp<firrtl::RegResetOp>()) {
    ResolvedRef reset = resolveRef(regreset.getResetSignal(), ctx);
    // An unnameable reset still gates the connect; say so explicitly rather
    // than letting the condition disappear.
    Attribute condition = reset.var
                              ? Attribute(reset.var)
                              : Attribute(debug::OpaqueCondAttr::get(ctx));
    auto guard =
        debug::SubBlockOp::create(b, connect.getLoc(),
                                  /*condition=*/Value(), condition,
                                  /*negated=*/BoolAttr::get(ctx, true));
    guard.getBody().emplaceBlock();
    OpBuilder inner = OpBuilder::atBlockBegin(&guard.getBody().front());
    debug::ConnectStmtOp::create(inner, connect.getLoc(), dest.var, src);
    return;
  }

  debug::ConnectStmtOp::create(b, connect.getLoc(), dest.var, src);
}

void emitDeclStmt(Operation *decl, OpBuilder &b) {
  auto *ctx = b.getContext();
  // Resolve the declared value rather than reading the declaration's name.
  // A scalarised aggregate field is declared under a flattened name that
  // names no variable ("io_a"), while the aggregate wrapping it does.
  if (decl->getNumResults() == 1)
    if (ResolvedRef ref = resolveRef(decl->getResult(0), ctx); ref.var) {
      debug::DeclStmtOp::create(b, decl->getLoc(), ref.var);
      return;
    }
  // wire / reg / regreset / node carry `$name`.
  StringAttr name = decl->getAttrOfType<StringAttr>("name");
  if (!name || name.getValue().empty())
    return;
  debug::DeclStmtOp::create(b, decl->getLoc(),
                            debug::VarRefAttr::get(ctx, name, {}));
}

/// Walk state: insertion anchor for materialised `dbg.expression` ops
/// and a per-module counter for their synthesised names.
/// NOTE: `counter` is reset to 0 on each pass invocation. If the pass
/// runs more than once on the same module (e.g. clones from ModuleInliner),
/// the synthesised names (`__uhdi_expr_<Mod>_<N>`) may collide with those
/// from the first run. This is assumed to be a single-pass scenario;
/// a stable-hash scheme (similar to UhdiInit) would be needed to support
/// multiple invocations correctly.
struct ExprSink {
  debug::RootBlockOp rootBlock;
  FModuleOp module;
  unsigned counter = 0;
};

void walkRegion(Region &region, OpBuilder &b, ExprSink &sink) {
  if (region.empty())
    return;
  auto *ctx = b.getContext();
  // A `when` condition is recorded one of three ways, in order of how much
  // the consumer can do with it: an SSA handle on a materialised
  // `dbg.expression`, a reference to the variable that names it, or the
  // explicit statement that it did not reduce to either.
  auto emitBranch = [&](Region &branch, Location loc, Value condition,
                        Attribute conditionRef, bool negated) {
    auto block = debug::SubBlockOp::create(b, loc, condition, conditionRef,
                                           BoolAttr::get(ctx, negated));
    block.getBody().emplaceBlock();
    OpBuilder inner = OpBuilder::atBlockBegin(&block.getBody().front());
    walkRegion(branch, inner, sink);
  };
  for (Operation &op : region.front()) {
    if (auto when = dyn_cast<firrtl::WhenOp>(op)) {
      Value condition;
      Attribute conditionRef;
      if (ResolvedRef named = resolveRef(when.getCondition(), ctx); named.var)
        conditionRef = named.var;
      else if (Value expr =
                   materializeExpression(when.getCondition(), sink.rootBlock,
                                         sink.module, sink.counter))
        condition = expr;
      else
        conditionRef = debug::OpaqueCondAttr::get(ctx);

      emitBranch(when.getThenRegion(), when.getLoc(), condition, conditionRef,
                 /*negated=*/false);
      if (when.hasElseRegion() && !when.getElseRegion().empty())
        emitBranch(when.getElseRegion(), when.getLoc(), condition, conditionRef,
                   /*negated=*/true);
    } else if (auto connect = dyn_cast<firrtl::FConnectLike>(op)) {
      emitConnectStmt(connect, b);
    } else if (isa<firrtl::WireOp, firrtl::RegOp, firrtl::RegResetOp,
                   firrtl::NodeOp>(op)) {
      emitDeclStmt(&op, b);
    }
  }
}

struct UhdiCaptureWhenPass
    : public circt::firrtl::impl::UhdiCaptureWhenBase<UhdiCaptureWhenPass> {
  void runOnOperation() override;
};

} // namespace

void UhdiCaptureWhenPass::runOnOperation() {
  firrtl::FModuleOp module = getOperation();

  // Defensive: FExtModuleOp and other FModuleLike variants have no body.
  if (!module.getBodyBlock())
    return;

  // Mem-port wrappers are synthesised unconditionally so that a second
  // run (e.g. after ModuleInliner) still produces them even when the
  // dbg.rootblock is already present. synthesizeMemPortVariables is
  // idempotent: it skips names that already exist.
  synthesizeMemPortVariables(module);

  // Idempotent on re-runs: the rootblock walk and connect-tree capture
  // are skipped if a dbg.rootblock is already present. Mem wrappers
  // above must be created first so that reference resolution can reach the
  // variables they synthesise on a fresh run.
  bool already = false;
  module.walk([&](debug::RootBlockOp) {
    already = true;
    return WalkResult::interrupt();
  });
  if (already)
    return;

  OpBuilder top = OpBuilder::atBlockEnd(module.getBodyBlock());
  auto body = debug::RootBlockOp::create(top, module.getLoc(), mlir::Value());
  body.getBody().emplaceBlock();
  OpBuilder inner = OpBuilder::atBlockBegin(&body.getBody().front());

  ExprSink sink{body, module, /*counter=*/0};
  walkRegion(*module.getBodyBlock()->getParent(), inner, sink);
}
