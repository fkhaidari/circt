//===- EmitUHDI.cpp - UHDI debug info emission ----------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Emits debug information as a UHDI JSON document.
//
// A module with a `dbg.module` implementation binding is a source module, and
// so is a module that nothing instantiates. Any other module was made by the
// compiler and is transparent: its variables and instances move into the scope
// that instantiates it, and their signals are named by a hierarchical path from
// there. A targeted `dbg.scope` describes a live instance; an untargeted scope
// referencing `dbg.module` describes an inlined instance.
//
// Signal names are the Verilog names that ExportVerilog leaves on the IR, so
// this runs after ExportVerilog.
//
//===----------------------------------------------------------------------===//

#include "DebugInfoUtils.h"
#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/HW/InnerSymbolTable.h"
#include "circt/Dialect/SV/SVOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Support/Version.h"
#include "circt/Target/DebugInfo.h"
#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/ADT/TypeSwitch.h"
#include "llvm/Support/JSON.h"
#include <deque>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <vector>

using namespace circt;
namespace json = llvm::json;
using llvm::StringRef;
using mlir::Operation;
using mlir::Value;

//===----------------------------------------------------------------------===//
// Signal names
//===----------------------------------------------------------------------===//

static std::optional<StringRef> getInputPortName(Value value) {
  auto arg = dyn_cast<mlir::BlockArgument>(value);
  if (!arg)
    return std::nullopt;

  auto module = dyn_cast<hw::HWModuleOp>(arg.getOwner()->getParentOp());
  if (!module)
    return std::nullopt;

  return module.getPort(module.getPortIdForInputId(arg.getArgNumber()))
      .getVerilogName();
}

static std::optional<StringRef> getOutputPortName(Value value) {
  for (auto &use : value.getUses()) {
    if (!isa<hw::OutputOp>(use.getOwner()))
      continue;
    auto module = cast<hw::HWModuleOp>(use.getOwner()->getParentOp());
    return module.getPort(module.getPortIdForOutputId(use.getOperandNumber()))
        .getVerilogName();
  }
  return std::nullopt;
}

static std::optional<StringRef> getDeclaredName(Operation *op) {
  if (!isa_and_nonnull<hw::WireOp, sv::WireOp, sv::RegOp, sv::LogicOp,
                       seq::FirRegOp>(op))
    return std::nullopt;

  if (auto name = op->getAttrOfType<mlir::StringAttr>("hw.verilogName");
      name && !name.empty())
    return name.getValue();
  if (auto name = op->getAttrOfType<mlir::StringAttr>("name");
      name && !name.empty())
    return name.getValue();
  return std::nullopt;
}

/// The port that a wire only aliases: a wire driven by an input port, or one
/// read by `hw.output`. ExportVerilog may rename such a wire (`io_a` to
/// `io_a_0`); the port keeps the source name.
static std::optional<StringRef> getAliasedPortName(Value wire) {
  if (!isa_and_nonnull<sv::WireOp, sv::LogicOp>(wire.getDefiningOp()))
    return std::nullopt;

  for (auto *user : wire.getUsers()) {
    if (auto assign = dyn_cast<sv::AssignOp>(user);
        assign && assign.getDest() == wire)
      if (auto name = getInputPortName(assign.getSrc()))
        return name;
    if (auto read = dyn_cast<sv::ReadInOutOp>(user))
      if (auto name = getOutputPortName(read))
        return name;
  }
  return std::nullopt;
}

/// The signal that holds `value` in its own module.
static std::optional<StringRef> getSignalName(Value value) {
  // A wire or reg is read through `sv.read_inout`.
  if (auto read = value.getDefiningOp<sv::ReadInOutOp>()) {
    value = read.getInput();
    if (auto name = getAliasedPortName(value))
      return name;
  }
  if (auto name = getInputPortName(value))
    return name;
  if (auto name = getDeclaredName(value.getDefiningOp()))
    return name;
  return getOutputPortName(value);
}

static StringRef getInstanceName(hw::InstanceOp inst) {
  if (auto name = inst->getAttrOfType<mlir::StringAttr>("hw.verilogName"))
    return name.getValue();
  return inst.getInstanceName();
}

/// All bits of `value` as `0b...`, most significant first.
static std::string getBits(const llvm::APInt &value) {
  std::string bits = "0b";
  bits.reserve(2 + value.getBitWidth());
  for (unsigned i = value.getBitWidth(); i-- > 0;)
    bits += value[i] ? '1' : '0';
  return bits;
}

/// The low bit of the field that `op` selects in its input.
static std::optional<int64_t> getLowBit(hw::StructExtractOp op) {
  // A packed struct keeps its first field in the most significant bits.
  auto fields =
      hw::type_cast<hw::StructType>(op.getInput().getType()).getElements();
  int64_t lowBit = 0;
  for (auto field : fields.drop_front(op.getFieldIndex() + 1)) {
    auto width = hw::getBitWidth(field.type);
    if (width < 0)
      return std::nullopt;
    lowBit += width;
  }
  return lowBit;
}

/// The low bit of the element that `op` selects in its input,
/// if the index is a constant.
static std::optional<int64_t> getLowBit(hw::ArrayGetOp op) {
  auto index = op.getIndex().getDefiningOp<hw::ConstantOp>();
  if (!index)
    return std::nullopt;

  // A packed array keeps element 0 in the least significant bits.
  auto elementType =
      hw::type_cast<hw::ArrayType>(op.getInput().getType()).getElementType();
  auto width = hw::getBitWidth(elementType);
  if (width < 0)
    return std::nullopt;
  return index.getValue().getZExtValue() * width;
}

static std::optional<int64_t> getLowBit(Operation *op) {
  return llvm::TypeSwitch<Operation *, std::optional<int64_t>>(op)
      .Case<hw::StructExtractOp, hw::ArrayGetOp>(
          [](auto op) { return getLowBit(op); })
      .Case([](comb::ExtractOp op) { return int64_t(op.getLowBit()); })
      .Default(std::optional<int64_t>());
}

static json::Value getOptimizedOut() {
  return json::Object{{"$optimized_out", true}};
}

//===----------------------------------------------------------------------===//
// Debug value trees
//===----------------------------------------------------------------------===//

/// The debug values that `value` is built from.
static mlir::OperandRange getDebugOperands(Value value) {
  auto *op = value.getDefiningOp();
  if (isa_and_nonnull<debug::ValueOp, debug::EnumOp, debug::StructOp,
                      debug::ArrayOp>(op))
    return op->getOperands();
  return {nullptr, 0};
}

