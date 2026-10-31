//===- MaterializeDebugInfo.cpp - DI materialization ----------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLIntrinsics.h"
#include "circt/Dialect/FIRRTL/FIRRTLOps.h"
#include "circt/Dialect/FIRRTL/FIRRTLTypes.h"
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
/// Debug metadata that a `circt_debug_type` or `circt_debug_enum` intrinsic
/// gives a node of a declaration.
struct DebugMeta {
  StringAttr name;
  DictionaryAttr ext;
  DictionaryAttr enumVariants;
};

/// The metadata of one declaration, by path from it.
using DebugMetas = llvm::StringMap<DebugMeta>;

/// A declaration that a debug metadata intrinsic can name.
struct Decl {
  enum Kind { Value, Memory, Instance, InstanceChoice };
  Kind kind = Value;
  /// The type of a value, null otherwise.
  Type type;
  /// Whether more than one declaration has the name.
  bool ambiguous = false;
};

struct MaterializeDebugInfoPass
    : public circt::firrtl::impl::MaterializeDebugInfoBase<
          MaterializeDebugInfoPass> {
  void runOnOperation() override;
  LogicalResult collectDebugMetas();
  LogicalResult addDebugMeta(GenericIntrinsicOp op,
                             const DenseMap<StringAttr, Decl> &decls);
  void materializeVariable(OpBuilder &builder, StringAttr name, Value value,
                           std::optional<debug::VariableKind> kind = {},
                           debug::PortDirectionAttr dir = {});
  Value convertToDebugAggregates(OpBuilder &builder, Value value,
                                 const DebugMetas *declMetas, StringRef path);

  /// The debug metadata of the module, by declaration name.
  DenseMap<StringAttr, DebugMetas> metas;

  /// The debug metadata of the module itself.
  std::optional<DebugMeta> moduleMeta;
};
} // namespace

void MaterializeDebugInfoPass::runOnOperation() {
  auto module = getOperation();
  metas.clear();
  moduleMeta.reset();
  if (failed(collectDebugMetas()))
    return signalPassFailure();

  if (moduleMeta) {
    NamedAttrList info;
    if (moduleMeta->name)
      info.append("name", moduleMeta->name);
    if (moduleMeta->ext)
      info.append("ext", moduleMeta->ext);
    module->setAttr(debug::kDbgModuleInfoAttr,
                    info.getDictionary(&getContext()));
  }

  auto builder = OpBuilder::atBlockBegin(module.getBodyBlock());

  // Create DI variables for each port.
  for (const auto &[port, value] :
       llvm::zip(module.getPorts(), module.getArguments())) {
    auto dir = port.direction == Direction::In ? debug::PortDirection::In
                                               : debug::PortDirection::Out;
    if (type_isa<AnalogType>(port.type))
      dir = debug::PortDirection::InOut;

    auto dirAttr = debug::PortDirectionAttr::get(&getContext(), dir);
    materializeVariable(builder, port.name, value, /*kind=*/{}, dirAttr);
  }

  // Create DI variables for each declaration in the module body.
  module.walk([&](Operation *op) {
    TypeSwitch<Operation *>(op)
        .Case<WireOp>([&](auto op) {
          builder.setInsertionPointAfter(op);
          materializeVariable(builder, op.getNameAttr(), op.getResult());
        })
        .Case<NodeOp>([&](auto op) {
          builder.setInsertionPointAfter(op);
          materializeVariable(builder, op.getNameAttr(), op.getResult(),
                              debug::VariableKind::Node);
        })
        .Case<RegOp, RegResetOp>([&](auto op) {
          builder.setInsertionPointAfter(op);
          materializeVariable(builder, op.getNameAttr(), op.getResult(),
                              debug::VariableKind::Reg);
        })
        .Case<InstanceOp>([&](auto op) {
          // Describe the instance by name,
          // so that it stays in the debug info when it is inlined,
          // without keeping it alive.
          builder.setInsertionPoint(op);
          auto instOp =
              debug::InstanceOp::create(builder, op.getLoc(), op.getNameAttr(),
                                        op.getModuleNameAttr().getAttr());
          if (auto it = metas.find(op.getNameAttr()); it != metas.end()) {
            const auto &meta = it->second.find("")->second;
            instOp.setTypeNameAttr(meta.name);
            instOp.setExtAttr(meta.ext);
          }
        })
        .Case<chirrtl::CombMemOp, chirrtl::SeqMemOp, MemOp>([&](auto op) {
          // A memory becomes an instance of a module made by lowering,
          // which fills in the module name, so it has none yet.
          builder.setInsertionPoint(op);
          debug::InstanceOp::create(builder, op.getLoc(), op.getNameAttr(),
                                    StringAttr{});
        });
  });
}

