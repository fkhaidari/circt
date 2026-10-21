//===- CaptureDebugStmts.cpp - Record statements in debug ops -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Creates a `dbg.stmt` op for each declaration, connect and `when` of a module,
// while the `when` blocks still exist. Statements name variables by the names
// of the module's `dbg.variable` ops, so the pass runs after LowerIntrinsics.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/CHIRRTLDialect.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/Passes.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/SetVector.h"

namespace circt {
namespace firrtl {
#define GEN_PASS_DEF_CAPTUREDEBUGSTMTS
#include "circt/Dialect/FIRRTL/Passes.h.inc"
} // namespace firrtl
} // namespace circt

using namespace mlir;
using namespace circt;
using namespace firrtl;

/// Whether the location names a place in a source file.
static bool hasFileLoc(Location loc) {
  bool found = false;
  loc->walk([&](Location l) {
    if (isa<FileLineColLoc>(l))
      found = true;
    return found ? WalkResult::interrupt() : WalkResult::advance();
  });
  return found;
}

namespace {
struct CaptureDebugStmtsPass
    : public circt::firrtl::impl::CaptureDebugStmtsBase<CaptureDebugStmtsPass> {
  void runOnOperation() override;

private:
  /// Name each declaration covered by a `dbg.variable`.
  void collectNames(FModuleOp module);
  void nameLeaves(Value value, StringRef var);

  /// The source path a value denotes (`io.req.valid`, `hist[0]`), or empty if
  /// it is no variable. Indices of dynamic accesses go to `indices`.
  std::string pathOf(Value value, SmallVectorImpl<Value> *indices = nullptr);

  std::string subscript(const std::string &base, Value index);

  /// Add to `reads` the source paths the value is computed from.
  void collectReads(Value value, llvm::SetVector<StringRef> &reads);

  SmallVector<Attribute> captureBlock(Block &block);
  void createStmt(Operation *at, StringRef kind,
                  SmallVectorImpl<NamedAttribute> &fields,
                  Value guard = Value{});

  Builder *b = nullptr;
  unsigned nextId = 0;
  /// A declaration (or the access path into one a variable starts at) to the
  /// variable name.
  DenseMap<Value, std::string> names;
  /// Names of the module's variables. An aggregate variable takes its leaves,
  /// not the declaration, so the declaration is found by name.
  llvm::StringSet<> varNames;
  /// A memory op to its variable name.
  DenseMap<Operation *, StringAttr> memoryNames;
  /// Drivers of the declarations without a variable, which reads see through.
  DenseMap<Value, SmallVector<Value, 1>> tempDrivers;
  DenseSet<Value> visiting;
  /// Owns the strings `collectReads` hands out.
  llvm::StringSet<> strings;
};
} // namespace

void CaptureDebugStmtsPass::nameLeaves(Value value, StringRef var) {
  Operation *op = value.getDefiningOp();
  if (auto wrapper = dyn_cast_or_null<debug::ValueOp>(op))
    return nameLeaves(wrapper.getValue(), var);
  if (auto enumOp = dyn_cast_or_null<debug::EnumOp>(op))
    return nameLeaves(enumOp.getValue(), var);
  if (auto structOp = dyn_cast_or_null<debug::StructOp>(op)) {
    for (auto [field, name] :
         llvm::zip(structOp.getFields(), structOp.getNames()))
      nameLeaves(field, (var + "." + cast<StringAttr>(name).getValue()).str());
    return;
  }
  if (auto arrayOp = dyn_cast_or_null<debug::ArrayOp>(op)) {
    for (auto [i, elem] : llvm::enumerate(arrayOp.getElements()))
      nameLeaves(elem, (var + "[" + Twine(i) + "]").str());
    return;
  }
  names.try_emplace(value, var.str());
}

void CaptureDebugStmtsPass::collectNames(FModuleOp module) {
  module.walk([&](Operation *op) {
    if (auto var = dyn_cast<debug::VariableOp>(op)) {
      // Name the root first, so the aggregate keeps its own name even when
      // the leaves below it are named too.
      Value root = var.getValue();
      while (
          isa_and_nonnull<debug::ValueOp, debug::EnumOp>(root.getDefiningOp()))
        root = root.getDefiningOp()->getOperand(0);
      if (!isa<debug::DebugDialect>(root.getType().getDialect()))
        names.try_emplace(root, var.getName().str());
      nameLeaves(var.getValue(), var.getName());
      varNames.insert(var.getName());
      return;
    }
    if (auto memory = op->getAttrOfType<DictionaryAttr>(debug::kDbgMemoryAttr))
      if (auto name = memory.getAs<StringAttr>("name"))
        memoryNames[op] = name;
    if (auto connect = dyn_cast<FConnectLike>(op)) {
      Value dest = connect.getDest();
      while (Operation *def = dest.getDefiningOp()) {
        if (!isa<SubfieldOp, SubindexOp, SubaccessOp>(def))
          break;
        dest = def->getOperand(0);
      }
      tempDrivers[dest].push_back(connect.getSrc());
    }
  });
}