/// Call `fn` on `root` and on the values it is built from, children first.
/// A value used twice is visited once: CSE shares sub-trees.
static void walkDebugValue(Value root, llvm::function_ref<void(Value)> fn) {
  SmallVector<std::pair<Value, bool>> stack{{root, false}};
  llvm::DenseSet<Value> expanded;
  while (!stack.empty()) {
    auto [value, ready] = stack.pop_back_val();
    if (ready) {
      fn(value);
      continue;
    }
    // Marking a value when it is pushed would be too early: a parent could
    // then finish before a child that still waits on the stack.
    if (!expanded.insert(value).second)
      continue;
    stack.push_back({value, true});
    for (auto operand : llvm::reverse(getDebugOperands(value)))
      stack.push_back({operand, false});
  }
}

/// The language data of a debug op: its `ext`, the frontend's JSON string. The
/// JSON is an object that names the language of each entry by an `x-` key.
/// Empty if `ext` is absent.
static json::Object getExt(mlir::StringAttr ext) {
  if (!ext)
    return {};
  auto value = json::parse(ext.getValue());
  if (!value) {
    llvm::consumeError(value.takeError());
    return {};
  }
  return std::move(*value->getAsObject());
}

/// Check that `ext` holds the JSON that `getExt` expects.
static mlir::LogicalResult checkExt(Operation *op, mlir::StringAttr ext) {
  if (!ext)
    return mlir::success();
  auto value = json::parse(ext.getValue());
  if (!value) {
    auto diag = op->emitError("ext is not valid JSON: ");
    diag << llvm::toString(value.takeError());
    return mlir::failure();
  }
  auto *object = value->getAsObject();
  if (!object)
    return op->emitError("ext must be a JSON object");
  for (auto &entry : *object)
    if (!StringRef(entry.first).starts_with("x-"))
      return op->emitError("ext key '")
             << StringRef(entry.first) << "' does not start with 'x-'";
  return mlir::success();
}

//===----------------------------------------------------------------------===//
// Types
//===----------------------------------------------------------------------===//

namespace {
/// The `types` table. Equal types share one entry, and a type comes after the
/// types it is built from. A name is part of the type, but only a label: two
/// types with one name and different shapes are two entries.
struct TypeTable final {
  unsigned add(json::Object type);
  std::optional<unsigned> get(mlir::Type type);
  std::optional<unsigned> get(Value value);

  std::vector<json::Value> types;
  llvm::StringMap<unsigned> indices;
  /// The type of each debug value. It goes into the table only when something
  /// refers to it, so a type that only gets a name does not stay there.
  llvm::DenseMap<Value, std::optional<json::Object>> valueTypes;

private:
  std::optional<json::Object> describe(mlir::Type type);
  std::optional<json::Object> compute(Value value);
};
} // namespace

unsigned TypeTable::add(json::Object type) {
  json::Value value(std::move(type));
  std::string key;
  llvm::raw_string_ostream(key) << value;

  auto [it, inserted] = indices.try_emplace(key, types.size());
  if (inserted)
    types.push_back(std::move(value));
  return it->second;
}

std::optional<unsigned> TypeTable::get(mlir::Type type) {
  if (auto object = describe(type))
    return add(std::move(*object));
  return std::nullopt;
}

std::optional<json::Object> TypeTable::describe(mlir::Type type) {
  using Result = std::optional<json::Object>;
  return llvm::TypeSwitch<mlir::Type, Result>(hw::getCanonicalType(type))
      .Case(
          [&](hw::InOutType inout) { return describe(inout.getElementType()); })
      .Case([&](mlir::IntegerType intType) {
        return json::Object{{"kind", "uint"}, {"width", intType.getWidth()}};
      })
      .Case([&](seq::ClockType) { return json::Object{{"kind", "clock"}}; })
      .Case([&](hw::StructType structType) -> Result {
        json::Array fields;
        for (auto field : structType.getElements()) {
          auto type = get(field.type);
          if (!type)
            return std::nullopt;
          fields.push_back(
              json::Object{{"name", field.name.getValue()}, {"type", *type}});
        }
        return json::Object{{"kind", "struct"}, {"fields", std::move(fields)}};
      })
      .Case<hw::ArrayType, hw::UnpackedArrayType>(
          [&](auto arrayType) -> Result {
            auto elem = get(arrayType.getElementType());
            if (!elem)
              return std::nullopt;
            return json::Object{{"kind", "vector"},
                                {"elem", *elem},
                                {"size", arrayType.getNumElements()}};
          })
      .Default([&](mlir::Type type) -> Result {
        // Show any other type as its bits.
        if (auto width = hw::getBitWidth(type); width >= 0)
          return json::Object{{"kind", "uint"}, {"width", width}};
        return std::nullopt;
      });
}

std::optional<unsigned> TypeTable::get(Value value) {
  walkDebugValue(value, [&](Value part) {
    if (valueTypes.contains(part))
      return;
    auto type = compute(part);
    valueTypes[part] = std::move(type);
  });
  if (auto type = valueTypes.lookup(value))
    return add(std::move(*type));
  return std::nullopt;
}

/// The type of `value`, whose operands already have theirs.
std::optional<json::Object> TypeTable::compute(Value value) {
  auto *op = value.getDefiningOp();
  if (auto valueOp = dyn_cast_or_null<debug::ValueOp>(op)) {
    // The source name and language data make a type of their own.
    auto type = valueTypes.lookup(valueOp.getValue());
    if (!type)
      return std::nullopt;
    if (auto name = valueOp.getType())
      (*type)["name"] = *name;
    for (auto &entry : getExt(valueOp.getExtAttr()))
      (*type)[entry.first] = std::move(entry.second);
    return type;
  }

  if (auto structOp = dyn_cast_or_null<debug::StructOp>(op)) {
    json::Array fields;
    auto flips = structOp.getFlips().value_or(llvm::ArrayRef<bool>{});
    for (auto [index, name, field] :
         llvm::enumerate(structOp.getNames(), structOp.getFields())) {
      auto type = valueTypes.lookup(field);
      if (!type)
        return std::nullopt;
      json::Object entry{{"name", cast<mlir::StringAttr>(name).getValue()},
                         {"type", add(std::move(*type))}};
      if (index < flips.size() && flips[index])
        entry["flip"] = true;
      fields.push_back(std::move(entry));
    }
    return json::Object{{"kind", "struct"}, {"fields", std::move(fields)}};
  }

  if (auto arrayOp = dyn_cast_or_null<debug::ArrayOp>(op)) {
    auto elements = arrayOp.getElements();
    if (elements.empty())
      return std::nullopt;
    auto elem = valueTypes.lookup(elements.front());
    if (!elem)
      return std::nullopt;
    return json::Object{{"kind", "vector"},
                        {"elem", add(std::move(*elem))},
                        {"size", elements.size()}};
  }

  if (auto enumOp = dyn_cast_or_null<debug::EnumOp>(op)) {
    auto base = get(enumOp.getValue().getType());
    if (!base)
      return std::nullopt;
    json::Object values;
    for (auto variant : enumOp.getVariantsMap()) {
      auto tag = cast<mlir::IntegerAttr>(variant.getValue()).getValue();
      // A JSON number holds at most 64 bits; a wider tag is a string.
      values[variant.getName().getValue()] =
          tag.getActiveBits() <= 64
              ? json::Value(tag.getZExtValue())
              : json::Value(llvm::toString(tag, 10, false));
    }
    return json::Object{{"kind", "enum"},
                        {"base", *base},
                        {"values", std::move(values)},
                        {"name", enumOp.getEnumTypeName()}};
  }

  return describe(value.getType());
}

