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
// A module with an unscoped `dbg.moduleinfo` is a source module, and so is a
// module that nothing instantiates. Any other module was made by the compiler
// and is transparent: its variables and instances move into the scope that
// instantiates it, and their signals are named by a hierarchical path from
// there. A `dbg.scope` with a `dbg.moduleinfo` is an inlined instance. An
// `hw.instance` with a `scope` operand belongs to that scope.
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

/// The language data of a debug op: its `params`, a one-element array that
/// holds the frontend's JSON. The JSON is an object that names the language of
/// each entry by an `x-` key. Empty if `params` is absent.
static json::Object getExt(mlir::ArrayAttr params) {
  if (!params)
    return {};
  auto value = json::parse(cast<mlir::StringAttr>(params[0]).getValue());
  if (!value) {
    llvm::consumeError(value.takeError());
    return {};
  }
  return std::move(*value->getAsObject());
}

/// Check that `params` holds the JSON that `getExt` expects.
static mlir::LogicalResult checkExt(Operation *op, mlir::ArrayAttr params) {
  if (!params)
    return mlir::success();
  if (params.size() != 1 || !isa<mlir::StringAttr>(params[0]))
    return op->emitError("params must hold one JSON string");
  auto value = json::parse(cast<mlir::StringAttr>(params[0]).getValue());
  if (!value) {
    auto diag = op->emitError("params is not valid JSON: ");
    diag << llvm::toString(value.takeError());
    return mlir::failure();
  }
  auto *object = value->getAsObject();
  if (!object)
    return op->emitError("params must be a JSON object");
  for (auto &entry : *object)
    if (!StringRef(entry.first).starts_with("x-"))
      return op->emitError("params key '")
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
    if (auto name = valueOp.getTypeName())
      (*type)["name"] = *name;
    for (auto &entry : getExt(valueOp.getParamsAttr()))
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
};

/// An entry of `vars`: an item, or a port of an external module.
struct Var {
  std::string key;
  StringRef name;
  unsigned type;
  mlir::LocationAttr loc;
  std::optional<debug::VariableKind> kind;
  const Item *item = nullptr;
  StringRef port = {};
};

/// A module or an inlined instance as written in the source. It becomes an
/// entry of `original` and a binding.
struct Scope {
  /// The generated module that holds it.
  Operation *module;
  /// The inlined instance; null for a module.
  debug::ScopeOp scope;
  debug::ModuleInfoOp info;
  const Hop *root;
  SmallVector<std::string> inlinePath;
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
  const Hop *addHop(Operation *module, const Hop *parent, StringRef instName);

  mlir::ModuleOp top;
  mlir::SymbolTable symbols;
  hw::InnerSymbolTableCollection innerSymbols;
  llvm::DenseMap<Operation *, ModuleOps> moduleOps;
  llvm::DenseSet<mlir::StringAttr> instantiated;
  llvm::DenseMap<Operation *, Scope *> moduleScopes;
  // Deques: items point at hops and scopes.
  std::deque<Hop> hops;
  std::deque<Scope> scopes;
  /// Each key of `original` to what was emitted for it.
  llvm::StringMap<std::string> originals;
  TypeTable types;
  FileTable files;
};
} // namespace

/// Sort the debug ops and instances of each module by scope, and check that a
/// module and a scope each have at most one `dbg.moduleinfo`. Check the
/// `params` of `dbg.moduleinfo` and `dbg.value`.
mlir::LogicalResult Emitter::collect() {
  bool failed = false;
  for (auto module : top.getOps<hw::HWModuleOp>()) {
    auto &ops = moduleOps[module];
    auto getKey = [&](Value scope) -> Operation * {
      return scope ? scope.getDefiningOp() : module;
    };
    module.walk([&](Operation *op) {
      if (auto info = dyn_cast<debug::ModuleInfoOp>(op)) {
        if (mlir::failed(checkExt(info, info.getParamsAttr())))
          failed = true;
        auto *key = getKey(info.getScope());
        auto &slot = key == module ? ops.info : ops.scopeInfos[key];
        if (slot) {
          auto diag = info.emitError("more than one dbg.moduleinfo for this ")
                      << (key == module ? "module" : "scope");
          diag.attachNote(slot.getLoc()) << "previous one is here";
          failed = true;
        }
        slot = info;
      } else if (auto value = dyn_cast<debug::ValueOp>(op)) {
        if (mlir::failed(checkExt(value, value.getParamsAttr())))
          failed = true;
      } else if (auto var = dyn_cast<debug::VariableOp>(op)) {
        ops.members[getKey(var.getScope())].push_back(op);
      } else if (auto scope = dyn_cast<debug::ScopeOp>(op)) {
        ops.members[getKey(scope.getScope())].push_back(op);
      } else if (auto inst = dyn_cast<hw::InstanceOp>(op)) {
        ops.members[getKey(inst.getScope())].push_back(op);
        instantiated.insert(inst.getModuleNameAttr().getAttr());
      }
    });
  }
  return mlir::failure(failed);
}