/// Collect the debug metadata intrinsics of the module and erase them.
LogicalResult MaterializeDebugInfoPass::collectDebugMetas() {
  auto module = getOperation();
  SmallVector<GenericIntrinsicOp> intrinsics;
  module.walk([&](GenericIntrinsicOp op) {
    if (llvm::is_contained({"circt_debug_type", "circt.debug_type",
                            "circt_debug_enum", "circt.debug_enum"},
                           op.getIntrinsic()))
      intrinsics.push_back(op);
  });

  if (intrinsics.empty())
    return success();

  // The declarations a target can name.
  DenseMap<StringAttr, Decl> decls;
  auto addDecl = [&](StringAttr name, Decl::Kind kind, Type type = {}) {
    auto [it, inserted] = decls.try_emplace(name, Decl{kind, type});
    if (!inserted)
      it->second.ambiguous = true;
  };
  for (unsigned i = 0, e = module.getNumPorts(); i < e; ++i)
    addDecl(module.getPortNameAttr(i), Decl::Value, module.getPortType(i));

  module.walk([&](Operation *op) {
    TypeSwitch<Operation *>(op)
        .Case<WireOp, NodeOp, RegOp, RegResetOp>([&](auto op) {
          addDecl(op.getNameAttr(), Decl::Value, op.getResult().getType());
        })
        .Case<chirrtl::CombMemOp, chirrtl::SeqMemOp, MemOp>(
            [&](auto op) { addDecl(op.getNameAttr(), Decl::Memory); })
        .Case<InstanceOp>(
            [&](auto op) { addDecl(op.getNameAttr(), Decl::Instance); })
        .Case<InstanceChoiceOp>(
            [&](auto op) { addDecl(op.getNameAttr(), Decl::InstanceChoice); });
  });

  bool anyFailed = false;
  for (auto op : intrinsics) {
    if (failed(addDebugMeta(op, decls)))
      anyFailed = true;
    op.erase();
  }

  return failure(anyFailed);
}

/// The type of the node at `path` in declaration `target` of type `type`.
/// A memory has a null type, and so does each node in it.
static FailureOr<Type> getPathType(GenericIntrinsic gi, StringAttr target,
                                   Type type, StringRef path) {
  auto mismatch = [&] {
    return gi.emitError() << " path '" << path
                          << "' does not match the type of '"
                          << target.getValue() << "'";
  };

  for (auto rest = path; !rest.empty();) {
    if (rest.consume_front("[*]")) {
      if (auto vector = type_dyn_cast_or_null<FVectorType>(type))
        type = vector.getElementType();
      else if (type)
        return mismatch();
      continue;
    }

    if (rest.starts_with("["))
      return gi.emitError()
             << " path '" << path << "' must index a vector with '[*]'";

    auto field = rest.drop_front().take_until(
        [](char c) { return c == '.' || c == '['; });
    if (!rest.consume_front(".") || field.empty())
      return gi.emitError() << " has a malformed path '" << path << "'";

    rest = rest.drop_front(field.size());
    if (!type)
      continue;

    auto bundle = type_dyn_cast<BundleType>(type);
    if (!bundle)
      return mismatch();

    auto index = bundle.getElementIndex(field);
    if (!index)
      return gi.emitError() << " path '" << path << "' names no field '"
                            << field << "' of '" << target.getValue() << "'";

    type = bundle.getElementType(*index);
  }

  return type;
}