//===----------------------------------------------------------------------===//
// Files
//===----------------------------------------------------------------------===//

namespace {
struct FileTable final {
  void emitLoc(json::OStream &out, mlir::Location loc, bool emitted);
  void emitLoc(json::OStream &out, mlir::FileLineColLoc fileLoc, bool emitted);

  /// Path to whether it is a file of the emitted netlist, in the order the
  /// emitter first meets it; the position is the file number in `loc`.
  llvm::MapVector<StringRef, bool> paths;
  /// The path of an emitted location with no file name.
  StringRef netlistFile;
};
} // namespace

/// Emit `[file, line, column]` of the best source or emitted location in `loc`.
void FileTable::emitLoc(json::OStream &out, mlir::Location loc, bool emitted) {
  auto fileLoc = findBestLocation(loc, emitted, /*fileMustExist=*/false);
  if (fileLoc)
    emitLoc(out, fileLoc, emitted);
}

void FileTable::emitLoc(json::OStream &out, mlir::FileLineColLoc fileLoc,
                        bool emitted) {
  // Single-file ExportVerilog leaves the file name of its locations empty.
  StringRef path = fileLoc.getFilename().getValue();
  if (emitted && path.empty())
    path = netlistFile;
  auto it = paths.insert({path, emitted}).first;
  out.attributeArray("loc", [&] {
    out.value(it - paths.begin());
    out.value(fileLoc.getLine());
    if (auto column = fileLoc.getColumn())
      out.value(column);
  });
}

//===----------------------------------------------------------------------===//
// Scopes
//===----------------------------------------------------------------------===//

namespace {
/// A step down the instance hierarchy into a transparent module.
struct Hop {
  Operation *module;
  const Hop *parent;
  /// The Verilog name of the instance; empty at the root.
  StringRef instName;
  hw::InstanceOp instance;
  /// The instance names from the root, each followed by `.`.
  std::string prefix;
};

struct Scope;

/// A variable or an instance of a scope.
struct Item {
  /// A `dbg.variable`, `hw.instance` or `dbg.scope`.
  Operation *op;
  const Hop *hop;
  /// The scope that an instance instantiates.
  Scope *child = nullptr;
  hw::InstanceOp target = {};
};

/// An entry of `vars`: an item, or a port of an external module.
struct Var {
  std::string key;
  StringRef name;
  unsigned type;
  mlir::LocationAttr loc;
  std::optional<debug::VariableKind> kind;
  const Item *item = nullptr;
  std::string port = {};
};

/// A module or an inlined instance as written in the source. It becomes an
/// entry of `original` and a binding.
struct Scope {
  /// The generated module that holds it.
  Operation *module;
  /// The inlined instance; null for a module.
  debug::ScopeOp scope;
  debug::ModuleInfoOp info;
  Operation *members = nullptr;
  const Hop *memberHop = nullptr;
  SmallVector<std::pair<Operation *, const Hop *>> externalPorts;
  const Hop *root;
  SmallVector<std::string> inlinePath;
  SmallVector<SmallVector<Operation *>> exclusions;
  bool contextual = false;
  SmallVector<Item> items;
  SmallVector<Var> vars;
  std::string key;
};

/// The debug ops and instances of a module, by the `dbg.scope` they belong
/// to. The module itself stands for no scope.
struct ModuleOps {
  debug::ModuleInfoOp info;
  llvm::DenseMap<Operation *, SmallVector<Operation *>> members;
  llvm::DenseMap<Operation *, debug::ModuleInfoOp> scopeInfos;
};

struct Emitter {
  Emitter(mlir::ModuleOp top, StringRef netlistFile) : top(top), symbols(top) {
    files.netlistFile = netlistFile;
  }

  mlir::LogicalResult collect();
  void buildScopes();
  void absorb(Scope &scope);
  void addVars();
  void addKeys(Scope &scope);
  void emit(json::OStream &out);

  void emitOriginal(json::OStream &out, Scope &scope);
  void emitBinding(json::OStream &out, Scope &scope);
  void emitGenerated(json::OStream &out);
  void emitSignals(json::OStream &out, hw::HWModuleOp module);
  void emitProfiles(json::OStream &out);

  json::Value getValue(Value value, const Hop *hop);
  json::Value getLeafValue(Value value, const Hop *hop);
  std::optional<std::string> getXMRName(Value value, const Hop *hop);
  const Hop *addHop(Operation *module, const Hop *parent, StringRef instName,
                    hw::InstanceOp instance = {});

  mlir::ModuleOp top;
  mlir::SymbolTable symbols;
  hw::InnerSymbolTableCollection innerSymbols;
  llvm::DenseMap<Operation *, ModuleOps> moduleOps;
  llvm::DenseSet<mlir::StringAttr> instantiated;
  llvm::DenseMap<Operation *, SmallVector<Operation *>> descriptionPaths;
  llvm::DenseMap<Operation *, Scope *> moduleScopes;
  bool usesExpressions = false;
  // Deques: items point at hops and scopes.
  std::deque<Hop> hops;
  std::deque<Scope> scopes;
  /// Each key of `original` to what was emitted for it.
  llvm::StringMap<std::string> originals;
  llvm::DenseMap<const Item *, json::Value> bindingValues;
  TypeTable types;
  FileTable files;
};
} // namespace