std::string CaptureDebugStmtsPass::pathOf(Value value,
                                          SmallVectorImpl<Value> *indices) {
  if (auto it = names.find(value); it != names.end())
    return it->second;
  Operation *op = value.getDefiningOp();
  if (!op) {
    // A port without a variable keeps its FIRRTL name.
    auto arg = cast<BlockArgument>(value);
    if (auto module = dyn_cast<FModuleOp>(arg.getOwner()->getParentOp()))
      return module.getPortName(arg.getArgNumber()).str();
    return {};
  }
  if (isa<WireOp, RegOp, RegResetOp, NodeOp>(op)) {
    auto name = op->getAttrOfType<StringAttr>("name");
    if (name && varNames.contains(name.getValue()))
      return name.str();
    return {};
  }
  if (auto sub = dyn_cast<SubfieldOp>(op)) {
    auto base = pathOf(sub.getInput(), indices);
    return base.empty() ? base : base + "." + sub.getFieldName().str();
  }
  if (auto sub = dyn_cast<SubindexOp>(op)) {
    auto base = pathOf(sub.getInput(), indices);
    return base.empty() ? base
                        : base + "[" + std::to_string(sub.getIndex()) + "]";
  }
  if (auto sub = dyn_cast<SubaccessOp>(op)) {
    if (indices)
      indices->push_back(sub.getIndex());
    return subscript(pathOf(sub.getInput(), indices), sub.getIndex());
  }
  if (auto inst = dyn_cast<InstanceOp>(op))
    return (inst.getInstanceName() + "." +
            inst.getPortName(cast<OpResult>(value).getResultNumber()))
        .str();
  if (auto port = dyn_cast<chirrtl::MemoryPortOp>(op)) {
    Operation *memory = port.getMemory().getDefiningOp();
    if (auto name = memoryNames.lookup(memory)) {
      std::string path = name.str();
      for (auto *user : port.getPort().getUsers())
        if (auto access = dyn_cast<chirrtl::MemoryPortAccessOp>(user)) {
          if (indices)
            indices->push_back(access.getIndex());
          path = subscript(path, access.getIndex());
        }
      return path;
    }
  }
  return {};
}

std::string CaptureDebugStmtsPass::subscript(const std::string &base,
                                             Value index) {
  if (base.empty())
    return base;
  // A subscript by a variable is written as that variable's path; by anything
  // else, the access is to the whole aggregate.
  auto path = pathOf(index);
  return path.empty() ? base : base + "[" + path + "]";
}

void CaptureDebugStmtsPass::collectReads(Value value,
                                         llvm::SetVector<StringRef> &reads) {
  if (!visiting.insert(value).second)
    return;
  SmallVector<Value> indices;
  auto path = pathOf(value, &indices);
  if (!path.empty()) {
    reads.insert(strings.insert(path).first->getKey());
  } else if (Operation *op = value.getDefiningOp()) {
    // A temporary is transparent: read what drives it.
    if (auto node = dyn_cast<NodeOp>(op))
      collectReads(node.getInput(), reads);
    else if (isa<WireOp, RegOp, RegResetOp>(op))
      for (Value driver : tempDrivers.lookup(value))
        collectReads(driver, reads);
    else if (!isa<ConstantOp, SpecialConstantOp, AggregateConstantOp,
                  InvalidValueOp>(op))
      for (Value operand : op->getOperands())
        collectReads(operand, reads);
  }
  for (Value index : indices)
    collectReads(index, reads);
  visiting.erase(value);
}

void CaptureDebugStmtsPass::createStmt(Operation *at, StringRef kind,
                                       SmallVectorImpl<NamedAttribute> &fields,
                                       Value guard) {
  fields.insert(fields.begin(),
                b->getNamedAttr("kind", b->getStringAttr(kind)));
  OpBuilder builder(at);
  debug::StmtOp::create(builder, at->getLoc(),
                        builder.getStringAttr("s" + Twine(nextId++)),
                        builder.getDictionaryAttr(fields), guard,
                        /*scope=*/Value{});
}

static ArrayAttr pathArray(Builder &b,
                           const llvm::SetVector<StringRef> &paths) {
  SmallVector<Attribute> attrs;
  for (auto path : paths)
    attrs.push_back(b.getStringAttr(path));
  return b.getArrayAttr(attrs);
}