/// Check that each variant of an enum fits the node it targets.
static LogicalResult verifyEnumTarget(GenericIntrinsic gi, Type type,
                                      DictionaryAttr variants,
                                      StringAttr target, StringRef path) {
  auto uintType = type_dyn_cast<UIntType>(type);
  if (!uintType)
    return gi.emitError() << " must target an unsigned integer";

  auto width = uintType.getWidth();
  if (!width)
    return success();

  for (auto variant : variants) {
    auto tag = cast<IntegerAttr>(variant.getValue()).getValue();
    if (tag.getActiveBits() > static_cast<unsigned>(*width))
      return gi.emitError()
             << " variant '" << variant.getName().getValue()
             << "' does not fit in the " << *width << "-bit target '"
             << target.getValue() << path << "'";
  }

  return success();
}

/// Check a debug metadata intrinsic against
/// the declaration it targets and record it.
LogicalResult MaterializeDebugInfoPass::addDebugMeta(
    GenericIntrinsicOp op, const DenseMap<StringAttr, Decl> &decls) {
  GenericIntrinsic gi(op);
  auto params = parseDebugMeta(gi);
  if (failed(params))
    return failure();

  DebugMeta meta{params->name, params->ext, params->enumVariants};
  auto target = params->target;
  auto path = params->path;

  if (!target) {
    if (meta.enumVariants)
      return gi.emitError() << " needs a 'target'";
    if (std::exchange(moduleMeta, meta))
      return gi.emitError() << " gives the module debug metadata twice";
    return success();
  }

  auto it = decls.find(target);
  if (it == decls.end())
    return gi.emitError() << " has no declaration named '" << target.getValue()
                          << "'";

  const auto &decl = it->second;
  if (decl.ambiguous)
    return gi.emitError() << " target '" << target.getValue()
                          << "' names more than one declaration";

  switch (decl.kind) {
  case Decl::InstanceChoice:
    return gi.emitError() << " on instance_choice '" << target.getValue()
                          << "' is not supported yet";

  case Decl::Instance:
    if (!path.empty())
      return gi.emitError() << " cannot have a 'path' on instance '"
                            << target.getValue() << "'";
    if (meta.enumVariants)
      return gi.emitError()
             << " cannot target instance '" << target.getValue() << "'";
    break;

  case Decl::Memory:
  case Decl::Value: {
    // A memory has a null type, and so does each node in it.
    auto type = getPathType(gi, target, decl.type, path);
    if (failed(type))
      return failure();

    // LowerOpenAggs drops the metadata of probe and property fields,
    // so what is left must exist.
    if (!*type)
      return success();

    if (meta.enumVariants) {
      if (failed(verifyEnumTarget(gi, *type, meta.enumVariants, target, path)))
        return failure();
    }
    break;
  }
  }

  if (!metas[target].try_emplace(path, meta).second)
    return gi.emitError() << " gives '" << target.getValue() << path
                          << "' debug metadata twice";

  return success();
}

/// Materialize debug variable ops for a value.
void MaterializeDebugInfoPass::materializeVariable(
    OpBuilder &builder, StringAttr name, Value value,
    std::optional<debug::VariableKind> kind, debug::PortDirectionAttr dir) {
  if (!name || isUselessName(name.getValue()))
    return;
  if (name.getValue().starts_with("_"))
    return;

  const DebugMetas *declMetas = nullptr;
  if (auto it = metas.find(name); it != metas.end())
    declMetas = &it->second;

  auto dbgValue = convertToDebugAggregates(builder, value, declMetas, "");
  if (!dbgValue)
    return;

  debug::VariableKindAttr kindAttr;
  if (kind)
    kindAttr = debug::VariableKindAttr::get(builder.getContext(), *kind);

  debug::VariableOp::create(builder, value.getLoc(), name, dbgValue,
                            /*scope=*/Value{}, kindAttr, dir);
}