/// Sort the debug ops and instances of each module by scope, and check that a
/// hardware module has at most one `dbg.module` binding. Check the
/// `ext` of `dbg.module` and `dbg.value`.
mlir::LogicalResult Emitter::collect() {
  bool failed = false;
  top.walk([&](debug::VariableOp description) {
    auto value = description.getValue().getDefiningOp<debug::ValueOp>();
    if (!value || !value.getPathAttr())
      return;
    SmallVector<Attribute> refs;
    auto ref = value.getPathAttr();
    auto path = symbols.lookup<hw::HierPathOp>(ref.getValue());
    if (!path) {
      description.emitError("instance path not found");
      failed = true;
      return;
    }
    llvm::append_range(refs, path.getNamepath());
    auto owner = description->getParentOfType<hw::HWModuleOp>();
    if (!owner) {
      description.emitError("instance description must belong to an hw.module");
      failed = true;
      return;
    }
    Operation *expected = owner;
    SmallVector<Operation *> instances;
    bool invalid = false;
    for (auto attr : refs) {
      if (auto moduleRef = dyn_cast<FlatSymbolRefAttr>(attr)) {
        if (symbols.lookup(moduleRef.getValue()) != expected)
          invalid = true;
        continue;
      }
      auto ref = dyn_cast<hw::InnerRefAttr>(attr);
      auto *module = ref ? symbols.lookup(ref.getModule()) : nullptr;
      if (!module || module != expected) {
        invalid = true;
        break;
      }
      auto target =
          innerSymbols.getInnerSymbolTable(module).lookup(ref.getName());
      auto *targetOp = target && !target.isPort() && !target.isField()
                           ? target.getOp()
                           : nullptr;
      if (auto instance = dyn_cast_or_null<hw::InstanceOp>(targetOp)) {
        instances.push_back(instance);
        expected = symbols.lookup(instance.getModuleName());
      } else if (isa_and_nonnull<debug::ScopeOp>(targetOp) &&
                 attr == refs.back()) {
        instances.push_back(targetOp);
      } else {
        invalid = true;
        break;
      }
    }
    if (instances.empty() || invalid) {
      description.emitError("invalid instance description path");
      failed = true;
      return;
    }
    descriptionPaths[description] = std::move(instances);
  });
  for (auto info : top.getOps<debug::ModuleInfoOp>()) {
    if (mlir::failed(checkExt(info, info.getExtAttr())))
      failed = true;
    if (auto ref = info.getImplAttr()) {
      auto *module = symbols.lookup(ref.getValue());
      if (!module) {
        info.emitError("described module not found");
        failed = true;
        continue;
      }
      auto &slot = moduleOps[module].info;
      if (slot) {
        info.emitError("more than one dbg.module for this module");
        failed = true;
      }
      slot = info;
    }
  }
  for (auto module : top.getOps<hw::HWModuleOp>()) {
    auto &ops = moduleOps[module];
    auto getKey = [&](Value scope) -> Operation * {
      return scope ? scope.getDefiningOp() : module;
    };
    module.walk([&](Operation *op) {
      if (auto value = dyn_cast<debug::ValueOp>(op)) {
        if (mlir::failed(checkExt(value, value.getExtAttr())))
          failed = true;
      } else if (auto var = dyn_cast<debug::VariableOp>(op)) {
        ops.members[getKey(var.getScope())].push_back(op);
      } else if (auto scope = dyn_cast<debug::ScopeOp>(op)) {
        if (auto definition = scope.getDefAttr())
          ops.scopeInfos[scope] =
              SymbolTable::lookupNearestSymbolFrom<debug::ModuleInfoOp>(
                  scope, definition);
        ops.members[getKey(scope.getScope())].push_back(op);
      } else if (auto inst = dyn_cast<hw::InstanceOp>(op)) {
        ops.members[module].push_back(op);
        instantiated.insert(inst.getModuleNameAttr().getAttr());
      }
    });
  }
  llvm::DenseSet<Operation *> active, visited;
  std::function<bool(debug::ScopeOp)> visit = [&](debug::ScopeOp scope) {
    if (active.contains(scope)) {
      scope.emitError("cyclic debug scope description");
      return false;
    }
    if (!visited.insert(scope).second)
      return true;
    active.insert(scope);
    auto owner = scope->getParentOfType<hw::HWModuleOp>();
    for (auto *member : moduleOps[owner].members.lookup(scope)) {
      if (auto nested = dyn_cast<debug::ScopeOp>(member))
        if (!visit(nested))
          return false;
      auto path = descriptionPaths.find(member);
      if (path != descriptionPaths.end())
        if (auto target = dyn_cast<debug::ScopeOp>(path->second.back()))
          if (!visit(target))
            return false;
    }
    active.erase(scope);
    return true;
  };
  top.walk([&](debug::ScopeOp scope) {
    if (!failed && !visit(scope))
      failed = true;
  });
  return mlir::failure(failed);
}

const Hop *Emitter::addHop(Operation *module, const Hop *parent,
                           StringRef instName, hw::InstanceOp instance) {
  std::string prefix;
  if (parent)
    prefix = (parent->prefix + instName + ".").str();
  return &hops.emplace_back(
      Hop{module, parent, instName, instance, std::move(prefix)});
}

/// Make a scope of each source module, then fill each scope, which may find
/// inlined scopes in it.
void Emitter::buildScopes() {
  for (auto &op : *top.getBody()) {
    if (!isa<hw::HWModuleOp, hw::HWModuleExternOp, sv::SVVerbatimModuleOp>(op))
      continue;
    auto module = cast<hw::HWModuleLike>(op);
    auto it = moduleOps.find(&op);
    auto info = it != moduleOps.end() ? it->second.info : nullptr;
    if (isa<hw::HWModuleOp>(op) && !info &&
        instantiated.contains(module.getModuleNameAttr()))
      continue;
    auto &scope = scopes.emplace_back();
    scope.module = &op;
    scope.info = info;
    scope.root = addHop(&op, nullptr, "");
    scope.key = module.getModuleName();
    // A module keeps its name in `original`; inlined scopes avoid it.
    originals.try_emplace(scope.key);
    moduleScopes[&op] = &scope;
  }

  // `absorb` appends the inlined scopes it finds.
  for (size_t i = 0; i < scopes.size(); ++i)
    absorb(scopes[i]);
}