SmallVector<Attribute> CaptureDebugStmtsPass::captureBlock(Block &block) {
  SmallVector<Attribute> ids;
  auto record = [&]() {
    ids.push_back(b->getStringAttr("s" + Twine(nextId - 1)));
  };
  for (auto &op : llvm::make_early_inc_range(block)) {
    if (auto when = dyn_cast<WhenOp>(op)) {
      // Number the block before its children, so ids follow source order.
      unsigned id = nextId++;
      SmallVector<NamedAttribute> fields;
      auto thenIds = captureBlock(when.getThenBlock());
      fields.push_back(b->getNamedAttr("then", b->getArrayAttr(thenIds)));
      if (when.hasElseRegion()) {
        auto elseIds = captureBlock(when.getElseBlock());
        fields.push_back(b->getNamedAttr("else", b->getArrayAttr(elseIds)));
      }
      // A block with no statement to stop on says nothing.
      if (thenIds.empty() &&
          (!when.hasElseRegion() ||
           cast<ArrayAttr>(fields.back().getValue()).empty()))
        continue;
      llvm::SetVector<StringRef> reads;
      collectReads(when.getCondition(), reads);
      fields.push_back(b->getNamedAttr("reads", pathArray(*b, reads)));
      fields.insert(fields.begin(),
                    b->getNamedAttr("kind", b->getStringAttr("when")));
      OpBuilder builder(when);
      debug::StmtOp::create(builder, when.getLoc(),
                            builder.getStringAttr("s" + Twine(id)),
                            builder.getDictionaryAttr(fields),
                            when.getCondition(), /*scope=*/Value{});
      ids.push_back(b->getStringAttr("s" + Twine(id)));
      continue;
    }
    if (!hasFileLoc(op.getLoc()))
      continue;

    SmallVector<NamedAttribute> fields;
    if (isa<WireOp, RegOp, RegResetOp>(op)) {
      auto var = pathOf(op.getResult(0));
      if (var.empty())
        continue;
      fields.push_back(b->getNamedAttr("var", b->getStringAttr(var)));
      bool isReg = !isa<WireOp>(op);
      if (isReg) {
        auto clock = pathOf(op.getOperand(0));
        if (!clock.empty())
          fields.push_back(b->getNamedAttr("clock", b->getStringAttr(clock)));
      }
      if (auto reg = dyn_cast<RegResetOp>(op)) {
        auto reset = pathOf(reg.getResetSignal());
        if (!reset.empty())
          fields.push_back(b->getNamedAttr("reset", b->getStringAttr(reset)));
        Value init = reg.getResetValue();
        if (auto constant = init.getDefiningOp<ConstantOp>())
          fields.push_back(b->getNamedAttr("init", constant.getValueAttr()));
        else if (auto initPath = pathOf(init); !initPath.empty())
          fields.push_back(b->getNamedAttr("init", b->getStringAttr(initPath)));
      }
      createStmt(&op, isReg ? "reg" : "wire", fields);
      record();
      continue;
    }
    if (auto name = memoryNames.lookup(&op)) {
      fields.push_back(b->getNamedAttr("var", name));
      unsigned readLatency = 0, writeLatency = 1;
      if (auto mem = dyn_cast<MemOp>(op)) {
        readLatency = mem.getReadLatency();
        writeLatency = mem.getWriteLatency();
      } else if (isa<chirrtl::SeqMemOp>(op)) {
        readLatency = 1;
      }
      fields.push_back(
          b->getNamedAttr("read_latency", b->getI32IntegerAttr(readLatency)));
      fields.push_back(
          b->getNamedAttr("write_latency", b->getI32IntegerAttr(writeLatency)));
      createStmt(&op, "mem", fields);
      record();
      continue;
    }
    if (auto inst = dyn_cast<InstanceOp>(op)) {
      fields.push_back(b->getNamedAttr("var", inst.getInstanceNameAttr()));
      createStmt(&op, "inst", fields);
      record();
      continue;
    }
    // A named node is a statement; a compiler temporary is part of the
    // statement that reads it.
    if (auto node = dyn_cast<NodeOp>(op)) {
      auto var = pathOf(node.getResult());
      if (var.empty())
        continue;
      llvm::SetVector<StringRef> reads;
      collectReads(node.getInput(), reads);
      fields.push_back(b->getNamedAttr("var", b->getStringAttr(var)));
      fields.push_back(b->getNamedAttr("reads", pathArray(*b, reads)));
      createStmt(&op, "node", fields);
      record();
      continue;
    }
    if (auto connect = dyn_cast<FConnectLike>(op)) {
      SmallVector<Value> indices;
      auto lhs = pathOf(connect.getDest(), &indices);
      if (lhs.empty())
        continue;
      llvm::SetVector<StringRef> reads;
      collectReads(connect.getSrc(), reads);
      // A write through a dynamic index reads the index, too.
      for (Value index : indices)
        collectReads(index, reads);
      fields.push_back(b->getNamedAttr("lhs", b->getStringAttr(lhs)));
      fields.push_back(b->getNamedAttr("reads", pathArray(*b, reads)));
      createStmt(&op, "connect", fields);
      record();
      continue;
    }
  }
  return ids;
}

void CaptureDebugStmtsPass::runOnOperation() {
  auto module = getOperation();
  Builder builder(module.getContext());
  b = &builder;
  nextId = 0;
  names.clear();
  memoryNames.clear();
  varNames.clear();
  tempDrivers.clear();

  collectNames(module);
  // A module without debug variables has no source view to attach to.
  if (names.empty() && memoryNames.empty())
    return markAllAnalysesPreserved();
  captureBlock(*module.getBodyBlock());
}