const Hop *Emitter::addHop(Operation *module, const Hop *parent,
                           StringRef instName) {
  std::string prefix;
  if (parent)
    prefix = (parent->prefix + instName + ".").str();
  return &hops.emplace_back(Hop{module, parent, instName, std::move(prefix)});
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

  SmallVector<std::pair<Operation *, const Hop *>> worklist;
  worklist.push_back(
      {scope.scope ? scope.scope : scope.root->module, scope.root});
  for (size_t i = 0; i < worklist.size(); ++i) {
    auto [key, hop] = worklist[i];
    auto &ops = moduleOps[hop->module];
    auto members = ops.members.find(key);
    if (members == ops.members.end())
      continue;
    for (auto *op : members->second) {
      if (isa<debug::VariableOp>(op)) {
        scope.items.push_back({op, hop});
        continue;
      }

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
        child.root = hop;
        child.key = dbgScope.getModuleName();
        // Inlined into a transparent module: the path goes through the
        // instances of that module.
        SmallVector<StringRef> names;
        for (auto *step = hop; step != scope.root; step = step->parent)
          names.push_back(step->instName);
        child.inlinePath = scope.inlinePath;
        for (auto name : llvm::reverse(names))
          child.inlinePath.push_back(name.str());
        child.inlinePath.push_back(dbgScope.getInstanceName().str());
        scope.items.push_back({op, hop, &child});
        continue;
      }

      auto inst = cast<hw::InstanceOp>(op);
      auto *callee = symbols.lookup(inst.getModuleNameAttr().getAttr());
      if (auto *child = moduleScopes.lookup(callee)) {
        scope.items.push_back({op, hop, child});
        continue;
      }
      if (!isa_and_nonnull<hw::HWModuleOp>(callee)) {
        inst.emitWarning("UHDI leaves out this instance: its module is not "
                         "an hw.module or hw.module.extern");
        continue;
      }
      worklist.push_back({callee, addHop(callee, hop, getInstanceName(inst))});
    }
  }
}

/// Give each variable its type. Variables of a type that cannot be shown are
/// left out with a warning. Instances get theirs in `addKeys`.
void Emitter::addVars() {
  for (auto &scope : scopes) {
    if (isa<hw::HWModuleExternOp, sv::SVVerbatimModuleOp>(scope.module)) {
      for (auto port : cast<hw::HWModuleLike>(scope.module).getPortList()) {
        auto type = types.get(port.type);
        if (!type) {
          scope.module->emitWarning("UHDI leaves out port '")
              << port.getName() << "': its type cannot be described";
          continue;
        }
        auto kind = port.isInput()    ? debug::VariableKind::Input
                    : port.isOutput() ? debug::VariableKind::Output
                                      : debug::VariableKind::InOut;
        scope.vars.push_back({"", port.getName(), *type, port.loc, kind,
                              nullptr, port.getVerilogName()});
      }
      continue;
    }

    for (auto &item : scope.items) {
      auto var = dyn_cast<debug::VariableOp>(item.op);
      if (!var)
        continue;
      auto type = types.get(var.getValue());
      if (!type) {
        var.emitWarning("UHDI leaves out this variable: its type cannot be "
                        "described");
        continue;
      }
      scope.vars.push_back(
          {"", var.getName(), *type, var.getLoc(), var.getKind(), &item});
    }
  }
}

/// The source class of a scope: the name in its `dbg.moduleinfo`, or the
/// `sourceName` of an external module. Empty if it has none.
static StringRef getClassName(Scope &scope) {
  if (scope.info)
    return scope.info.getTypeName();
  if (auto ext = dyn_cast<hw::HWModuleExternOp>(scope.module))
    return ext.getSourceName().value_or("");
  if (auto ext = dyn_cast<sv::SVVerbatimModuleOp>(scope.module))
    return ext.getSourceName().value_or("");
  return {};
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
      for (auto &entry : getExt(child->info.getParamsAttr()))
        type[entry.first] = std::move(entry.second);
    StringRef name = isa<debug::ScopeOp>(item.op)
                         ? child->scope.getInstanceName()
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
  if (!scope.scope)
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

  // Expressions (`$op`) are not emitted: no signal holds the value.
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
      for (auto &entry : getExt(scope.info.getParamsAttr()))
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
        if (auto dbgVar = dyn_cast<debug::VariableOp>(item->op)) {
          out.attribute(var.key, getValue(dbgVar.getValue(), item->hop));
          continue;
        }
        out.attributeObject(var.key, [&] {
          auto *child = item->child;
          if (auto inst = dyn_cast<hw::InstanceOp>(item->op)) {
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
  for (auto &type : types.types)
    for (auto &entry : *type.getAsObject())
      if (StringRef(entry.first).starts_with("x-"))
        profiles.insert(entry.first.str());
  for (auto &scope : scopes)
    if (scope.info)
      for (auto &entry : getExt(scope.info.getParamsAttr()))
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
      for (auto &scope : scopes)
        emitBinding(out, scope);
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
  // An instance's type names the key of the scope it instantiates, so deeper
  // inlined scopes get their keys first. Among equal copies, the first one
  // keeps the plain key.
  SmallVector<Scope *> order;
  for (auto &scope : emitter.scopes)
    order.push_back(&scope);
  llvm::stable_sort(order, [](Scope *a, Scope *b) {
    return a->inlinePath.size() > b->inlinePath.size();
  });
  for (auto *scope : order)
    emitter.addKeys(*scope);

  json::OStream out(os, indent);
  emitter.emit(out);
  os << "\n";
  return mlir::success();
}