/// Collect the variables and instances of `scope`, including those of the
/// transparent modules and scopes inside it.
void Emitter::absorb(Scope &scope) {
  if (!isa<hw::HWModuleOp>(scope.root->module))
    return;

  for (auto &entry : descriptionPaths)
    if (entry.first->getParentOfType<hw::HWModuleOp>() == scope.root->module)
      scope.exclusions.push_back(entry.second);
  SmallVector<std::pair<Operation *, const Hop *>> worklist;
  worklist.push_back({scope.members ? scope.members
                                    : (scope.scope ? scope.scope.getOperation()
                                                   : scope.root->module),
                      scope.memberHop ? scope.memberHop : scope.root});
  llvm::DenseMap<Operation *, llvm::StringSet<>> visitedMembers;
  for (size_t i = 0; i < worklist.size(); ++i) {
    auto [key, hop] = worklist[i];
    if (!visitedMembers[key].insert(hop->prefix).second)
      continue;
    if (hop != scope.root) {
      SmallVector<Operation *> prefix;
      for (auto *step = hop; step != scope.root; step = step->parent)
        prefix.push_back(step->instance);
      std::reverse(prefix.begin(), prefix.end());
      for (auto &entry : descriptionPaths)
        if (entry.first->getParentOfType<hw::HWModuleOp>() == hop->module) {
          auto path = prefix;
          llvm::append_range(path, entry.second);
          scope.exclusions.push_back(std::move(path));
        }
    }
    auto &ops = moduleOps[hop->module];
    auto members = ops.members.find(key);
    if (members == ops.members.end())
      continue;
    auto orderedMembers = members->second;
    llvm::stable_sort(orderedMembers, [](Operation *a, Operation *b) {
      return isa<debug::VariableOp>(a) && !isa<debug::VariableOp>(b);
    });
    for (auto *op : orderedMembers) {
      if (auto variable = dyn_cast<debug::VariableOp>(op)) {
        auto path = descriptionPaths.find(variable);
        if (path == descriptionPaths.end()) {
          scope.items.push_back({op, hop});
          continue;
        }
        auto *targetHop = hop;
        for (auto *step : llvm::drop_end(path->second)) {
          auto instance = cast<hw::InstanceOp>(step);
          auto *callee = symbols.lookup(instance.getModuleName());
          targetHop =
              addHop(callee, targetHop, getInstanceName(instance), instance);
        }
        auto *target = path->second.back();
        auto instance = dyn_cast<hw::InstanceOp>(target);
        auto *callee = instance ? symbols.lookup(instance.getModuleName())
                                : targetHop->module;
        auto *memberHop = instance ? addHop(callee, targetHop,
                                            getInstanceName(instance), instance)
                                   : targetHop;
        auto *members = instance ? callee : target;
        auto &child = scopes.emplace_back();
        child.module = callee;
        child.members = members;
        child.info = instance ? moduleOps[callee].info
                              : moduleOps[callee].scopeInfos.lookup(target);
        auto value = variable.getValue().getDefiningOp<debug::ValueOp>();
        if (auto definition = value.getDefAttr())
          child.info =
              SymbolTable::lookupNearestSymbolFrom<debug::ModuleInfoOp>(
                  value, definition);
        child.root = addHop(callee, nullptr, "");
        child.key = instance     ? hw::getVerilogModuleName(callee).str()
                    : child.info ? child.info.getType().str()
                    : value.getTypeAttr() ? value.getTypeAttr().getValue().str()
                                          : variable.getName().str();
        if (!instance) {
          child.module = scope.module;
          child.root = scope.root;
          child.memberHop = memberHop;
          child.contextual = true;
          child.inlinePath = scope.inlinePath;
          child.inlinePath.push_back(variable.getName().str());
          if (isa<hw::HWModuleExternOp, sv::SVVerbatimModuleOp>(callee))
            child.externalPorts.push_back({callee, child.memberHop});
          scope.items.push_back({op, hop, &child});
        } else {
          scope.items.push_back({op, targetHop, &child, instance});
        }
        continue;
      }

      SmallVector<Operation *> route;
      SmallVector<const Hop *> ancestry;
      for (auto *step = hop; step != scope.root; step = step->parent)
        ancestry.push_back(step);
      for (auto *step : llvm::reverse(ancestry))
        route.push_back(step->instance);
      route.push_back(op);
      SmallVector<SmallVector<Operation *>> remaining;
      bool described = false;
      for (auto &path : scope.exclusions) {
        if (path.size() < route.size() ||
            !std::equal(route.begin(), route.end(), path.begin()))
          continue;
        if (path.size() == route.size())
          described = true;
        else
          remaining.emplace_back(path.begin() + route.size(), path.end());
      }
      if (described)
        continue;

      if (auto dbgScope = dyn_cast<debug::ScopeOp>(op)) {
        auto info = ops.scopeInfos.lookup(dbgScope);
        if (!info) {
          worklist.push_back({dbgScope, hop});
          continue;
        }
        auto &child = scopes.emplace_back();
        child.module = scope.module;
        child.scope = dbgScope;
        child.info = info;
        child.root = scope.root;
        child.memberHop = hop;
        child.key = info.getType();
        // Inlined into a transparent module: the path goes through the
        // instances of that module.
        SmallVector<StringRef> names;
        for (auto *step = hop; step != scope.root; step = step->parent)
          names.push_back(step->instName);
        child.inlinePath = scope.inlinePath;
        for (auto name : llvm::reverse(names))
          child.inlinePath.push_back(name.str());
        child.inlinePath.push_back(dbgScope.getName().str());
        scope.items.push_back({op, hop, &child});
        continue;
      }

      auto inst = cast<hw::InstanceOp>(op);
      auto *callee = symbols.lookup(inst.getModuleNameAttr().getAttr());
      if (auto *child = moduleScopes.lookup(callee)) {
        if (!remaining.empty()) {
          auto &context = scopes.emplace_back();
          context.module = child->module;
          context.info = child->info;
          context.root = addHop(callee, nullptr, "");
          context.key = child->key;
          context.exclusions = std::move(remaining);
          context.contextual = true;
          child = &context;
        }
        scope.items.push_back({op, hop, child});
        continue;
      }
      if (!isa_and_nonnull<hw::HWModuleOp>(callee)) {
        inst.emitWarning("UHDI leaves out this instance: its module is not "
                         "an hw.module or hw.module.extern");
        continue;
      }
      worklist.push_back(
          {callee, addHop(callee, hop, getInstanceName(inst), inst)});
    }
  }
}