/// The kind that `dbg.value` records for a type whose kind lowering erases.
static debug::ValueKind getValueKind(Type type) {
  if (type_isa<ClockType>(type))
    return debug::ValueKind::Clock;
  if (type_isa<AsyncResetType>(type))
    return debug::ValueKind::AsyncReset;
  if (type_isa<SIntType>(type))
    return debug::ValueKind::SInt;
  if (type_isa<ResetType>(type))
    return debug::ValueKind::Reset;
  llvm_unreachable("no value kind for this type");
}

/// Unpack all aggregates in a FIRRTL value and repack them as debug aggregates.
/// For example, converts a FIRRTL vector `v` into `dbg.array [v[0],v[1],...]`.
/// Wraps the node at `path` from the declaration in a `dbg.value` or `dbg.enum`
/// from the metadata that `declMetas` has for it.
Value MaterializeDebugInfoPass::convertToDebugAggregates(
    OpBuilder &builder, Value value, const DebugMetas *declMetas,
    StringRef path) {
  const DebugMeta *meta = nullptr;
  if (declMetas)
    if (auto it = declMetas->find(path); it != declMetas->end())
      meta = &it->second;

  auto wrap = [&](Value node) -> Value {
    if (!meta || !node)
      return node;

    if (meta->enumVariants)
      return debug::EnumOp::create(builder, value.getLoc(), node, meta->name,
                                   meta->enumVariants, meta->ext);
    return debug::ValueOp::create(builder, value.getLoc(), node,
                                  debug::ValueKindAttr{}, meta->name,
                                  meta->ext);
  };

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

          SmallString<64> fieldPath;
          if (declMetas)
            (path + "." + element.name.getValue()).toVector(fieldPath);

          auto dbgValue =
              convertToDebugAggregates(builder, subOp, declMetas, fieldPath);
          if (dbgValue) {
            fields.push_back(dbgValue);
            names.push_back(element.name);
            flips.push_back(element.isFlip);
          }
        }

        auto result =
            debug::StructOp::create(builder, value.getLoc(), fields,
                                    builder.getArrayAttr(names), flips);
        for (auto *subOp : subOps)
          if (subOp->use_empty())
            subOp->erase();

        return wrap(result);
      })
      .Case<FVectorType>([&](auto type) -> Value {
        SmallVector<Value> elements;
        SmallVector<Operation *> subOps;
        SmallString<64> elementPath;
        if (declMetas)
          (path + "[*]").toVector(elementPath);

        for (unsigned index = 0; index < type.getNumElements(); ++index) {
          auto subOp =
              SubindexOp::create(builder, value.getLoc(), value, index);
          subOps.push_back(subOp);
          auto dbgValue =
              convertToDebugAggregates(builder, subOp, declMetas, elementPath);
          if (dbgValue)
            elements.push_back(dbgValue);
        }

        Value result;
        if (!elements.empty() && elements.size() == type.getNumElements())
          result = debug::ArrayOp::create(builder, value.getLoc(), elements);
        for (auto *subOp : subOps)
          if (subOp->use_empty())
            subOp->erase();

        return wrap(result);
      })
      .Case<ClockType, ResetType, AsyncResetType, SIntType>(
          [&](auto type) -> Value {
            auto kind = getValueKind(type);

            // A type name goes on the op that carries the kind.
            StringAttr typeName;
            DictionaryAttr ext;
            if (meta) {
              typeName = meta->name;
              ext = meta->ext;
            }

            return debug::ValueOp::create(
                builder, value.getLoc(), value,
                debug::ValueKindAttr::get(builder.getContext(), kind), typeName,
                ext);
          })
      .Case<FIRRTLBaseType>(
          [&](auto type) { return type.isGround() ? wrap(value) : Value{}; })
      .Default({});
}