/// Give each variable its type. Variables of a type that cannot be shown are
/// left out with a warning. Instances get theirs in `addKeys`.
void Emitter::addVars() {
  for (auto &scope : scopes) {
    auto externalPorts = scope.externalPorts;
    if (isa<hw::HWModuleExternOp, sv::SVVerbatimModuleOp>(scope.module))
      externalPorts.push_back({scope.module, scope.root});
    for (auto [module, hop] : externalPorts) {
      for (auto port : cast<hw::HWModuleLike>(module).getPortList()) {
        auto type = types.get(port.type);
        if (!type) {
          module->emitWarning("UHDI leaves out port '")
              << port.getName() << "': its type cannot be described";
          continue;
        }
        auto kind = port.isInput()    ? debug::VariableKind::Input
                    : port.isOutput() ? debug::VariableKind::Output
                                      : debug::VariableKind::InOut;
        scope.vars.push_back({"", port.getName(), *type, port.loc, kind,
                              nullptr,
                              hop->prefix + port.getVerilogName().str()});
      }
    }

    for (auto &item : scope.items) {
      auto var = dyn_cast<debug::VariableOp>(item.op);
      if (!var || item.child)
        continue;
      auto type = types.get(var.getValue());
      if (!type) {
        var.emitWarning("UHDI leaves out this variable: its type cannot be "
                        "described");
        continue;
      }
      scope.vars.push_back(
          {"", var.getName(), *type, var.getLoc(), var.getKind(), &item});
      bindingValues.try_emplace(&item, getValue(var.getValue(), item.hop));
    }
  }
}

/// The source class recorded by `dbg.module`, if present.
static StringRef getClassName(Scope &scope) {
  return scope.info ? scope.info.getType() : StringRef();
}

/// Add the instances to the vars of `scope`, key each entry, and pick the key
/// of `scope` in `original`. The scopes it instantiates have their keys.
void Emitter::addKeys(Scope &scope) {
  for (auto &item : scope.items) {
    auto *child = item.child;
    if (!child)
      continue;
    json::Object type{{"kind", "module"}, {"module", child->key}};
    if (auto name = getClassName(*child); !name.empty())
      type["name"] = name;
    if (child->info)
      for (auto &entry : getExt(child->info.getExtAttr()))
        type[entry.first] = std::move(entry.second);
    if (auto variable = dyn_cast<debug::VariableOp>(item.op)) {
      auto value = variable.getValue().getDefiningOp<debug::ValueOp>();
      if (auto name = value.getType())
        type["name"] = *name;
      for (auto &entry : getExt(value.getExtAttr()))
        type[entry.first] = std::move(entry.second);
    }
    StringRef name = isa<debug::VariableOp>(item.op)
                         ? cast<debug::VariableOp>(item.op).getName()
                     : isa<debug::ScopeOp>(item.op)
                         ? child->scope.getName()
                         : cast<hw::InstanceOp>(item.op).getInstanceName();
    scope.vars.push_back({"", name, types.add(std::move(type)),
                          item.op->getLoc(), std::nullopt, &item});
  }

  // A key is unique in its module and has no `.`, `[` or `]`, which the path
  // grammar uses.
  llvm::StringSet<> used;
  for (auto &var : scope.vars) {
    std::string key = var.name.str();
    llvm::replace(key, '.', '_');
    llvm::replace(key, '[', '_');
    llvm::replace(key, ']', '_');
    var.key = key;
    for (unsigned n = 1; !used.insert(var.key).second; ++n)
      var.key = (key + "_" + llvm::Twine(n)).str();
  }

  // A module keeps its name. Inlined copies of a module share an entry when
  // they are equal; a different one gets a new key.
  if (!scope.scope && !scope.contextual)
    return;
  std::string text;
  {
    llvm::raw_string_ostream os(text);
    json::OStream out(os);
    emitOriginal(out, scope);
  }
  std::string base = scope.key;
  for (unsigned n = 1;; ++n) {
    auto [it, inserted] = originals.try_emplace(scope.key, text);
    if (inserted || it->second == text)
      return;
    scope.key = (base + "_" + llvm::Twine(n)).str();
  }
}

//===----------------------------------------------------------------------===//
// Values
//===----------------------------------------------------------------------===//

/// The value of a variable: a signal, a literal, or an aggregate of those
/// shaped like the variable's type. Signals are named from the generated
/// module of the scope, through `hop`.
json::Value Emitter::getValue(Value root, const Hop *hop) {
  llvm::DenseMap<Value, json::Value> values;
  walkDebugValue(root, [&](Value value) {
    auto *op = value.getDefiningOp();
    json::Value result = nullptr;
    if (isa_and_nonnull<debug::ValueOp, debug::EnumOp>(op)) {
      if (op->getNumOperands())
        result = values.at(op->getOperand(0));
    } else if (auto structOp = dyn_cast_or_null<debug::StructOp>(op)) {
      json::Object fields;
      for (auto [name, field] :
           llvm::zip(structOp.getNames().getAsValueRange<mlir::StringAttr>(),
                     structOp.getFields()))
        fields[name] = values.at(field);
      result = std::move(fields);
    } else if (auto arrayOp = dyn_cast_or_null<debug::ArrayOp>(op)) {
      json::Array elements;
      for (auto element : arrayOp.getElements())
        elements.push_back(values.at(element));
      result = std::move(elements);
    } else {
      result = getLeafValue(value, hop);
    }
    values.try_emplace(value, std::move(result));
  });
  return std::move(values.find(root)->second);
}

json::Value Emitter::getLeafValue(Value value, const Hop *hop) {
  if (auto constant = value.getDefiningOp<hw::ConstantOp>()) {
    // A zero-width value has no bits to give.
    if (constant.getValue().getBitWidth() == 0)
      return json::Object{{"$zero_width", true}};
    return json::Object{{"$const", getBits(constant.getValue())}};
  }

  if (auto name = getSignalName(value))
    return hop->prefix + name->str();
  if (auto name = getXMRName(value, hop))
    return *name;

  // A field or a constant index of a packed aggregate, or a bit range, is a
  // slice of the aggregate's signal.
  int64_t lowBit = 0;
  auto width = hw::getBitWidth(value.getType());
  for (auto base = value; width > 0;) {
    auto *op = base.getDefiningOp();
    auto bit = op ? getLowBit(op) : std::nullopt;
    if (!bit)
      break;
    lowBit += *bit;
    base = op->getOperand(0);
    if (auto name = getSignalName(base))
      return json::Object{{"$slice", hop->prefix + name->str()},
                          {"hi", lowBit + width - 1},
                          {"lo", lowBit}};
  }

  if (auto concat = value.getDefiningOp<comb::ConcatOp>()) {
    json::Array args;
    for (auto operand : concat.getOperands())
      args.push_back(getLeafValue(operand, hop));
    usesExpressions = true;
    return json::Object{{"$op", "{}"}, {"args", std::move(args)}};
  }
  if (auto replicate = value.getDefiningOp<comb::ReplicateOp>()) {
    usesExpressions = true;
    return json::Object{
        {"$op", "R{}"},
        {"args", json::Array{replicate.getMultiple(),
                             getLeafValue(replicate.getInput(), hop)}}};
  }
  if (auto extract = value.getDefiningOp<comb::ExtractOp>()) {
    usesExpressions = true;
    return json::Object{
        {"$op", "[]"},
        {"args",
         json::Array{getLeafValue(extract.getInput(), hop),
                     extract.getLowBit() + width - 1, extract.getLowBit()}}};
  }

  auto *op = value.getDefiningOp();
  if (!op)
    return getOptimizedOut();
  bool signedOperands = isa<comb::DivSOp, comb::ModSOp, comb::ShrSOp>(op);
  auto opcode = llvm::TypeSwitch<Operation *, StringRef>(op)
                    .Case<comb::AndOp>([](auto) { return "&"; })
                    .Case<comb::OrOp>([](auto) { return "|"; })
                    .Case<comb::XorOp, comb::ParityOp>([](auto) { return "^"; })
                    .Case<comb::AddOp>([](auto) { return "+"; })
                    .Case<comb::SubOp>([](auto) { return "-"; })
                    .Case<comb::MulOp>([](auto) { return "*"; })
                    .Case<comb::DivUOp, comb::DivSOp>([](auto) { return "/"; })
                    .Case<comb::ModUOp, comb::ModSOp>([](auto) { return "%"; })
                    .Case<comb::ShlOp>([](auto) { return "<<"; })
                    .Case<comb::ShrUOp>([](auto) { return ">>"; })
                    .Case<comb::ShrSOp>([](auto) { return ">>>"; })
                    .Case<comb::MuxOp>([](auto) { return "?:"; })
                    .Default(StringRef());
  if (auto cmp = dyn_cast<comb::ICmpOp>(op)) {
    switch (cmp.getPredicate()) {
    case comb::ICmpPredicate::eq:
      opcode = "==";
      break;
    case comb::ICmpPredicate::ne:
      opcode = "!=";
      break;
    case comb::ICmpPredicate::ceq:
      opcode = "===";
      break;
    case comb::ICmpPredicate::cne:
      opcode = "!==";
      break;
    case comb::ICmpPredicate::weq:
      opcode = "==?";
      break;
    case comb::ICmpPredicate::wne:
      opcode = "!=?";
      break;
    case comb::ICmpPredicate::slt:
      signedOperands = true;
      [[fallthrough]];
    case comb::ICmpPredicate::ult:
      opcode = "<";
      break;
    case comb::ICmpPredicate::sle:
      signedOperands = true;
      [[fallthrough]];
    case comb::ICmpPredicate::ule:
      opcode = "<=";
      break;
    case comb::ICmpPredicate::sgt:
      signedOperands = true;
      [[fallthrough]];
    case comb::ICmpPredicate::ugt:
      opcode = ">";
      break;
    case comb::ICmpPredicate::sge:
      signedOperands = true;
      [[fallthrough]];
    case comb::ICmpPredicate::uge:
      opcode = ">=";
      break;
    }
  }
  if (!opcode.empty()) {
    json::Array args;
    for (auto [index, operand] : llvm::enumerate(op->getOperands())) {
      auto arg = getLeafValue(operand, hop);
      if (signedOperands && (!isa<comb::ShrSOp>(op) || index == 0))
        arg = json::Object{{"$op", "$signed"},
                           {"args", json::Array{std::move(arg)}}};
      args.push_back(std::move(arg));
    }
    usesExpressions = true;
    return json::Object{{"$op", opcode}, {"args", std::move(args)}};
  }
  return getOptimizedOut();
}

/// The signal that an XMR read in a transparent module names, as a path from
/// the generated module of the scope. None if the path starts outside it.
std::optional<std::string> Emitter::getXMRName(Value value, const Hop *hop) {
  auto read = value.getDefiningOp<sv::ReadInOutOp>();
  if (!read)
    return std::nullopt;
  auto xmr = read.getInput().getDefiningOp<sv::XMRRefOp>();
  if (!xmr || !xmr.getVerbatimSuffix().empty())
    return std::nullopt;
  auto path = symbols.lookup<hw::HierPathOp>(xmr.getRefAttr().getAttr());
  if (!path)
    return std::nullopt;

  auto namepath = path.getNamepath().getValue();
  auto first = dyn_cast<hw::InnerRefAttr>(namepath.front());
  if (!first)
    return std::nullopt;
  while (hop &&
         mlir::SymbolTable::getSymbolName(hop->module) != first.getModule())
    hop = hop->parent;
  if (!hop)
    return std::nullopt;

  std::string name = hop->prefix;
  for (auto [index, attr] : llvm::enumerate(namepath)) {
    auto ref = dyn_cast<hw::InnerRefAttr>(attr);
    if (!ref)
      return std::nullopt;
    auto *module = symbols.lookup(ref.getModule());
    if (!module)
      return std::nullopt;
    auto target =
        innerSymbols.getInnerSymbolTable(module).lookup(ref.getName());
    if (!target || target.isField())
      return std::nullopt;

    // The path goes through instances to a port or a declaration.
    if (index + 1 < namepath.size()) {
      auto inst = dyn_cast<hw::InstanceOp>(target.getOp());
      if (target.isPort() || !inst)
        return std::nullopt;
      name += (getInstanceName(inst) + ".").str();
      continue;
    }
    if (target.isPort()) {
      name += cast<hw::HWModuleLike>(module)
                  .getPort(target.getPort())
                  .getVerilogName();
      return name;
    }
    auto declared = getDeclaredName(target.getOp());
    if (!declared)
      return std::nullopt;
    return name + declared->str();
  }
  return std::nullopt;
}

//===----------------------------------------------------------------------===//
// Document
//===----------------------------------------------------------------------===//

void Emitter::emitOriginal(json::OStream &out, Scope &scope) {
  out.object([&] {
    auto loc = scope.info ? scope.info.getLoc() : scope.module->getLoc();
    files.emitLoc(out, loc, /*emitted=*/false);

    // The top module has no instance whose type names its class.
    if (auto name = getClassName(scope); !name.empty())
      out.attribute("name", name);
    if (scope.info)
      for (auto &entry : getExt(scope.info.getExtAttr()))
        out.attribute(entry.first, std::move(entry.second));

    out.attributeObject("vars", [&] {
      for (auto &var : scope.vars)
        out.attributeObject(var.key, [&] {
          if (var.key != var.name)
            out.attribute("name", var.name);
          out.attribute("type", var.type);
          if (var.loc)
            files.emitLoc(out, var.loc, /*emitted=*/false);
          if (!var.kind)
            return;
          switch (*var.kind) {
          case debug::VariableKind::Input:
            return out.attribute("dir", "in");
          case debug::VariableKind::Output:
            return out.attribute("dir", "out");
          case debug::VariableKind::InOut:
            return out.attribute("dir", "inout");
          case debug::VariableKind::Reg:
            return out.attribute("storage", "reg");
          case debug::VariableKind::Node:
            return out.attribute("node", true);
          case debug::VariableKind::Wire:
          case debug::VariableKind::Instance:
            return;
          }
        });
    });
  });
}

void Emitter::emitBinding(json::OStream &out, Scope &scope) {
  out.object([&] {
    out.attribute("original", scope.key);
    out.attribute("generated", hw::getVerilogModuleName(scope.module));
    if (!scope.inlinePath.empty())
      out.attributeArray("inline_path", [&] {
        for (auto &name : scope.inlinePath)
          out.value(name);
      });

    out.attributeObject("vars", [&] {
      for (auto &var : scope.vars) {
        auto *item = var.item;
        if (!item) {
          out.attribute(var.key, var.port);
          continue;
        }
        if (isa<debug::VariableOp>(item->op) && !item->child) {
          out.attribute(var.key, bindingValues.find(item)->second);
          continue;
        }
        out.attributeObject(var.key, [&] {
          auto *child = item->child;
          if (auto inst = item->target ? item->target
                                       : dyn_cast<hw::InstanceOp>(item->op)) {
            out.attribute("$inst",
                          (item->hop->prefix + getInstanceName(inst)).str());
            out.attribute("module", hw::getVerilogModuleName(child->module));
            return;
          }
          out.attributeArray("$inline", [&] {
            for (auto &name : child->inlinePath)
              out.value(name);
          });
        });
      }
    });
  });
}

/// Emit where each signal of `module` is declared in the netlist.
/// Of signals with the same name, only the first is kept.
void Emitter::emitSignals(json::OStream &out, hw::HWModuleOp module) {
  SmallVector<std::pair<StringRef, mlir::FileLineColLoc>> signals;
  llvm::StringSet<> seen;
  module.walk([&](Operation *op) {
    auto name = getDeclaredName(op);
    if (!name)
      return;
    auto fileLoc = findBestLocation(op->getLoc(), /*emitted=*/true,
                                    /*fileMustExist=*/false);
    if (fileLoc && seen.insert(*name).second)
      signals.push_back({*name, fileLoc});
  });
  if (signals.empty())
    return;

  out.attributeObject("signals", [&] {
    for (auto &signal : signals)
      out.attributeObject(signal.first, [&] {
        files.emitLoc(out, signal.second, /*emitted=*/true);
      });
  });
}

void Emitter::emitGenerated(json::OStream &out) {
  // External modules may share one Verilog module.
  llvm::StringSet<> seen;
  out.attributeObject("generated", [&] {
    for (auto &op : *top.getBody()) {
      if (!isa<hw::HWModuleOp, hw::HWModuleExternOp, sv::SVVerbatimModuleOp>(
              op))
        continue;
      auto name = hw::getVerilogModuleName(&op);
      if (!seen.insert(name).second)
        continue;

      out.attributeObject(name, [&] {
        files.emitLoc(out, op.getLoc(), /*emitted=*/true);
        if (isa<hw::HWModuleExternOp, sv::SVVerbatimModuleOp>(op))
          out.attribute("kind", "extern");
        if (auto module = dyn_cast<hw::HWModuleOp>(op))
          emitSignals(out, module);
      });
    }
  });
}

/// Every `x-` key of the document names a profile it uses.
void Emitter::emitProfiles(json::OStream &out) {
  // std::set: the profiles are emitted sorted.
  std::set<std::string> profiles;
  if (usesExpressions)
    profiles.insert("expr");
  for (auto &type : types.types)
    for (auto &entry : *type.getAsObject())
      if (StringRef(entry.first).starts_with("x-"))
        profiles.insert(entry.first.str());
  for (auto &scope : scopes)
    if (scope.info)
      for (auto &entry : getExt(scope.info.getExtAttr()))
        profiles.insert(entry.first.str());

  out.attributeArray("profiles", [&] {
    for (auto &profile : profiles)
      out.value(profile);
  });
}

void Emitter::emit(json::OStream &out) {
  out.object([&] {
    out.attribute("uhdi", "0.1");
    out.attribute("producer", getCirctVersion());
    emitProfiles(out);
    out.attributeArray("types", [&] {
      for (auto &type : types.types)
        out.value(type);
    });

    // An entry shared by several inlined copies is emitted once.
    llvm::StringSet<> emitted;
    out.attributeObject("original", [&] {
      for (auto &scope : scopes) {
        if (!emitted.insert(scope.key).second)
          continue;
        out.attributeBegin(scope.key);
        emitOriginal(out, scope);
        out.attributeEnd();
      }
    });
    emitGenerated(out);
    out.attributeArray("bindings", [&] {
      llvm::StringSet<> emittedBindings;
      for (auto &scope : scopes) {
        std::string binding;
        llvm::raw_string_ostream stream(binding);
        json::OStream candidate(stream);
        emitBinding(candidate, scope);
        if (emittedBindings.insert(binding).second)
          emitBinding(out, scope);
      }
    });
    // Files come last: the sections above number them as they meet them.
    out.attributeArray("files", [&] {
      for (auto &file : files.paths)
        out.object([&] {
          out.attribute("path", file.first);
          if (file.second)
            out.attribute("generated", true);
        });
    });
  });
}

mlir::LogicalResult circt::debug::emitUHDI(mlir::Operation *op,
                                           llvm::raw_ostream &os,
                                           unsigned indent,
                                           StringRef netlistFile) {
  auto top = dyn_cast<mlir::ModuleOp>(op);
  if (!top)
    return op->emitError("UHDI emission expects a builtin.module");

  Emitter emitter(top, netlistFile);
  if (mlir::failed(emitter.collect()))
    return mlir::failure();
  emitter.buildScopes();
  emitter.addVars();
  // Child keys must be final before their parent creates instance types.
  llvm::DenseSet<Scope *> visited;
  std::function<void(Scope &)> assignKeys = [&](Scope &scope) {
    if (!visited.insert(&scope).second)
      return;
    for (auto &item : scope.items)
      if (item.child)
        assignKeys(*item.child);
    emitter.addKeys(scope);
  };
  for (auto &scope : emitter.scopes)
    assignKeys(scope);

  json::OStream out(os, indent);
  emitter.emit(out);
  os << "\n";
  return mlir::success();
}
