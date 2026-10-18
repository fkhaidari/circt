//===- EmitUHDI.cpp - UHDI emission ---------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Serialise the compile-unit's debug information into the UHDI JSON
// format from the `dbg.*` ops alone; knows nothing else about the producer.
//
// Shape: a `types` pool, and `modules` keyed by source name. A module owns its
// variables, its instances and any inline scopes nested in it. A variable names
// its source-language identity under `source` and its simulation-side binding
// under `target.verilog` -- one signal for a scalar, a dotted-member-path map
// for an aggregate.
//
//===----------------------------------------------------------------------===//

#include "LocationUtils.h"
#include "circt/Dialect/Comb/CombOps.h"
#include "circt/Dialect/Debug/DebugOps.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/SV/SVOps.h"
#include "circt/Dialect/SV/VerilogName.h"
#include "circt/Dialect/Seq/SeqTypes.h"
#include "circt/Target/DebugInfo.h"
#include "mlir/IR/BuiltinOps.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/ADT/TypeSwitch.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/Path.h"

#include <map>

#define DEBUG_TYPE "emit-uhdi"

using namespace mlir;
using namespace circt;
using namespace debug;

using llvm::json::Array;
using llvm::json::Object;

namespace {

static constexpr StringRef kFormatVersion = "1.0";
static constexpr StringRef kFormatVersion2 = "2.0";

/// `dbg.value` is a metadata wrapper (typeName / params) materialised by
/// LowerIntrinsics. Unwrap before type interning and name resolution to
/// reach the wrapped SSA value.
static mlir::Value unwrapDbgValue(mlir::Value v) {
  while (auto opResult = dyn_cast<OpResult>(v))
    if (auto vw = dyn_cast<debug::ValueOp>(opResult.getOwner()))
      v = vw.getValue();
    else
      break;
  return v;
}

/// Like `unwrapDbgValue`, but also looks through `dbg.enum` casts to reach
/// the real HW value for name resolution. A `dbg.enum` result has type
/// `!dbg.enum`, which `sv::resolveVerilogName` cannot resolve; its integer
/// operand is the actual signal. Used on the name-resolution path only -- the
/// type path keeps the `dbg.enum` wrapper so the enum typeRef is preserved.
static mlir::Value unwrapToHwValue(mlir::Value v) {
  while (auto opResult = dyn_cast<OpResult>(v)) {
    if (auto vw = dyn_cast<debug::ValueOp>(opResult.getOwner()))
      v = vw.getValue();
    else if (auto en = dyn_cast<debug::EnumOp>(opResult.getOwner()))
      v = en.getValue();
    else
      break;
  }
  return v;
}

/// Innermost `dbg.value` wrapping `v`, if any -- carries source-language
/// metadata (`typeName` / `params`).
static debug::ValueOp findDbgValue(mlir::Value v) {
  if (auto opResult = dyn_cast<OpResult>(v))
    if (auto vw = dyn_cast<debug::ValueOp>(opResult.getOwner()))
      return vw;
  return {};
}

/// Split a source-language type name of the form `Binding[X]` (`IO[UInt<8>]`)
/// into its two halves. `Binding` is how the variable was declared (IO / Wire /
/// Reg / ...) and belongs to the variable; `X` names the type itself and is
/// pooled on the type. A name with no wrapper is all `X` and has no binding.
static std::pair<StringRef, StringRef> splitSourceTypeName(StringRef typeName) {
  if (!typeName.ends_with("]"))
    return {StringRef(), typeName};
  size_t open = typeName.find('[');
  if (open == StringRef::npos || open == 0)
    return {StringRef(), typeName};
  StringRef binding = typeName.take_front(open);
  if (!llvm::all_of(binding,
                    [](char c) { return llvm::isAlnum(c) || c == '_'; }))
    return {StringRef(), typeName};
  return {binding, typeName.slice(open + 1, typeName.size() - 1)};
}

/// The `x-chisel` object of a `source`, created on first use. Keys that
/// describe the frontend rather than the hardware live there, so the core of
/// the document stays language-neutral and a consumer that does not know
/// Chisel can skip them wholesale.
static Object &sourceExt(Object &source) {
  return *source.try_emplace("x-chisel", Object{}).first->second.getAsObject();
}

/// Serialise a `params` ArrayAttr (frontend JSON preserved by LowerIntrinsics)
/// into a type's `source.params` array: UHDI sec.6.9 constructor parameters,
/// e.g. Chisel `Vec`'s `gen` / `length`. Native type preservation (StringAttr
/// -> string, BoolAttr -> bool, IntegerAttr -> int); an entry without a `name`
/// describes nothing and is dropped.
static Array renderTypeSourceParams(ArrayAttr params) {
  Array out;
  if (!params)
    return out;
  for (Attribute entryAttr : params) {
    auto dict = dyn_cast<DictionaryAttr>(entryAttr);
    if (!dict)
      continue;
    auto nameAttr = dict.getAs<StringAttr>("name");
    if (!nameAttr)
      continue;
    Object entry{{"name", nameAttr.getValue().str()}};
    auto put = [&](StringRef key, Attribute v) {
      if (auto s = dyn_cast_or_null<StringAttr>(v))
        entry[key.str()] = s.getValue().str();
      else if (auto b = dyn_cast_or_null<BoolAttr>(v))
        entry[key.str()] = b.getValue();
      else if (auto i = dyn_cast_or_null<IntegerAttr>(v))
        entry[key.str()] = i.getValue().getSExtValue();
    };
    put("type", dict.get("typeName"));
    put("value", dict.get("value"));
    out.push_back(std::move(entry));
  }
  return out;
}

/// Source-language type name and constructor params recorded by
/// `dbg.moduleinfo`. The intrinsic lowering sets the attribute on the module,
/// and PropagateDebugClassInfo moves it onto every instance of that module, so
/// it is read off the instance. A module with no instantiation site keeps its
/// own record, and inlining copies the record onto the `dbg.scope` it creates,
/// since the instance is gone by then.
static StringAttr moduleSourceTypeName(Operation *op) {
  if (auto miAttr = op->getAttrOfType<DictionaryAttr>(kDbgModuleInfoAttr))
    return miAttr.getAs<StringAttr>("typeName");
  return {};
}

static Array moduleSourceParams(Operation *op) {
  if (auto miAttr = op->getAttrOfType<DictionaryAttr>(kDbgModuleInfoAttr))
    return renderTypeSourceParams(miAttr.getAs<ArrayAttr>("params"));
  return {};
}

/// Name the module carries in the netlist. ExportVerilog records a rename on
/// the module op, and that name -- not the symbol -- is what a consumer reading
/// the Verilog has to match against.
static StringRef verilogModuleName(Operation *op) {
  if (auto attr = op->getAttrOfType<StringAttr>("verilogName"))
    return attr.getValue();
  return cast<mlir::SymbolOpInterface>(op).getName();
}

/// LowerTypes flattens aggregate ports into per-field wires aliasing the
/// flat ports; PrettifyVerilogNames then renames the wire's `hw.verilogName`
/// (e.g. `io_a` -> `io_a_0`) to dodge the port-name collision.
/// `sv::resolveVerilogName` returns the renamed alias, not the canonical
/// signal VCD/verilator consumers expect. Walk the wire-aliasing pattern to
/// recover the port name; null if `value` isn't a port alias.
static StringAttr resolvePortAliasName(mlir::Value value) {
  Operation *op = value.getDefiningOp();
  if (!op)
    return {};
  // Pre-ExportVerilog: hw.wire %port -> result. `getInput()` is the port.
  if (auto hwWire = dyn_cast<hw::WireOp>(op))
    if (auto ba = dyn_cast<BlockArgument>(hwWire.getInput()))
      if (auto mod = dyn_cast<hw::HWModuleOp>(ba.getOwner()->getParentOp()))
        return mod.getInputNameAttr(ba.getArgNumber());
  // Post-ExportVerilog: sv.read_inout %wire. Walk to the wire and
  // inspect its sv.assign / hw.output uses for port-alias patterns.
  Operation *wireOp = nullptr;
  if (auto rio = dyn_cast<sv::ReadInOutOp>(op)) {
    if (auto *def = rio.getInput().getDefiningOp())
      if (isa<sv::WireOp, sv::LogicOp>(def))
        wireOp = def;
  } else if (isa<sv::WireOp, sv::LogicOp>(op)) {
    wireOp = op;
  }
  if (!wireOp)
    return {};
  Value wireResult = wireOp->getResult(0);
  // Input pattern: `sv.assign %wire, %port_block_arg`.
  for (auto &use : wireResult.getUses()) {
    auto assign = dyn_cast<sv::AssignOp>(use.getOwner());
    if (!assign || use.getOperandNumber() != 0)
      continue;
    if (auto ba = dyn_cast<BlockArgument>(assign.getSrc()))
      if (auto mod = dyn_cast<hw::HWModuleOp>(ba.getOwner()->getParentOp()))
        return mod.getInputNameAttr(ba.getArgNumber());
  }
  // Output pattern: `%r = sv.read_inout %wire; hw.output %r, ...`.
  for (auto &use : wireResult.getUses())
    if (auto rio = dyn_cast<sv::ReadInOutOp>(use.getOwner()))
      for (auto &readUse : rio->getUses())
        if (auto out = dyn_cast<hw::OutputOp>(readUse.getOwner()))
          if (auto mod = out->getParentOfType<hw::HWModuleOp>())
            return mod.getOutputNameAttr(readUse.getOperandNumber());
  return {};
}

/// If `value` is a post-ExportVerilog output-port alias
/// (`sv.read_inout %wire` where the wire feeds `hw.output`), return the
/// output-id (operand number into hw.output). Otherwise return nullopt.
/// The value may first be unwrapped through dbg.enum / dbg.value by the
/// caller before this is called; pass the already-unwrapped HW value.
/// A register counts too: `assign o = r` reads it once for the port and once
/// for the variable, and the two reads are different values.
static std::optional<unsigned> resolveAsOutputPortId(mlir::Value value) {
  auto *op = value.getDefiningOp();
  if (!op)
    return std::nullopt;
  Operation *wireOp = nullptr;
  if (auto rio = dyn_cast<sv::ReadInOutOp>(op)) {
    if (auto *def = rio.getInput().getDefiningOp())
      if (isa<sv::WireOp, sv::LogicOp, sv::RegOp>(def))
        wireOp = def;
  } else if (isa<sv::WireOp, sv::LogicOp, sv::RegOp>(op)) {
    wireOp = op;
  }
  if (!wireOp)
    return std::nullopt;
  Value wireResult = wireOp->getResult(0);
  // Output pattern: `%r = sv.read_inout %wire; hw.output %r, ...`.
  for (auto &use : wireResult.getUses())
    if (auto rio = dyn_cast<sv::ReadInOutOp>(use.getOwner()))
      for (auto &readUse : rio->getUses())
        if (dyn_cast<hw::OutputOp>(readUse.getOwner()))
          return readUse.getOperandNumber();
  return std::nullopt;
}

/// Output-id of the `hw.output` operand an input port feeds directly, for the
/// `assign b = a` shape where no wire sits between the two. The input's value
/// then backs both ports, so the variable's own name decides which one it
/// describes. Block arguments only, on purpose: a value produced inside the
/// body carries its own Verilog name, which `resolveAsOutputPortId` and
/// `sv::resolveVerilogName` resolve already and which names the wire the
/// waveform actually shows.
static std::optional<unsigned> resolveAsDirectOutputPortId(mlir::Value value,
                                                           StringRef varName,
                                                           hw::HWModuleOp mod) {
  if (varName.empty() || !mod || !value)
    return std::nullopt;
  auto modType = mod.getHWModuleType();
  for (auto &use : value.getUses()) {
    if (!isa<hw::OutputOp>(use.getOwner()))
      continue;
    unsigned outId = use.getOperandNumber();
    if (modType.getPortName(modType.getPortIdForOutputId(outId)) == varName)
      return outId;
  }
  return std::nullopt;
}

/// Combined leaf-name resolver: try the port-alias walk first (so bundle
/// fields surface as `io_a` rather than the lowering-introduced
/// `io_a_0`), then fall back to the standard SV-name resolver.
static StringAttr resolveBundleFieldName(mlir::Value value) {
  if (auto a = resolvePortAliasName(value))
    return a;
  return sv::resolveVerilogName(value);
}

//===----------------------------------------------------------------------===//
// File table & locations
//===----------------------------------------------------------------------===//

/// Per-language file list, deduplicated, in insertion order.
struct FileTable {
  llvm::StringMap<unsigned> indexByPath;
  std::vector<std::string> ordered;

  /// Interns `path`, or nullopt for an empty one: an unnamed file would
  /// surface as an empty string consumers cannot resolve.
  std::optional<unsigned> internIfNamed(StringRef path) {
    if (path.empty())
      return std::nullopt;
    return intern(path);
  }

  unsigned intern(StringRef path) {
    auto it = indexByPath.find(path);
    if (it != indexByPath.end())
      return it->second;
    unsigned idx = ordered.size();
    ordered.emplace_back(path.str());
    indexByPath[path] = idx;
    return idx;
  }

  Array asArray() const {
    Array out;
    for (auto &s : ordered)
      out.push_back(s);
    return out;
  }
};

using circt::debuginfo::bestLocation;

/// Location object; nullopt if no FileLineColLoc. `file` indexes the file list
/// of whichever language the location belongs to. A location without a file
/// name lies in `unnamed`, if given.
static std::optional<Object> locationObject(FileLineColLoc loc,
                                            StringRef prefix, FileTable &files,
                                            StringRef unnamed = {}) {
  if (!loc)
    return std::nullopt;
  StringRef name = loc.getFilename().getValue();
  if (name.empty())
    name = unnamed;
  SmallString<128> path;
  if (prefix.empty())
    path = name;
  else {
    path = prefix;
    llvm::sys::path::append(path, name);
  }
  auto fileIdx = files.internIfNamed(path);
  if (!fileIdx)
    return std::nullopt;
  Object o{{"file", int64_t(*fileIdx)}};
  if (loc.getLine() > 0)
    o["beginLine"] = int64_t(loc.getLine());
  if (loc.getColumn() > 0)
    o["beginColumn"] = int64_t(loc.getColumn());
  return o;
}

//===----------------------------------------------------------------------===//
// Type pool
//===----------------------------------------------------------------------===//

/// Source-language identity of a value: the type half of its `dbg.value`
/// `typeName` plus the constructor params recorded next to it. Empty when the
/// value carries no debug metadata.
struct SourceType {
  StringRef name;
  ArrayAttr params;
};

static SourceType sourceTypeOf(mlir::Value value) {
  debug::ValueOp vw = findDbgValue(value);
  if (!vw)
    return {};
  StringRef name;
  if (auto tn = vw.getTypeNameAttr())
    name = splitSourceTypeName(tn.getValue()).second;
  return {name, vw.getParamsAttr()};
}

/// Type identity is structure *plus* source-language name: Chisel's `Clock` and
/// a plain `Bool` are both one-bit, but a consumer that collapses them cannot
/// tell a clock from a boolean afterwards. Entries are therefore keyed by both,
/// and every variable's display type is `binding[types[typeRef].source.name]`
/// with no per-variable escape hatch.
///
/// Ids are handed out as opaque placeholders during the walk and resolved in
/// `finalizeIds`, once the whole document is known: a structure named just one
/// way keeps its plain id (`uint8`), and only a structure two names disagree
/// over splits into `uint8_<name>` variants.
class TypePool {
public:
  /// Intern the type of `value` under `src`. Scalar ints map to canonical
  /// ground ids (`uint8`, `bool`, etc.); aggregates get a structural key + a
  /// hint-derived id (e.g. "BundleTest_io_in") or a `struct_N`/`array_N`
  /// fallback. A `dbg.enum` wrapper overrides the scalar typeRef with the enum
  /// type-pool entry.
  std::string internValueType(mlir::Value value, StringRef nameHint = {},
                              SourceType src = {}, StringRef ground = {}) {
    value = unwrapDbgValue(value);
    if (auto opResult = dyn_cast<OpResult>(value)) {
      // A `dbg.enum` wrapper overrides the underlying integer typeRef with the
      // enum type-pool entry.
      if (auto en = dyn_cast_or_null<debug::EnumOp>(opResult.getOwner()))
        return internEnum(en, src);
      if (auto s = dyn_cast_or_null<debug::StructOp>(opResult.getOwner()))
        return internStruct(s, nameHint, src);
      if (auto a = dyn_cast_or_null<debug::ArrayOp>(opResult.getOwner()))
        return internArray(a, nameHint, src);
    }
    return internType(value.getType(), value.getLoc(), src, ground);
  }

  /// Whether `groundOf` reads `dbg.ground`. Layout 1 keeps the integer types.
  bool groundKinds = false;

  /// The `dbg.ground` kind of operand `index` of `user`, read from the op
  /// that takes the leaf itself, past any `dbg.value` wrapper.
  StringRef groundOf(Operation *user, unsigned index) const {
    if (!groundKinds)
      return {};
    mlir::Value value = user->getOperand(index);
    while (auto wrapper = value.getDefiningOp<debug::ValueOp>()) {
      user = wrapper;
      index = 0;
      value = wrapper.getValue();
    }
    Attribute attr = user->getAttr(debug::kDbgGroundAttr);
    if (auto kind = dyn_cast_or_null<StringAttr>(attr))
      return kind.getValue();
    if (auto kinds = dyn_cast_or_null<ArrayAttr>(attr))
      if (index < kinds.size())
        if (auto kind = dyn_cast<StringAttr>(kinds[index]))
          return kind.getValue();
    return {};
  }

  /// Intern an IR Type directly (synthesized-port fallback). Preserves
  /// !seq.clock as `kind: clock` (spec §4.2 GroundClock); recurses into
  /// `hw.array` / `hw.struct` so aggregate ports don't silently collapse
  /// to a `uint0` placeholder. Truly opaque types still fall back to
  /// `uint<0>` but surface a warning at `warnLoc` so the corruption is
  /// at least audible.
  std::string internType(mlir::Type type, mlir::Location warnLoc,
                         SourceType src = {}, StringRef ground = {}) {
    if (auto i = dyn_cast<IntegerType>(type)) {
      if (ground == "clock" && i.getWidth() == 1)
        return internGround("clock", 0, src);
      return internGround(i.isSigned() || ground == "sint" ? "sint" : "uint",
                          i.getWidth(), src);
    }
    if (isa<seq::ClockType>(type))
      return internGround("clock", 0, src);
    if (auto arr = dyn_cast<hw::ArrayType>(type))
      return internArrayType(arr, warnLoc, src);
    if (auto st = dyn_cast<hw::StructType>(type))
      return internStructType(st, warnLoc, src);
    mlir::emitWarning(warnLoc) << "uhdi: unrecognised type " << type
                               << "; falling back to uint<0> placeholder";
    return internGround("uint", 0, src);
  }

  /// Resolve the placeholders into public ids.
  ///
  /// Interning keeps one entry per structure *and* name, which oversplits: an
  /// occurrence that carried no name at all -- a port with no debug metadata --
  /// contradicts nothing, so it joins the named entry whenever the structure
  /// has just one name. The integer under an enum is different: nothing could
  /// have named it, so it stays apart from a named entry. Only two names
  /// genuinely disagree, and there each keeps an entry of its own. Merging
  /// children can make two parents identical, so this runs to a fixed point.
  ///
  /// Ids then follow: a structure only one name is ever attached to keeps its
  /// plain id (`uint8`), and where two names meet each variant becomes
  /// `<id>_<name>`, leaving the plain id to the nameless occurrences.
  void finalizeIds() {
    merged.assign(pool.size(), 0);
    for (auto i : llvm::seq<unsigned>(0, pool.size()))
      merged[i] = i;

    for (bool changed = true; changed;) {
      changed = false;
      std::map<std::string, SmallVector<unsigned, 2>> shapes;
      for (auto i : llvm::seq<unsigned>(0, pool.size()))
        if (find(i) == i)
          shapes[shapeOf(i)].push_back(i);

      for (auto &[shape, group] : shapes) {
        if (group.size() < 2)
          continue;
        // One representative per distinct name, the earliest interned.
        llvm::StringMap<unsigned> byName;
        SmallVector<unsigned, 2> nameless;
        for (unsigned i : group) {
          if (pool[i].sourceName.empty())
            nameless.push_back(i);
          else if (auto [it, fresh] = byName.try_emplace(pool[i].sourceName, i);
                   !fresh)
            changed |= mergeInto(i, it->second);
        }
        unsigned into = byName.size() == 1 ? byName.begin()->second
                        : nameless.empty() ? 0u
                                           : nameless.front();
        if (byName.size() > 1 && nameless.empty())
          continue;
        for (unsigned i : nameless)
          if (i != into && !(pool[i].unnamed && !pool[into].sourceName.empty()))
            changed |= mergeInto(i, into);
      }
    }

    llvm::StringMap<unsigned> groupSize;
    for (auto i : llvm::seq<unsigned>(0, pool.size()))
      if (find(i) == i)
        ++groupSize[pool[i].baseId];

    llvm::StringSet<> taken;
    auto claim = [&](const Twine &want) {
      std::string base = want.str();
      std::string id = base;
      for (unsigned n = 2; !taken.insert(id).second; ++n)
        id = base + "_" + std::to_string(n);
      return id;
    };
    // Plain-id holders first, so a split variant can never take an id another
    // structure was going to claim outright.
    for (auto i : llvm::seq<unsigned>(0, pool.size()))
      if (find(i) == i &&
          (groupSize[pool[i].baseId] == 1 || pool[i].sourceName.empty()))
        pool[i].id = claim(pool[i].baseId);
    for (auto i : llvm::seq<unsigned>(0, pool.size()))
      if (find(i) == i && pool[i].id.empty())
        pool[i].id =
            claim(pool[i].baseId + "_" + sanitizeIdPart(pool[i].sourceName));
  }

  /// Public id of a placeholder handed out during the walk.
  std::string resolve(StringRef placeholder) const {
    return pool[find(indexOf(placeholder))].id;
  }

  /// The `types` object, with every internal reference rewritten to the public
  /// ids. Only valid after `finalizeIds`.
  Object takeObject() {
    Object out;
    for (auto i : llvm::seq<unsigned>(0, pool.size())) {
      if (find(i) != i)
        continue;
      Entry &e = pool[i];
      Object body = std::move(e.body);
      remapRefs(body);
      if (!e.sourceName.empty()) {
        Object source{{"name", e.sourceName}};
        if (e.params && e.paramsAgree)
          sourceExt(source)["params"] = std::move(*e.params);
        body["source"] = std::move(source);
      }
      out[e.id] = std::move(body);
    }
    return out;
  }

private:
  struct Entry {
    Object body;
    /// Readable id this entry would like: `uint8`, a name hint, `struct_0`.
    std::string baseId;
    /// Non-empty for a nominal type: an enum is identified by its fqn, so two
    /// enums that happen to share a layout must not collapse into one.
    std::string nominal;
    /// Source-language type name, empty when nothing named this type.
    std::string sourceName;
    std::optional<Array> params;
    bool paramsAgree = true;
    /// Filled by `finalizeIds`.
    std::string id;
    /// Set on a type no source declaration spells, such as the integer under
    /// an enum. Such an entry never joins a named one.
    bool unnamed = false;
  };

  SmallVector<Entry, 0> pool;
  /// Union-find over `pool`, filled by `finalizeIds`: entries describing the
  /// same type collapse onto one representative.
  SmallVector<unsigned> merged;
  /// structural key + '\0' + source name -> pool index.
  llvm::StringMap<unsigned> byKey;
  /// Enum fqn -> the layout first seen under it, for the redefinition check.
  llvm::StringMap<llvm::json::Value> enumLayouts;
  unsigned structCounter = 0, arrayCounter = 0;

  unsigned find(unsigned index) const {
    while (merged[index] != index)
      index = merged[index];
    return index;
  }

  /// Fold `from` onto `into`, keeping the params they agree on.
  bool mergeInto(unsigned from, unsigned into) {
    if (find(from) == find(into))
      return false;
    Entry &dst = pool[into];
    Entry &src = pool[from];
    if (src.params && !dst.params)
      dst.params = std::move(src.params);
    else if (src.params && dst.params &&
             llvm::json::Value(Array(*dst.params)) !=
                 llvm::json::Value(Array(*src.params)))
      dst.paramsAgree = false;
    dst.paramsAgree &= src.paramsAgree;
    merged[find(from)] = find(into);
    return true;
  }

  /// The entry's body with every reference put through the merge map, so two
  /// entries compare equal exactly when they describe the same type.
  std::string shapeOf(unsigned index) const {
    Object body = *llvm::json::Value(Object(pool[index].body)).getAsObject();
    canonicaliseRefs(body);
    std::string out = pool[index].nominal + "\0";
    llvm::raw_string_ostream os(out);
    os << llvm::json::Value(std::move(body));
    return out;
  }

  void canonicaliseRefs(Object &body) const {
    for (StringRef key : {"typeRef", "elementRef", "underlyingTypeRef"})
      if (auto ref = body.getString(key))
        body[key] = placeholderFor(find(indexOf(*ref)));
    if (auto *members = body.getArray("members"))
      for (llvm::json::Value &m : *members)
        if (auto *o = m.getAsObject())
          canonicaliseRefs(*o);
  }

  static std::string placeholderFor(unsigned index) {
    return "%t" + std::to_string(index);
  }
  static unsigned indexOf(StringRef placeholder) {
    unsigned index = 0;
    bool bad = placeholder.drop_front(2).getAsInteger(10, index);
    assert(!bad && placeholder.starts_with("%t") && "not a type placeholder");
    (void)bad;
    return index;
  }

  /// Keep ids to the characters an id is expected to hold; `UInt<8>` would
  /// otherwise put angle brackets in a key consumers use as an identifier.
  static std::string sanitizeIdPart(StringRef name) {
    std::string out;
    for (char c : name)
      out.push_back(llvm::isAlnum(c) || c == '_' ? c : '_');
    return out;
  }

  /// Rewrite the placeholders a body holds into public ids.
  void remapRefs(Object &body) {
    for (StringRef key : {"typeRef", "elementRef", "underlyingTypeRef"})
      if (auto ref = body.getString(key))
        body[key] = resolve(*ref);
    if (auto *members = body.getArray("members"))
      for (llvm::json::Value &m : *members)
        if (auto *o = m.getAsObject())
          remapRefs(*o);
  }

  /// Fold one occurrence's constructor params into `e`. Params only reach the
  /// type when every occurrence naming it the same way agrees on them.
  void noteParams(Entry &e, ArrayAttr params) {
    Array rendered = renderTypeSourceParams(params);
    if (rendered.empty())
      return;
    if (!e.params)
      e.params = std::move(rendered);
    else if (llvm::json::Value(Array(*e.params)) !=
             llvm::json::Value(std::move(rendered)))
      e.paramsAgree = false;
  }

  /// Intern one entry; `build` produces its body the first time the pair of
  /// structure and name is seen.
  std::string intern(const Twine &structuralKey, const Twine &baseId,
                     SourceType src, llvm::function_ref<Object()> build,
                     StringRef nominal = {}, bool unnamed = false) {
    llvm::SmallString<128> key;
    structuralKey.toVector(key);
    key.push_back('\0');
    key.append(src.name);
    if (unnamed)
      key.push_back('\0');
    auto [it, inserted] = byKey.try_emplace(key, pool.size());
    if (inserted) {
      pool.push_back(Entry{
          build(), baseId.str(), nominal.str(), src.name.str(), {}, true, {}});
      pool.back().unnamed = unnamed;
    }
    Entry &e = pool[it->second];
    noteParams(e, src.params);
    return placeholderFor(it->second);
  }

  std::string internGround(StringRef kind, unsigned width, SourceType src,
                           bool unnamed = false) {
    std::string id = (kind == "uint" && width == 1) ? std::string("bool")
                     : kind == "clock"              ? std::string("clock")
                                       : (kind + std::to_string(width)).str();
    return intern(
        id, id, src,
        [&] {
          Object d{{"kind", kind.str()}};
          if (kind == "uint" || kind == "sint")
            d["width"] = int64_t(width);
          return d;
        },
        /*nominal=*/{}, unnamed);
  }

  /// Intern a `dbg.enum` value op as a `kind: "enum"` type-pool entry. The
  /// dedup key is the fqn (preferred) or else the typeName, so identical enums
  /// materialised inline at many use sites — including across modules —
  /// collapse to one pool entry. Width of the underlying int is derived from
  /// the widest IntegerAttr in the variants map. `variantsMap` is stored in IR
  /// as `<name> -> IntegerAttr` (DictionaryAttr keys must be strings); the
  /// emitted UHDI form inverts that to `"<int>" -> "<name>"` to match HGLDD's
  /// `enum_defs` shape. Idempotent across multiple references.
  std::string internEnum(debug::EnumOp op, SourceType src) {
    StringRef fqn = op.getFqn().value_or("");
    std::string id = fqn.empty() ? op.getEnumTypeName().str() : fqn.str();
    DictionaryAttr variantsMap = op.getVariantsMapAttr();
    unsigned width = 1;
    for (NamedAttribute na : variantsMap)
      if (auto intAttr = dyn_cast<IntegerAttr>(na.getValue()))
        width = std::max<unsigned>(width,
                                   intAttr.getType().getIntOrFloatBitWidth());
    std::string underlyingId =
        internGround("uint", width, {}, /*unnamed=*/true);
    Object variantsJson;
    for (NamedAttribute na : variantsMap) {
      auto intAttr = dyn_cast<IntegerAttr>(na.getValue());
      if (!intAttr)
        continue;
      llvm::SmallString<16> keyBuf;
      intAttr.getValue().toString(keyBuf, /*Radix=*/10, /*Signed=*/false);
      variantsJson[std::string(keyBuf)] = na.getName().getValue().str();
    }
    llvm::json::Value layout =
        Object{{"underlyingTypeRef", underlyingId},
               {"variants", llvm::json::Value(Object(variantsJson))}};
    // The key identifies the enum, so a second definition claiming it must
    // describe the same layout. When it does not, keeping the first silently
    // would decode the second enum's values against the wrong variant names,
    // so give it a key of its own and say so.
    auto [it, inserted] = enumLayouts.try_emplace(id, layout);
    if (!inserted && it->second != layout) {
      unsigned disambiguator = 1;
      std::string unique;
      do {
        unique = id + "#" + std::to_string(disambiguator++);
      } while (enumLayouts.count(unique));
      mlir::emitWarning(op.getLoc())
          << "uhdi: enum '" << id
          << "' redefined with a different layout; emitting it as '" << unique
          << "'";
      id = unique;
      enumLayouts.try_emplace(id, layout);
    }
    return intern(
        id, id, src,
        [&] {
          return Object{{"kind", "enum"},
                        {"underlyingTypeRef", underlyingId},
                        {"variants", std::move(variantsJson)}};
        },
        /*nominal=*/id);
  }

  /// `flipped: true` on a member the FIRRTL bundle flipped, as recorded in
  /// `dbg.flips`; relative to this struct, like FIRRTL `flip`.
  std::string internStruct(debug::StructOp op, StringRef nameHint,
                           SourceType src) {
    Array members;
    std::string key = "struct{";
    auto flips = op->getAttrOfType<DenseBoolArrayAttr>(debug::kDbgFlipsAttr);
    if (flips && flips.asArrayRef().size() != op.getFields().size())
      flips = {};
    for (auto [index, nameAttr, field] :
         llvm::enumerate(op.getNames(), op.getFields())) {
      StringRef n = cast<StringAttr>(nameAttr).getValue();
      std::string childHint =
          nameHint.empty() ? std::string() : (nameHint + "_" + n).str();
      // dbg.value wraps the leaf-value with metadata (typeName, params);
      // an enum leaf is additionally wrapped in dbg.enum. Pass the wrapped
      // value to internValueType so the enum/struct typeRef is preserved,
      // not the raw integer.
      std::string ft = internValueType(field, childHint, sourceTypeOf(field),
                                       groundOf(op, index));
      bool flipped = flips && flips[index];
      key.append(n).append(1, ':').append(ft);
      if (flipped)
        key += '!';
      key += ',';
      Object m{{"name", n.str()}, {"typeRef", ft}};
      if (flipped)
        m["flipped"] = true;
      members.push_back(std::move(m));
    }
    key += '}';
    return intern(
        key, aggregateId(nameHint, "struct_", structCounter), src, [&] {
          return Object{{"kind", "struct"}, {"members", std::move(members)}};
        });
  }

  std::string internArray(debug::ArrayOp op, StringRef nameHint,
                          SourceType src) {
    auto elems = op.getElements();
    std::string elemId =
        elems.empty()
            ? internGround("uint", 0, {})
            : internValueType(elems.front(), nameHint,
                              sourceTypeOf(elems.front()), groundOf(op, 0));
    std::string key =
        "array{" + elemId + ':' + std::to_string(elems.size()) + '}';
    return intern(key, aggregateId(nameHint, "array_", arrayCounter), src, [&] {
      return Object{{"kind", "vector"},
                    {"elementRef", elemId},
                    {"size", int64_t(elems.size())}};
    });
  }

  /// Intern a `hw.struct` type directly (port type, no dbg.struct
  /// wrapper). Used by `internType` on aggregate ports that survived
  /// LowerTypes (e.g. extmodule signatures, or ports whose lowering was
  /// skipped). Structural key only — no name hint to honour here.
  std::string internStructType(hw::StructType type, mlir::Location warnLoc,
                               SourceType src) {
    Array members;
    std::string key = "struct{";
    for (auto &field : type.getElements()) {
      std::string ft = internType(field.type, warnLoc);
      key.append(field.name.getValue())
          .append(1, ':')
          .append(ft)
          .append(1, ',');
      members.push_back(
          Object{{"name", field.name.getValue().str()}, {"typeRef", ft}});
    }
    key += '}';
    return intern(key, aggregateId({}, "struct_", structCounter), src, [&] {
      return Object{{"kind", "struct"}, {"members", std::move(members)}};
    });
  }

  /// Intern a `hw.array` type directly (port type, no dbg.array wrapper).
  std::string internArrayType(hw::ArrayType type, mlir::Location warnLoc,
                              SourceType src) {
    std::string elemId = internType(type.getElementType(), warnLoc);
    std::string key =
        "array{" + elemId + ':' + std::to_string(type.getNumElements()) + '}';
    return intern(key, aggregateId({}, "array_", arrayCounter), src, [&] {
      return Object{{"kind", "vector"},
                    {"elementRef", elemId},
                    {"size", int64_t(type.getNumElements())}};
    });
  }

  /// Preferred id of an aggregate: the caller's name hint, else `struct_N` /
  /// `array_N`. Collisions are settled in `finalizeIds`.
  std::string aggregateId(StringRef hint, StringRef prefix, unsigned &counter) {
    if (!hint.empty())
      return hint.str();
    return (prefix + std::to_string(counter++)).str();
  }
};

//===----------------------------------------------------------------------===//
// Constant values
//===----------------------------------------------------------------------===//

static Object renderBits(const llvm::APInt &val);

/// Render a hw.constant: `constant` for <=63-bit values (cap at 63 so the
/// cast to int64_t never sign-flips), `bitVector` otherwise. Width is
/// implicit in the variable's typeRef.
static Object renderConstant(const llvm::APInt &val) {
  if (val.getActiveBits() <= 63)
    return Object{{"constant", static_cast<int64_t>(val.getZExtValue())}};
  return renderBits(val);
}

/// Render a hw.constant as `bitVector`, all of its bits, so the width shows.
static Object renderBits(const llvm::APInt &val) {
  Object lit;
  unsigned bw = val.getBitWidth();
  llvm::SmallString<128> bits;
  val.toString(bits, /*Radix=*/2, /*Signed=*/false,
               /*formatAsCLiteral=*/false, /*UpperCase=*/false,
               /*InsertSeparators=*/false);
  while (bits.size() < bw)
    bits.insert(bits.begin(), '0'); // toString drops leading zeros.
  lit["bitVector"] = bits.str().str();
  return lit;
}

//===----------------------------------------------------------------------===//
// Variable / scope assembly
//===----------------------------------------------------------------------===//

/// Bundle of per-document mutable state passed through the assembly
/// helpers. Keeps the function signatures from sprouting a half-dozen
/// args each.
struct EmitState {
  FileTable &chiselFiles, &verilogFiles;
  StringRef chiselPrefix, verilogPrefix;
  bool onlyExisting;
  llvm::StringMap<bool> &existsCache;
  /// Layout 2: the netlist an emitted location without a file name lies in,
  /// as ExportVerilog writes one file without naming it.
  StringRef unnamedVerilogFile = {};

  std::optional<Object> chiselLoc(Location loc) {
    return locationObject(
        bestLocation(loc, /*emitted=*/false, onlyExisting, &existsCache),
        chiselPrefix, chiselFiles);
  }
  std::optional<Object> verilogLoc(Location loc) {
    return locationObject(
        bestLocation(loc, /*emitted=*/true, onlyExisting, &existsCache),
        verilogPrefix, verilogFiles, unnamedVerilogFile);
  }
};

/// One `variables[key]` entry, held until the document-wide type-source
/// resolution and the per-scope key assignment have run.
struct VarRecord {
  std::string name;
  std::string typeRef;
  StringRef direction;
  /// Layout 2: `in` or `out` when the variable declares a port, as the
  /// frontend lowering recorded it.
  StringRef portDirection;
  /// A port record is dropped when an aggregate variable already covers its
  /// signal; an instance view moves to `instances[..].target` instead.
  bool isPort = false;
  bool isInstanceView = false;
  std::optional<Object> sourceLoc;
  /// Raw `Binding[X]` name as the frontend spelled it; only the `Binding` half
  /// belongs to the variable, the rest names the type.
  StringAttr sourceTypeName;
  /// `source.params`: constructor params the frontend recorded on this
  /// variable's own declaration.
  Array sourceParams;
  /// `target.verilog`: a signal name / literal for a scalar, a dotted-path map
  /// for an aggregate.
  std::optional<llvm::json::Value> target;
  /// `target.loc`, an aggregate's own simulation-side location: a dotted-path
  /// map has nowhere to put the `loc` a scalar binding embeds.
  std::optional<Object> targetLoc;
  /// Signal this variable binds to as a whole, for the duplicate-port drop.
  std::string scalarSignal;
  /// Absolute port index when the variable is a port; that port needs no
  /// synthesized record.
  std::optional<unsigned> portIndex;
  /// Per-port bindings of an instance view.
  Object instanceTarget;
  /// Module dedup moved the variable out of (`dbg.origin`); empty for one
  /// declared where it sits.
  StringRef origin;
  /// Made up for a port no `dbg.variable` covers.
  bool synthesized = false;

  bool dropped = false;
  std::string key;
  Object entry;
};

struct InstanceRecord {
  std::string as;
  std::string moduleRef;
  /// The module dedup merged into `moduleRef`, if this instance stood for it.
  std::string origin;
  Object source;
  /// `target.loc`, the instance's own Verilog-side location.
  Object target;
  /// `target.verilog`: port -> binding, from the instance view.
  Object verilogTarget;
};

/// A `modules[key]` entry or, nested under one, an inline scope.
struct ScopeRecord {
  /// The module's symbol name, which is both the emitted key and what instance
  /// operands refer to; an inline scope gets a placeholder and is found
  /// through its op.
  std::string id;
  StringRef kind;
  Object source;
  Object target;
  SmallVector<VarRecord, 0> vars;
  SmallVector<InstanceRecord, 0> instances;
  SmallVector<unsigned> childScopes;
  /// Signals reachable as a leaf of some aggregate variable here.
  llvm::StringSet<> aggregateLeaves;
  /// The module or `dbg.scope` op this record was made from.
  Operation *op = nullptr;
};

//===----------------------------------------------------------------------===//
// Emitter driver
//===----------------------------------------------------------------------===//

class UhdiEmitter {
public:
  UhdiEmitter(Operation *root, const EmitUHDIOptions &options)
      : root(root), options(options) {
    types.groundKinds = options.format == 2;
  }
  LogicalResult run(raw_ostream &os);

private:
  Operation *root;
  const EmitUHDIOptions &options;
  TypePool types;
  FileTable chiselFiles, verilogFiles;
  llvm::StringMap<bool> existsCache;

  SmallVector<ScopeRecord, 0> scopes;
  llvm::StringMap<unsigned> scopeIndex;
  /// Index into `scopes` of the record a `dbg.scope` op became.
  llvm::DenseMap<Operation *, unsigned> scopeOfOp;
  SmallVector<unsigned> topLevelScopes;
  llvm::DenseMap<Operation *, llvm::StringSet<>> instanceNamesByMod;

  EmitState state() {
    return EmitState{chiselFiles,
                     verilogFiles,
                     options.sourceFilePrefix,
                     options.outputFilePrefix,
                     options.onlyExistingFileLocs,
                     existsCache,
                     options.format == 2 ? options.verilogFileName : ""};
  }

  ScopeRecord &addScope(StringRef id, StringRef kind);
  ScopeRecord *findScope(StringRef id);
  ScopeRecord *ownerScope(debug::VariableOp var);
  std::optional<unsigned> containerOf(debug::ScopeOp scope);
  const llvm::StringSet<> &instanceNames(hw::HWModuleOp mod);

  void collect(mlir::ModuleOp top);
  void collectModule(hw::HWModuleOp module, EmitState &s);
  void collectInlineScope(debug::ScopeOp scope, EmitState &s);
  VarRecord collectVariable(debug::VariableOp var, EmitState &s,
                            ScopeRecord &scope);
  void synthesizePortVars(hw::HWModuleOp mod, ScopeRecord &scope,
                          const llvm::DenseSet<unsigned> &coveredPortIndices);

  void walkAggregate(mlir::Value aggregate, const Twine &prefix, Object &out,
                     ScopeRecord &scope);
  std::optional<llvm::json::Value> memberBinding(mlir::Value field,
                                                 ScopeRecord &scope);

  void finalizeVariables();
  Object buildVariableEntry(VarRecord &var);

  void renderScope(llvm::json::OStream &j, unsigned index);
  void renderLayout2(llvm::json::OStream &j);
};

ScopeRecord &UhdiEmitter::addScope(StringRef id, StringRef kind) {
  scopeIndex[id] = scopes.size();
  scopes.push_back(ScopeRecord{id.str(), kind, {}, {}, {}, {}, {}, {}});
  return scopes.back();
}

ScopeRecord *UhdiEmitter::findScope(StringRef id) {
  auto it = scopeIndex.find(id);
  return it == scopeIndex.end() ? nullptr : &scopes[it->second];
}

/// The scope a variable is filed under: the `dbg.scope` it names, else the
/// hardware module it sits in.
ScopeRecord *UhdiEmitter::ownerScope(debug::VariableOp var) {
  if (auto scope = var.getScope())
    if (auto *def = scope.getDefiningOp())
      if (auto it = scopeOfOp.find(def); it != scopeOfOp.end())
        return &scopes[it->second];
  if (auto mod = var->getParentOfType<hw::HWModuleOp>())
    return findScope(mod.getNameAttr().getValue());
  if (auto mod = var->getParentOfType<hw::HWModuleExternOp>())
    return findScope(mod.getNameAttr().getValue());
  return nullptr;
}

/// Container of an inline scope: the scope it nests in, else the hardware
/// module it sits in. Naming the module for a nested scope would flatten a
/// hierarchy the IR keeps nested, since inlining a module that was itself
/// inlined into leaves one scope per level.
std::optional<unsigned> UhdiEmitter::containerOf(debug::ScopeOp scope) {
  if (auto parent = scope.getScope())
    if (auto *def = parent.getDefiningOp())
      if (auto it = scopeOfOp.find(def); it != scopeOfOp.end())
        return it->second;
  if (auto module = scope->getParentOfType<hw::HWModuleOp>())
    if (auto it = scopeIndex.find(module.getNameAttr().getValue());
        it != scopeIndex.end())
      return it->second;
  return std::nullopt;
}

/// Names of the instances in a module, including the ones inlining replaced
/// with a `dbg.scope`.
const llvm::StringSet<> &UhdiEmitter::instanceNames(hw::HWModuleOp mod) {
  static const llvm::StringSet<> none;
  if (!mod)
    return none;
  auto [it, inserted] = instanceNamesByMod.try_emplace(mod);
  if (inserted)
    mod.walk([&](Operation *op) {
      if (auto inst = dyn_cast<hw::InstanceOp>(op))
        it->second.insert(inst.getInstanceName());
      else if (auto scope = dyn_cast<debug::ScopeOp>(op))
        it->second.insert(scope.getInstanceName());
    });
  return it->second;
}

//===----------------------------------------------------------------------===//
// Value bindings
//===----------------------------------------------------------------------===//

static std::optional<llvm::json::Value> leafBinding(mlir::Value value,
                                                    bool exprs);

/// HGLDD's spelling of a combinational op, empty if it has none.
static StringRef exprOpcode(Operation *op) {
  return TypeSwitch<Operation *, StringRef>(op)
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
      .Case<comb::ConcatOp>([](auto) { return "{}"; })
      .Case<comb::ReplicateOp>([](auto) { return "R{}"; })
      .Case<comb::ExtractOp>([](auto) { return "[]"; })
      .Case<comb::MuxOp>([](auto) { return "?:"; })
      .Case<comb::ICmpOp>([](auto cmpOp) -> StringRef {
        switch (cmpOp.getPredicate()) {
        case comb::ICmpPredicate::eq:
          return "==";
        case comb::ICmpPredicate::ne:
          return "!=";
        case comb::ICmpPredicate::ceq:
          return "===";
        case comb::ICmpPredicate::cne:
          return "!==";
        case comb::ICmpPredicate::weq:
          return "==?";
        case comb::ICmpPredicate::wne:
          return "!=?";
        case comb::ICmpPredicate::ult:
        case comb::ICmpPredicate::slt:
          return "<";
        case comb::ICmpPredicate::ugt:
        case comb::ICmpPredicate::sgt:
          return ">";
        case comb::ICmpPredicate::ule:
        case comb::ICmpPredicate::sle:
          return "<=";
        case comb::ICmpPredicate::uge:
        case comb::ICmpPredicate::sge:
          return ">=";
        }
        return {};
      })
      .Default([](auto) { return ""; });
}

/// Whether `a` and `b` compute the same value: the same value, reads of the
/// same signal, or the same op over such operands. Lowering of a register
/// read clones the op per user, so the debug value and the port it drives can
/// be distinct but equal ops.
static bool sameValue(mlir::Value a, mlir::Value b) {
  if (a == b)
    return true;
  auto *opA = a.getDefiningOp(), *opB = b.getDefiningOp();
  if (!opA || !opB || opA->getName() != opB->getName() ||
      opA->getAttrDictionary() != opB->getAttrDictionary() ||
      opA->getResultTypes() != opB->getResultTypes() ||
      opA->getNumOperands() != opB->getNumOperands() || opA->getNumRegions() ||
      opB->getNumRegions())
    return false;
  if (isa<sv::ReadInOutOp>(opA))
    return opA->getOperand(0) == opB->getOperand(0);
  if (!isa<comb::CombDialect>(opA->getDialect()))
    return false;
  return llvm::all_of(llvm::zip(opA->getOperands(), opB->getOperands()),
                      [](auto pair) {
                        return sameValue(std::get<0>(pair), std::get<1>(pair));
                      });
}

/// The output port a value drives (`assign o = ~r;`), if any. Such a value
/// has no wire of its own, but the port carries it.
static StringAttr drivenOutputName(mlir::Value value) {
  auto mod = value.getParentRegion()->getParentOfType<hw::HWModuleOp>();
  if (!mod)
    return {};
  auto out = cast<hw::OutputOp>(mod.getBodyBlock()->getTerminator());
  for (auto [i, operand] : llvm::enumerate(out.getOperands()))
    if (sameValue(value, operand))
      return mod.getOutputNameAttr(i);
  return {};
}

/// A value that no signal carries, as the combinational op over signals and
/// literals that computes it: `{$op, args}`, with a `$` so that it never reads
/// as a struct member. `R{}` takes the count first and `[]` takes the high and
/// low bit last, as plain numbers. As in Verilog, the operands of a signed op
/// are wrapped in `$signed`.
static std::optional<llvm::json::Value> exprBinding(mlir::Value value) {
  auto *op = value.getDefiningOp();
  if (!op)
    return std::nullopt;
  StringRef opcode = exprOpcode(op);
  if (opcode.empty())
    return std::nullopt;
  bool isSigned = isa<comb::DivSOp, comb::ModSOp, comb::ShrSOp>(op);
  if (auto cmp = dyn_cast<comb::ICmpOp>(op))
    isSigned = comb::ICmpOp::isPredicateSigned(cmp.getPredicate());
  Array args;
  if (auto rep = dyn_cast<comb::ReplicateOp>(op))
    args.push_back(static_cast<int64_t>(rep.getMultiple()));
  for (auto operand : op->getOperands()) {
    std::optional<llvm::json::Value> arg;
    // Nothing else gives a literal operand its width.
    if (auto constant = operand.getDefiningOp<hw::ConstantOp>())
      arg = renderBits(constant.getValue());
    else
      arg = leafBinding(operand, /*exprs=*/true);
    if (!arg)
      return std::nullopt;
    if (isSigned)
      arg = Object{{"$op", "$signed"}, {"args", Array{std::move(*arg)}}};
    args.push_back(std::move(*arg));
  }
  if (auto extract = dyn_cast<comb::ExtractOp>(op)) {
    unsigned low = extract.getLowBit();
    args.push_back(static_cast<int64_t>(
        low + extract.getType().getIntOrFloatBitWidth() - 1));
    args.push_back(static_cast<int64_t>(low));
  }
  return llvm::json::Value(Object{{"$op", opcode}, {"args", std::move(args)}});
}

/// Simulation-side binding of a leaf: the signal it lowered to, or the literal
/// it was folded into. With `exprs`, a value tied to neither can still be an
/// expression over them; else it has no binding at all.
static std::optional<llvm::json::Value> leafBinding(mlir::Value value,
                                                    bool exprs) {
  mlir::Value hwVal = unwrapToHwValue(value);
  if (auto vname = resolveBundleFieldName(hwVal))
    return llvm::json::Value(vname.getValue().str());
  if (auto opR = dyn_cast<OpResult>(hwVal);
      opR && isa<hw::ConstantOp>(opR.getOwner()))
    return llvm::json::Value(
        renderConstant(cast<hw::ConstantOp>(opR.getOwner()).getValue()));
  if (!exprs)
    return std::nullopt;
  if (auto port = drivenOutputName(hwVal))
    return llvm::json::Value(port.getValue().str());
  return exprBinding(hwVal);
}

/// Record `binding`'s signal as covered by an aggregate, so a port record
/// describing the same signal is recognised as a duplicate.
static void noteLeafSignal(const llvm::json::Value &binding,
                           ScopeRecord &scope) {
  if (auto s = binding.getAsString())
    scope.aggregateLeaves.insert(*s);
}

/// Flatten an aggregate's value tree into `out`, keyed by dotted member path
/// (struct-member names and array indices joined with '.'), one entry per leaf
/// that has a value.
void UhdiEmitter::walkAggregate(mlir::Value aggregate, const Twine &prefix,
                                Object &out, ScopeRecord &scope) {
  auto visit = [&](StringRef segment, mlir::Value field) {
    std::string path = prefix.isTriviallyEmpty()
                           ? segment.str()
                           : (prefix + "." + segment).str();
    // Unwrap one dbg.value layer to reach the member's value; its
    // source-language type is interned with the enclosing aggregate.
    debug::ValueOp vw = findDbgValue(field);
    mlir::Value inner = vw ? vw.getValue() : field;
    if (isa_and_nonnull<debug::StructOp, debug::ArrayOp>(
            inner.getDefiningOp())) {
      walkAggregate(inner, path, out, scope);
      return;
    }
    if (auto binding = leafBinding(inner, options.format == 2)) {
      noteLeafSignal(*binding, scope);
      out[path] = std::move(*binding);
    }
  };

  Operation *op = aggregate.getDefiningOp();
  if (auto st = dyn_cast_or_null<debug::StructOp>(op)) {
    for (auto [nameAttr, field] : llvm::zip(st.getNames(), st.getFields()))
      visit(cast<StringAttr>(nameAttr).getValue(), field);
  } else if (auto ar = dyn_cast_or_null<debug::ArrayOp>(op)) {
    for (auto [idx, field] : llvm::enumerate(ar.getElements()))
      visit(std::to_string(idx), field);
  }
}

/// Binding of one member: a dotted-path map when it is itself an aggregate, a
/// scalar binding otherwise.
std::optional<llvm::json::Value>
UhdiEmitter::memberBinding(mlir::Value field, ScopeRecord &scope) {
  debug::ValueOp vw = findDbgValue(field);
  mlir::Value inner = vw ? vw.getValue() : field;
  if (isa_and_nonnull<debug::StructOp, debug::ArrayOp>(inner.getDefiningOp())) {
    Object members;
    walkAggregate(inner, Twine(), members, scope);
    if (members.empty())
      return std::nullopt;
    return llvm::json::Value(std::move(members));
  }
  auto binding = leafBinding(inner, options.format == 2);
  if (binding)
    noteLeafSignal(*binding, scope);
  return binding;
}

//===----------------------------------------------------------------------===//
// Variables
//===----------------------------------------------------------------------===//

VarRecord UhdiEmitter::collectVariable(debug::VariableOp var, EmitState &s,
                                       ScopeRecord &scope) {
  VarRecord rec;
  rec.name = var.getName().str();
  if (auto origin = var->getAttrOfType<StringAttr>(kDbgOriginAttr))
    rec.origin = origin.getValue();
  if (auto port = var->getAttrOfType<StringAttr>(debug::kDbgPortAttr))
    rec.portDirection = port.getValue();

  // Root-level source-language metadata rides on a `dbg.value` wrapper of the
  // variable's operand; unwrap it once and use the wrapped value for all
  // structural checks (aggregate / port / constant detection).
  debug::ValueOp rootMeta = findDbgValue(var.getValue());
  mlir::Value rootVal = unwrapDbgValue(var.getValue());
  // Hint nested struct/array ids with `<Module>_<var>[_field]...` to
  // match HGLDD's naming so the canonical diff stays name-equal.
  bool isAggregate =
      isa_and_nonnull<debug::StructOp, debug::ArrayOp>(rootVal.getDefiningOp());
  std::string structHint;
  if (isAggregate) {
    if (auto mod = var->getParentOfType<hw::HWModuleOp>())
      structHint = (mod.getNameAttr().getValue() + "_" + var.getName()).str();
    else
      structHint = var.getName().str();
  }
  // typeRef: a `dbg.enum`-valued dbg.variable resolves to the enum type-pool
  // entry inside internValueType; otherwise the value's own type (or aggregate
  // structure) wins.
  SourceType src;
  if (rootMeta) {
    rec.sourceTypeName = rootMeta.getTypeNameAttr();
    if (rec.sourceTypeName)
      src.name = splitSourceTypeName(rec.sourceTypeName.getValue()).second;
    src.params = rootMeta.getParamsAttr();
    rec.sourceParams = renderTypeSourceParams(src.params);
  }
  // A struct variable named after an instance of this module is the view of
  // that instance's ports MaterializeDebugInfo adds, so the signals crossing
  // the boundary have a name on this side. It is not a declaration the user
  // wrote, and a consumer must not present it as one. An inlined instance
  // leaves its `dbg.scope` behind, so that name counts too. The view has no
  // type of its own: the instance record it becomes only names signals.
  rec.isInstanceView =
      isa_and_nonnull<debug::StructOp>(rootVal.getDefiningOp()) &&
      instanceNames(var->getParentOfType<hw::HWModuleOp>())
          .contains(var.getName());
  if (!rec.isInstanceView)
    rec.typeRef =
        types.internValueType(rootVal, structHint, src, types.groundOf(var, 0));

  // A port is the variable named after it. Where the value sits is not
  // enough: `node alias = a` shares the input's block argument at -O=release
  // and reaches hw.output through its own wire at -O=debug, and `alias` is a
  // node either way. A frontend binding other than IO settles it outright.
  // A variable filed under a `dbg.scope` belongs to an inlined instance; its
  // ports are plain variables now, even one named like the port it reads.
  bool isInput = false;
  bool isOutput = false;
  StringRef outputPortName;
  StringRef binding;
  if (rec.sourceTypeName)
    binding = splitSourceTypeName(rec.sourceTypeName.getValue()).first;
  auto mod = var->getParentOfType<hw::HWModuleOp>();
  if (mod && !var.getScope() && (binding.empty() || binding == "IO")) {
    auto modType = mod.getHWModuleType();
    Value hwVal = unwrapToHwValue(rootVal);
    if (auto blockArg = dyn_cast<BlockArgument>(hwVal))
      if (isa<hw::HWModuleOp>(blockArg.getOwner()->getParentOp())) {
        unsigned id = modType.getPortIdForInputId(blockArg.getArgNumber());
        if (modType.getPortName(id) == var.getName()) {
          isInput = true;
          rec.portIndex = id;
        }
      }
    // `assign b = a` leaves the output port sharing its value with the input
    // driving it; the name picks the port either way.
    std::optional<unsigned> outId = resolveAsOutputPortId(hwVal);
    if (!outId)
      outId = resolveAsDirectOutputPortId(hwVal, var.getName(), mod);
    if (outId) {
      unsigned id = modType.getPortIdForOutputId(*outId);
      if (modType.getPortName(id) == var.getName()) {
        isInput = false;
        isOutput = true;
        rec.portIndex = id;
        outputPortName = var.getName();
      }
    }
  }
  rec.isPort = !rec.isInstanceView && (isInput || isOutput);
  if (isInput)
    rec.direction = "input";
  else if (isOutput)
    rec.direction = "output";

  rec.sourceLoc = s.chiselLoc(var.getLoc());
  std::optional<Object> hdlLoc = s.verilogLoc(var.getLoc());

  if (rec.isInstanceView) {
    // The ports of the instance, one entry each; the instance record picks
    // these up, since the instance -- not the parent -- declares them. Their
    // signals are the parent's own ports and wires, not leaves of a parent
    // aggregate, so they are noted on a scratch scope: otherwise the
    // parent's `clock` would be dropped as a duplicate of `alu.clock`.
    ScopeRecord scratch{};
    if (auto st = dyn_cast_or_null<debug::StructOp>(rootVal.getDefiningOp()))
      for (auto [nameAttr, field] : llvm::zip(st.getNames(), st.getFields()))
        if (auto binding = memberBinding(field, scratch))
          rec.instanceTarget[cast<StringAttr>(nameAttr).getValue()] =
              std::move(*binding);
    return rec;
  }

  if (isAggregate) {
    Object members;
    walkAggregate(rootVal, Twine(), members, scope);
    if (!members.empty()) {
      rec.target = llvm::json::Value(std::move(members));
      rec.targetLoc = std::move(hdlLoc);
    }
    return rec;
  }

  if (!outputPortName.empty()) {
    // Bind to the port itself, not to the signal that happens to drive it.
    rec.scalarSignal = outputPortName.str();
  } else if (auto opResult = dyn_cast<OpResult>(rootVal);
             opResult && isa_and_nonnull<hw::ConstantOp>(opResult.getOwner())) {
    // A literal carries no location of its own to combine with.
    rec.target = llvm::json::Value(
        renderConstant(cast<hw::ConstantOp>(opResult.getOwner()).getValue()));
    return rec;
  } else if (auto vname = sv::resolveVerilogName(unwrapToHwValue(rootVal))) {
    rec.scalarSignal = vname.getValue().str();
  }
  if (!rec.scalarSignal.empty()) {
    if (hdlLoc)
      rec.target = llvm::json::Value(
          Object{{"signal", rec.scalarSignal}, {"loc", std::move(*hdlLoc)}});
    else
      rec.target = llvm::json::Value(rec.scalarSignal);
  } else if (options.format == 2) {
    if (auto port = drivenOutputName(unwrapToHwValue(rootVal)))
      rec.target = llvm::json::Value(port.getValue().str());
    else
      rec.target = exprBinding(unwrapToHwValue(rootVal));
  }
  return rec;
}

/// Fill in port entries for ports that lack a `dbg.variable` cover
/// (e.g. firtool-emitted SRAM macros, or hand-written hw.module fixtures
/// with no MaterializeDebugInfo run). Per-port — modules that already
/// have dbg.variables for *some* of their ports still get synthesized
/// entries for the *uncovered* ports, so partial coverage doesn't read
/// as full coverage. Both directions bind to the port-name signal so
/// VCD/Tywaves can lock onto it.
void UhdiEmitter::synthesizePortVars(
    hw::HWModuleOp mod, ScopeRecord &scope,
    const llvm::DenseSet<unsigned> &coveredPortIndices) {
  auto modType = mod.getModuleType();
  for (size_t i = 0, e = modType.getNumPorts(); i < e; ++i) {
    if (coveredPortIndices.contains(i))
      continue;
    StringRef portName = modType.getPortName(i);
    if (portName.empty())
      continue;
    VarRecord rec;
    rec.name = portName.str();
    rec.typeRef = types.internType(modType.getPorts()[i].type, mod.getLoc());
    rec.direction = modType.isOutput(i) ? "output" : "input";
    rec.portDirection = modType.isOutput(i) ? "out" : "in";
    rec.isPort = true;
    rec.synthesized = true;
    rec.scalarSignal = portName.str();
    rec.target = llvm::json::Value(rec.scalarSignal);
    scope.vars.push_back(std::move(rec));
  }
}

Object UhdiEmitter::buildVariableEntry(VarRecord &var) {
  Object entry;
  entry["typeRef"] = types.resolve(var.typeRef);
  if (!var.direction.empty())
    entry["direction"] = var.direction.str();

  Object source;
  // The key already carries the name unless a collision forced it aside.
  if (!var.name.empty() && var.key != var.name)
    source["name"] = var.name;
  // Only the declaration half stays on the variable: the type half names the
  // pool entry `typeRef` points at, so `binding[types[typeRef].source.name]`
  // reconstructs what the frontend spelled.
  if (var.sourceTypeName) {
    StringRef binding =
        splitSourceTypeName(var.sourceTypeName.getValue()).first;
    if (!binding.empty())
      sourceExt(source)["binding"] = binding.str();
  }
  if (!var.sourceParams.empty())
    sourceExt(source)["params"] = std::move(var.sourceParams);
  if (var.sourceLoc)
    source["loc"] = std::move(*var.sourceLoc);
  entry["source"] = std::move(source);

  if (var.target) {
    Object target{{"verilog", std::move(*var.target)}};
    if (var.targetLoc)
      target["loc"] = std::move(*var.targetLoc);
    entry["target"] = std::move(target);
  }
  return entry;
}

void UhdiEmitter::finalizeVariables() {
  for (auto &scope : scopes) {
    // An instance view describes the instance, not the parent: move it onto the
    // instance it names. Without one -- an inlined module leaves the view
    // behind but no instance -- the scope's own variables already carry the
    // same bindings, so it just goes.
    for (auto &var : scope.vars) {
      if (!var.isInstanceView)
        continue;
      var.dropped = true;
      if (var.instanceTarget.empty())
        continue;
      for (auto &inst : scope.instances)
        if (inst.as == var.name) {
          inst.verilogTarget = std::move(var.instanceTarget);
          break;
        }
    }
    // A port whose signal is already a leaf of an aggregate variable here is
    // the same port twice; the aggregate is the one the user declared.
    for (auto &var : scope.vars)
      if (var.isPort && !var.scalarSignal.empty() &&
          scope.aggregateLeaves.contains(var.scalarSignal))
        var.dropped = true;

    // The key is the source name. Two declarations wanting one name are told
    // apart by a counter on the later ones, whose `source.name` then carries
    // the name.
    llvm::StringMap<unsigned> seen;
    for (auto &var : scope.vars) {
      if (var.dropped)
        continue;
      unsigned n = seen[var.name]++;
      var.key = n == 0 ? var.name : (var.name + "." + Twine(n)).str();
      var.entry = buildVariableEntry(var);
    }

    // Every map in the document is emitted in key order, so two runs that
    // differ only in what the IR walk happened to reach first still diff
    // cleanly.
    llvm::sort(scope.vars, [](const VarRecord &a, const VarRecord &b) {
      return a.key < b.key;
    });
    llvm::sort(scope.instances,
               [](const InstanceRecord &a, const InstanceRecord &b) {
                 return a.as < b.as;
               });
  }

  llvm::sort(topLevelScopes, [&](unsigned a, unsigned b) {
    return scopes[a].id < scopes[b].id;
  });
}

//===----------------------------------------------------------------------===//
// Scopes
//===----------------------------------------------------------------------===//

void UhdiEmitter::collectModule(hw::HWModuleOp module, EmitState &s) {
  StringRef sym = module.getNameAttr().getValue();
  ScopeRecord &scope = addScope(sym, "module");
  scope.op = module;
  if (auto typeName = moduleSourceTypeName(module))
    sourceExt(scope.source)["typeName"] = typeName.getValue().str();
  if (Array params = moduleSourceParams(module); !params.empty())
    sourceExt(scope.source)["params"] = std::move(params);
  if (auto loc = s.chiselLoc(module.getLoc()))
    scope.source["loc"] = std::move(*loc);
  // The key is the source name; `target.name` is only there when the Verilog
  // backend renamed the module.
  if (StringRef vn = verilogModuleName(module); vn != sym)
    scope.target["name"] = vn.str();
  if (auto loc = s.verilogLoc(module.getLoc()))
    scope.target["loc"] = std::move(*loc);

  module.walk([&](hw::InstanceOp inst) {
    InstanceRecord rec;
    rec.as = inst.getInstanceName().str();
    rec.moduleRef = inst.getModuleName().str();
    if (auto origin = inst->getAttrOfType<StringAttr>(kDbgOriginAttr))
      rec.origin = origin.getValue().str();
    if (auto typeName = moduleSourceTypeName(inst))
      sourceExt(rec.source)["typeName"] = typeName.getValue().str();
    if (Array params = moduleSourceParams(inst); !params.empty())
      sourceExt(rec.source)["params"] = std::move(params);
    if (auto loc = s.chiselLoc(inst.getLoc()))
      rec.source["loc"] = std::move(*loc);
    // PrettifyVerilogNames may rename the instance; record only when it
    // diverges from the source-level instanceName.
    if (auto vn = inst->getAttrOfType<StringAttr>("hw.verilogName");
        vn && vn.getValue() != inst.getInstanceName())
      rec.target["name"] = vn.getValue().str();
    if (auto loc = s.verilogLoc(inst.getLoc()))
      rec.target["loc"] = std::move(*loc);
    scope.instances.push_back(std::move(rec));
  });
}

void UhdiEmitter::collectInlineScope(debug::ScopeOp scope, EmitState &s) {
  scopeOfOp[scope] = scopes.size();
  ScopeRecord &rec =
      addScope(("inline#" + Twine(scopes.size())).str(), "inline");
  rec.op = scope;
  if (!scope.getInstanceName().empty())
    rec.source["name"] = scope.getInstanceName().str();
  if (auto typeName = moduleSourceTypeName(scope))
    sourceExt(rec.source)["typeName"] = typeName.getValue().str();
  if (Array params = moduleSourceParams(scope); !params.empty())
    sourceExt(rec.source)["params"] = std::move(params);
  if (auto loc = s.chiselLoc(scope.getLoc()))
    rec.source["loc"] = std::move(*loc);
}

void UhdiEmitter::collect(mlir::ModuleOp top) {
  EmitState s = state();

  // Seed the HDL file list with the netlist this document describes, so it is
  // named even when nothing in the IR carries an emitted location.
  verilogFiles.internIfNamed(options.verilogFileName);

  // 1. Module / extmodule entries.
  for (auto &op : top.getOps()) {
    if (auto mod = dyn_cast<hw::HWModuleOp>(op)) {
      collectModule(mod, s);
      topLevelScopes.push_back(scopeIndex[mod.getNameAttr().getValue()]);
    } else if (auto ext = dyn_cast<hw::HWModuleExternOp>(op)) {
      ScopeRecord &scope = addScope(ext.getNameAttr().getValue(), "extmodule");
      scope.op = ext;
      if (StringRef vn = verilogModuleName(ext); vn != scope.id)
        scope.target["name"] = vn.str();
      topLevelScopes.push_back(scopeIndex[ext.getNameAttr().getValue()]);
    }
  }

  // 2. Inline scopes, so a variable can be filed under one straight away. A
  // scope references its container through an SSA operand, which dominance puts
  // ahead of it, so one pass in walk order is enough to nest them.
  // Layout 1 has no place for the modules dedup merged away, so it leaves out
  // the debug ops dedup moved out of them (`dbg.origin` on the root ops), as
  // if they had been erased with their module.
  llvm::DenseSet<Operation *> mergedScopes;
  auto isMerged = [&](Operation *op, Value parent) {
    if (options.format != 1)
      return false;
    if (op->hasAttr(kDbgOriginAttr))
      return true;
    return parent && mergedScopes.contains(parent.getDefiningOp());
  };
  SmallVector<std::pair<unsigned, std::optional<unsigned>>> inlineContainers;
  top.walk([&](debug::ScopeOp scope) {
    if (isMerged(scope, scope.getScope())) {
      mergedScopes.insert(scope);
      return;
    }
    collectInlineScope(scope, s);
    inlineContainers.emplace_back(scopes.size() - 1, containerOf(scope));
  });
  for (auto [index, container] : inlineContainers)
    if (container)
      scopes[*container].childScopes.push_back(index);

  // 3. One whole-circuit walk that collects variables AND the per-module port
  // coverage step 4 consumes — so step 4 doesn't re-walk.
  llvm::DenseMap<hw::HWModuleOp, llvm::DenseSet<unsigned>> coveredPortsByMod;
  top.walk([&](debug::VariableOp var) {
    if (isMerged(var, var.getScope()))
      return;
    ScopeRecord *scope = ownerScope(var);
    if (!scope)
      return;
    VarRecord rec = collectVariable(var, s, *scope);
    // The port a variable stands for needs no synthesized record.
    if (rec.portIndex)
      if (auto mod = var->getParentOfType<hw::HWModuleOp>())
        coveredPortsByMod[mod].insert(*rec.portIndex);
    scope->vars.push_back(std::move(rec));
  });

  // 4. Synthesized port entries for ports with no dbg.variable coverage.
  for (auto mod : top.getOps<hw::HWModuleOp>())
    if (auto *scope = findScope(mod.getNameAttr().getValue()))
      synthesizePortVars(mod, *scope, coveredPortsByMod[mod]);

  types.finalizeIds();
  finalizeVariables();
}

//===----------------------------------------------------------------------===//
// Rendering
//===----------------------------------------------------------------------===//

void UhdiEmitter::renderScope(llvm::json::OStream &j, unsigned index) {
  ScopeRecord &scope = scopes[index];
  j.objectBegin();
  if (scope.kind != "module")
    j.attribute("kind", scope.kind.str());
  if (!scope.source.empty())
    j.attribute("source", std::move(scope.source));
  if (!scope.target.empty())
    j.attribute("target", std::move(scope.target));

  j.attributeBegin("variables");
  j.objectBegin();
  for (auto &var : scope.vars) {
    if (var.dropped)
      continue;
    j.attributeBegin(var.key);
    j.value(std::move(var.entry));
    j.attributeEnd();
  }
  j.objectEnd();
  j.attributeEnd();

  if (!scope.instances.empty()) {
    j.attributeBegin("instances");
    j.objectBegin();
    for (auto &inst : scope.instances) {
      Object entry{{"moduleRef", inst.moduleRef}};
      if (!inst.source.empty())
        entry["source"] = std::move(inst.source);
      Object target = std::move(inst.target);
      if (!inst.verilogTarget.empty())
        target["verilog"] = std::move(inst.verilogTarget);
      if (!target.empty())
        entry["target"] = std::move(target);
      j.attributeBegin(inst.as);
      j.value(std::move(entry));
      j.attributeEnd();
    }
    j.objectEnd();
    j.attributeEnd();
  }

  if (!scope.childScopes.empty()) {
    j.attributeBegin("scopes");
    j.arrayBegin();
    for (unsigned child : scope.childScopes)
      renderScope(j, child);
    j.arrayEnd();
    j.attributeEnd();
  }
  j.objectEnd();
}

//===----------------------------------------------------------------------===//
// Layout 2: source / target / bindings
//===----------------------------------------------------------------------===//

/// `[file, line, column]` of a layout-1 location object, its file index moved
/// by `fileOffset` into the single file list.
static std::optional<Array> locTuple(const Object *loc,
                                     int64_t fileOffset = 0) {
  if (!loc)
    return std::nullopt;
  auto line = loc->getInteger("beginLine");
  if (!line)
    return std::nullopt;
  return Array{*loc->getInteger("file") + fileOffset, *line,
               loc->getInteger("beginColumn").value_or(0)};
}

/// `x-chisel` of a `dbg.moduleinfo` record: class name and constructor params.
static Object moduleInfoExt(DictionaryAttr moduleInfo) {
  Object ext;
  if (!moduleInfo)
    return ext;
  if (auto typeName = moduleInfo.getAs<StringAttr>("typeName"))
    ext["typeName"] = typeName.getValue().str();
  if (Array params =
          renderTypeSourceParams(moduleInfo.getAs<ArrayAttr>("params"));
      !params.empty())
    ext["params"] = std::move(params);
  return ext;
}

/// The pool in layout 2: `fields` / `elem` / `base` / `values` and the source
/// name next to the kind instead of under `source`.
static Object layoutTypes(const Object &pool) {
  Object out;
  for (auto &[id, value] : pool) {
    const Object &t = *value.getAsObject();
    StringRef kind = t.getString("kind").value_or("");
    const Object *src = t.getObject("source");
    std::optional<StringRef> name;
    if (src)
      name = src->getString("name");
    Object n{{"kind", kind}};
    if (kind == "uint" || kind == "sint")
      n["width"] = *t.get("width");
    if (kind == "struct") {
      Array fields;
      for (auto &m : *t.getArray("members")) {
        const Object &member = *m.getAsObject();
        Object field{{"name", *member.get("name")},
                     {"type", *member.get("typeRef")}};
        if (member.getBoolean("flipped").value_or(false))
          field["flip"] = true;
        fields.push_back(std::move(field));
      }
      n["fields"] = std::move(fields);
    }
    if (kind == "vector") {
      n["elem"] = *t.get("elementRef");
      n["size"] = *t.get("size");
    }
    if (kind == "enum") {
      n["base"] = *t.get("underlyingTypeRef");
      Object values;
      for (auto &[number, label] : *t.getObject("variants")) {
        int64_t v;
        if (StringRef(number).getAsInteger(10, v))
          values[*label.getAsString()] = StringRef(number).str();
        else
          values[*label.getAsString()] = v;
      }
      n["values"] = std::move(values);
    }
    if (name)
      n["name"] = *name;
    if (src)
      if (auto *ext = src->get("x-chisel"))
        n["x-chisel"] = *ext;
    out[id] = std::move(n);
  }
  return out;
}

static llvm::json::Value noValue() { return Object{{"$none", "optimized"}}; }

/// Bit width of a leaf of pool type `typeId`; an enum has its base's.
static unsigned leafWidth(const Object &pool, StringRef typeId) {
  const Object *t = pool.getObject(typeId);
  if (!t)
    return 0;
  if (auto base = t->getString("underlyingTypeRef"))
    return leafWidth(pool, *base);
  return t->getInteger("width").value_or(0);
}

/// A leaf binding of layout 1 (signal, `{signal, loc}` or literal) as a
/// layout-2 value. A literal is always a bit string, `width` bits long.
static llvm::json::Value leafValue(const llvm::json::Value &binding,
                                   unsigned width = 0) {
  if (auto s = binding.getAsString())
    return *s;
  const Object &o = *binding.getAsObject();
  if (auto s = o.getString("signal"))
    return *s;
  if (auto c = o.getInteger("constant")) {
    llvm::APInt value(64, *c);
    return leafValue(
        renderBits(value.zextOrTrunc(std::max(width, value.getActiveBits()))));
  }
  if (auto b = o.getString("bitVector"))
    return Object{{"$const", ("0b" + *b).str()}};
  if (auto op = o.getString("$op")) {
    Array args;
    for (auto &arg : *o.getArray("args"))
      args.push_back(arg.getAsInteger() ? arg : leafValue(arg));
    return Object{{"$op", *op}, {"args", std::move(args)}};
  }
  return binding;
}

/// Whether a layout-2 value holds an expression anywhere inside.
static bool hasExpr(const llvm::json::Value &value) {
  if (auto *arr = value.getAsArray())
    return llvm::any_of(*arr, hasExpr);
  if (auto *obj = value.getAsObject())
    return obj->get("$op") ||
           llvm::any_of(*obj, [](auto &kv) { return hasExpr(kv.second); });
  return false;
}

static bool isLeafBinding(const llvm::json::Value &binding) {
  const Object *o = binding.getAsObject();
  return !o || o->get("signal") || o->get("constant") || o->get("bitVector") ||
         o->get("$op");
}

/// Rebuild the value of an aggregate from the dotted-path map of layout 1,
/// shaped by its type: an object per struct, an array per vector, with a hole
/// in a vector marked as having no value. Null when nothing below has a value.
static std::optional<llvm::json::Value>
aggregateValue(const Object &pool, StringRef typeId, const Object &paths,
               const std::string &path) {
  auto child = [&](const Twine &segment) {
    return path.empty() ? segment.str() : (Twine(path) + "." + segment).str();
  };
  const Object *t = pool.getObject(typeId);
  StringRef kind = t ? t->getString("kind").value_or("") : "";
  if (kind == "struct") {
    Object out;
    for (auto &m : *t->getArray("members")) {
      const Object &member = *m.getAsObject();
      StringRef name = *member.getString("name");
      if (auto v = aggregateValue(pool, *member.getString("typeRef"), paths,
                                  child(name)))
        out[name] = std::move(*v);
    }
    if (out.empty())
      return std::nullopt;
    return llvm::json::Value(std::move(out));
  }
  if (kind == "vector") {
    Array out;
    bool any = false;
    for (int64_t i = 0, e = t->getInteger("size").value_or(0); i < e; ++i) {
      auto v = aggregateValue(pool, *t->getString("elementRef"), paths,
                              child(Twine(i)));
      any |= v.has_value();
      out.push_back(v ? std::move(*v) : noValue());
    }
    if (!any)
      return std::nullopt;
    return llvm::json::Value(std::move(out));
  }
  if (auto *leaf = paths.get(path))
    return leafValue(*leaf, leafWidth(pool, typeId));
  return std::nullopt;
}

/// Port names LowerTypes makes out of the leaves of an aggregate of `typeId`.
static void aggregateLeafNames(const Object &pool, StringRef typeId,
                               const std::string &prefix,
                               llvm::StringSet<> &out) {
  const Object *t = pool.getObject(typeId);
  StringRef kind = t ? t->getString("kind").value_or("") : "";
  if (kind == "struct") {
    for (auto &m : *t->getArray("members")) {
      const Object &member = *m.getAsObject();
      aggregateLeafNames(pool, *member.getString("typeRef"),
                         prefix + member.getString("name")->str() + "_", out);
    }
  } else if (kind == "vector") {
    for (int64_t i = 0, e = t->getInteger("size").value_or(0); i < e; ++i)
      aggregateLeafNames(pool, *t->getString("elementRef"),
                         prefix + std::to_string(i) + "_", out);
  } else if (!prefix.empty()) {
    out.insert(StringRef(prefix).drop_back());
  }
}

/// One entry of `bindings`.
struct BindingRecord {
  BindingRecord(StringRef source, StringRef target, StringRef scope = {})
      : source(source), target(target), scope(scope) {}
  std::string source, target, scope;
  Object vars;
  /// Uses of each variable name, to tell two declarations of one name apart.
  llvm::StringMap<unsigned> names;
};

/// An instance as a variable of the source module that declares it: its type
/// is the module it instantiates as written, and its value names the Verilog
/// instance with its module, or the inline scope it became.
struct InstanceVar {
  std::string source, target, scope;
  std::string name, module;
  std::optional<Array> loc;
  llvm::json::Value value;
};

/// Layout 2 splits what layout 1 nests under `modules`: `source` describes the
/// modules as written, keyed by their name before dedup, with each instance a
/// variable typed by its module; `target` lists the Verilog modules;
/// `bindings` maps the variables of a source module to signals of a target
/// module, at the dotted inline path `scope` when it was inlined. A target
/// that dedup made out of several sources has a binding per source.
void UhdiEmitter::renderLayout2(llvm::json::OStream &j) {
  EmitState s = state();
  // Interning grows the source file list, so it has to settle before the
  // target files are numbered after it.
  for (auto &scope : scopes)
    if (scope.kind == "module")
      if (auto origins =
              scope.op->getAttrOfType<DictionaryAttr>(kDbgOriginsAttr))
        for (auto origin : origins)
          if (auto info = dyn_cast<DictionaryAttr>(origin.getValue()))
            if (auto loc = info.getAs<LocationAttr>("loc"))
              (void)s.chiselLoc(loc);
  int64_t offset = chiselFiles.ordered.size();

  Object pool = types.takeObject();

  llvm::StringMap<std::string> verilogNames;
  for (unsigned index : topLevelScopes) {
    ScopeRecord &scope = scopes[index];
    auto name = scope.target.getString("name");
    verilogNames[scope.id] = name ? name->str() : scope.id;
  }

  // Classes the instances of each module name.
  llvm::StringMap<SmallVector<llvm::json::Value, 1>> instanceClasses;
  for (unsigned index : topLevelScopes)
    for (auto &inst : scopes[index].instances)
      if (auto *ext = inst.source.getObject("x-chisel")) {
        auto &classes = instanceClasses[inst.moduleRef];
        llvm::json::Value cls = Object(*ext);
        if (!llvm::is_contained(classes, cls))
          classes.push_back(std::move(cls));
      }

  std::map<std::string, Object> sources;
  auto sourceEntry = [&](StringRef name) -> Object & {
    Object &entry = sources[name.str()];
    if (!entry.get("vars"))
      entry["vars"] = Object{};
    return entry;
  };

  // Variables of `scope` into `binding` and the source module it binds.
  auto addVar = [&](BindingRecord &binding, VarRecord &var,
                    const llvm::StringSet<> &leaves) {
    const Object &e = var.entry;
    const Object *src = e.getObject("source");
    // A port no `dbg.variable` covers that is only a leaf of an aggregate
    // variable already shown.
    if ((!src || src->empty()) && leaves.contains(var.name))
      return;
    // Keys are counted per source module, so a variable dedup moved here
    // keeps its own name.
    unsigned n = binding.names[var.name]++;
    std::string key = n == 0 ? var.name : (var.name + "." + Twine(n)).str();
    Object v{{"type", *e.get("typeRef")}};
    if (src)
      if (auto loc = locTuple(src->getObject("loc")))
        v["loc"] = std::move(*loc);
    if (!var.portDirection.empty())
      v["dir"] = var.portDirection;
    if (src)
      if (auto *ext = src->getObject("x-chisel"))
        v["x-chisel"] = Object(*ext);
    sourceEntry(binding.source)
        .getObject("vars")
        ->try_emplace(key, std::move(v));

    const Object *target = e.getObject("target");
    const llvm::json::Value *verilog =
        target ? target->get("verilog") : nullptr;
    if (!verilog) {
      binding.vars[key] = noValue();
      return;
    }
    if (isLeafBinding(*verilog)) {
      binding.vars[key] =
          leafValue(*verilog, leafWidth(pool, *e.getString("typeRef")));
      return;
    }
    auto value = aggregateValue(pool, *e.getString("typeRef"),
                                *verilog->getAsObject(), "");
    binding.vars[key] = value ? std::move(*value) : noValue();
  };
  auto leavesOf = [&](ScopeRecord &scope) {
    llvm::StringSet<> leaves;
    for (auto &var : scope.vars)
      if (!var.dropped) {
        StringRef typeId = *var.entry.getString("typeRef");
        if (auto *t = pool.getObject(typeId);
            t && llvm::is_contained({"struct", "vector"},
                                    t->getString("kind").value_or("")))
          aggregateLeafNames(pool, typeId, var.name + "_", leaves);
      }
    return leaves;
  };

  std::vector<BindingRecord> bindings;
  llvm::StringSet<> boundModules;
  Object targets;
  std::vector<InstanceVar> instanceVars;

  // A module the frontend said nothing about, such as a memory lowering made,
  // has no source and lives in the target only, unless it instantiates a
  // source module: that instance is a variable of it.
  llvm::StringSet<> sourceModules;
  for (unsigned index : topLevelScopes) {
    ScopeRecord &scope = scopes[index];
    if (scope.kind == "extmodule" ||
        scope.op->getAttrOfType<DictionaryAttr>(kDbgOriginsAttr) ||
        scope.source.getObject("x-chisel") ||
        instanceClasses.contains(scope.id) || !scope.childScopes.empty() ||
        !llvm::all_of(scope.vars,
                      [](const VarRecord &var) { return var.synthesized; }))
      sourceModules.insert(scope.id);
  }
  for (bool changed = true; changed;) {
    changed = false;
    for (unsigned index : topLevelScopes) {
      ScopeRecord &scope = scopes[index];
      if (!sourceModules.contains(scope.id) &&
          llvm::any_of(scope.instances, [&](const InstanceRecord &inst) {
            return !inst.origin.empty() ||
                   sourceModules.contains(inst.moduleRef);
          }))
        changed = sourceModules.insert(scope.id).second;
    }
  }

  // An inline scope binds the module it inlined, at its path in `target`,
  // and is an instance of each source that declares it.
  std::function<void(unsigned, StringRef, const std::string &,
                     ArrayRef<std::string>)>
      addInline = [&](unsigned index, StringRef target,
                      const std::string &parentPath,
                      ArrayRef<std::string> parents) {
        ScopeRecord &scope = scopes[index];
        auto op = cast<debug::ScopeOp>(scope.op);
        std::string path =
            parentPath.empty()
                ? op.getInstanceName().str()
                : (parentPath + "." + op.getInstanceName()).str();
        for (auto &parent : parents)
          instanceVars.push_back({parent, target.str(), parentPath,
                                  op.getInstanceName().str(),
                                  op.getModuleName().str(),
                                  locTuple(scope.source.getObject("loc")),
                                  Object{{"$inline", path}}});
        BindingRecord binding(op.getModuleName(), target, path);
        Object &entry = sourceEntry(binding.source);
        if (auto *ext = scope.source.getObject("x-chisel");
            ext && !entry.get("x-chisel"))
          entry["x-chisel"] = Object(*ext);
        llvm::StringSet<> leaves = leavesOf(scope);
        for (auto &var : scope.vars)
          if (!var.dropped)
            addVar(binding, var, leaves);
        bindings.push_back(std::move(binding));
        for (unsigned child : scope.childScopes)
          addInline(child, target, path, {op.getModuleName().str()});
      };

  for (unsigned index : topLevelScopes) {
    ScopeRecord &scope = scopes[index];
    StringRef target = verilogNames[scope.id];
    Object module;
    if (auto *loc = scope.target.getObject("loc"))
      module["file"] = *loc->getInteger("file") + offset;
    if (scope.kind == "extmodule") {
      module["kind"] = "extern";
      targets[target] = std::move(module);
      // The frontend declared it, so its instances are variables too; it
      // has nothing inside to bind.
      Object &entry = sourceEntry(scope.id);
      if (auto loc = locTuple(scope.source.getObject("loc")))
        entry["loc"] = std::move(*loc);
      bindings.emplace_back(scope.id, target);
      boundModules.insert(scope.id);
      continue;
    }

    if (!sourceModules.contains(scope.id)) {
      targets[target] = std::move(module);
      continue;
    }
    auto origins = scope.op->getAttrOfType<DictionaryAttr>(kDbgOriginsAttr);

    // The module's own source first, then each one dedup merged into it.
    SmallVector<BindingRecord, 1> own;
    own.emplace_back(scope.id, target);
    auto bindingOf = [&](StringRef source) -> BindingRecord & {
      for (auto &binding : own)
        if (binding.source == source)
          return binding;
      own.emplace_back(source, target);
      return own.back();
    };

    Object &ownEntry = sourceEntry(scope.id);
    if (auto loc = locTuple(scope.source.getObject("loc")))
      ownEntry["loc"] = std::move(*loc);
    SmallVector<llvm::json::Value> originClasses;
    if (origins)
      for (auto origin : origins) {
        bindingOf(origin.getName().getValue());
        Object &entry = sourceEntry(origin.getName().getValue());
        auto info = dyn_cast<DictionaryAttr>(origin.getValue());
        if (!info)
          continue;
        if (auto locAttr = info.getAs<LocationAttr>("loc"))
          if (auto loc = s.chiselLoc(locAttr))
            if (auto at = locTuple(&*loc))
              entry["loc"] = std::move(*at);
        if (Object ext =
                moduleInfoExt(info.getAs<DictionaryAttr>("moduleinfo"));
            !ext.empty()) {
          originClasses.push_back(Object(ext));
          entry["x-chisel"] = std::move(ext);
        }
      }
    // PropagateDebugClassInfo leaves the class on the instances. Those of a
    // deduplicated module name every source merged into it; the one no
    // origin claims is the module's own.
    if (auto *ext = scope.source.getObject("x-chisel")) {
      ownEntry["x-chisel"] = Object(*ext);
    } else {
      auto &classes = instanceClasses[scope.id];
      SmallVector<llvm::json::Value, 1> unclaimed;
      for (auto &cls : classes)
        if (!llvm::is_contained(originClasses, cls))
          unclaimed.push_back(cls);
      if (unclaimed.size() == 1)
        ownEntry["x-chisel"] = unclaimed.front();
      else if (classes.size() == 1)
        ownEntry["x-chisel"] = classes.front();
    }

    llvm::StringSet<> leaves = leavesOf(scope);
    for (auto &var : scope.vars) {
      if (var.dropped)
        continue;
      // A port without a `dbg.variable` belongs to every source alike.
      if (var.synthesized) {
        for (unsigned i = 0, e = own.size(); i != e; ++i)
          addVar(own[i], var, leaves);
        continue;
      }
      addVar(bindingOf(var.origin.empty() ? StringRef(scope.id) : var.origin),
             var, leaves);
    }
    boundModules.insert(scope.id);
    // Every source merged into this module declares what it instantiates.
    SmallVector<std::string> parents;
    for (auto &binding : own)
      parents.push_back(binding.source);
    for (auto &binding : own)
      bindings.push_back(std::move(binding));
    for (unsigned child : scope.childScopes)
      addInline(child, target, "", parents);
    targets[target] = std::move(module);
  }

  // Instances last, once every source is known. Dedup tags an instance with
  // the module it stood for; an untagged one stands for the module it
  // instantiates. One with no source, such as a memory lowering made, is a
  // part of the target only.
  for (unsigned index : topLevelScopes) {
    ScopeRecord &scope = scopes[index];
    StringRef target = verilogNames[scope.id];
    for (auto &inst : scope.instances) {
      StringRef module = !inst.origin.empty() ? StringRef(inst.origin)
                         : boundModules.contains(inst.moduleRef)
                             ? StringRef(inst.moduleRef)
                             : StringRef();
      if (module.empty())
        continue;
      auto name = inst.target.getString("name");
      Object value{{"$inst", name ? name->str() : inst.as},
                   {"module", verilogNames.lookup(inst.moduleRef)}};
      for (auto &binding : bindings)
        if (binding.target == target && binding.scope.empty())
          instanceVars.push_back(
              {binding.source, target.str(), "", inst.as, module.str(),
               locTuple(inst.source.getObject("loc")), Object(value)});
    }
  }

  // An instance is typed by the module it instantiates.
  std::map<std::string, std::string> moduleTypes;
  for (auto &inst : instanceVars) {
    auto [it, inserted] = moduleTypes.try_emplace(inst.module);
    if (!inserted)
      continue;
    std::string id = "module_" + inst.module;
    while (pool.get(id))
      id += "_";
    it->second = id;
  }
  for (auto &inst : instanceVars)
    for (auto &binding : bindings) {
      if (binding.source != inst.source || binding.target != inst.target ||
          binding.scope != inst.scope)
        continue;
      unsigned n = binding.names[inst.name]++;
      std::string key = n == 0 ? inst.name : (inst.name + "." + Twine(n)).str();
      Object v{{"type", moduleTypes[inst.module]}};
      if (inst.loc)
        v["loc"] = Array(*inst.loc);
      sourceEntry(inst.source)
          .getObject("vars")
          ->try_emplace(key, std::move(v));
      binding.vars[key] = inst.value;
      break;
    }

  Array files;
  for (auto &path : chiselFiles.ordered)
    files.push_back(Object{{"path", path}});
  for (auto &path : verilogFiles.ordered)
    files.push_back(Object{{"path", path}, {"target", true}});

  // A port an aggregate covers is dropped after its type was interned, so
  // keep only the types the variables reach.
  Object pool2 = layoutTypes(pool);
  Object liveTypes;
  SmallVector<std::string> work;
  for (auto &[name, entry] : sources)
    for (auto &[key, var] : *entry.getObject("vars"))
      if (auto type = var.getAsObject()->getString("type"))
        work.push_back(type->str());
  while (!work.empty()) {
    std::string key = work.pop_back_val();
    if (liveTypes.get(key))
      continue;
    auto *type = pool2.getObject(key);
    if (!type)
      continue;
    if (auto *fields = type->getArray("fields"))
      for (auto &field : *fields)
        if (auto ref = field.getAsObject()->getString("type"))
          work.push_back(ref->str());
    for (StringRef ref : {"elem", "base"})
      if (auto r = type->getString(ref))
        work.push_back(r->str());
    liveTypes[key] = std::move(*type);
  }
  for (auto &[module, id] : moduleTypes)
    liveTypes[id] = Object{{"kind", "module"}, {"module", module}};

  // Profiles the document uses, and only those.
  std::function<bool(const llvm::json::Value &)> hasChisel =
      [&](const llvm::json::Value &value) {
        if (auto *object = value.getAsObject()) {
          if (object->get("x-chisel"))
            return true;
          for (auto &kv : *object)
            if (hasChisel(kv.second))
              return true;
        } else if (auto *array = value.getAsArray()) {
          for (auto &element : *array)
            if (hasChisel(element))
              return true;
        }
        return false;
      };
  bool usesChisel = hasChisel(llvm::json::Value(Object(liveTypes))) ||
                    hasChisel(llvm::json::Value(Object(targets)));
  for (auto &[name, entry] : sources)
    usesChisel |= hasChisel(llvm::json::Value(Object(entry)));
  Array profiles;
  if (usesChisel)
    profiles.push_back("x-chisel");
  if (llvm::any_of(bindings, [](auto &binding) {
        return llvm::any_of(binding.vars,
                            [](auto &kv) { return hasExpr(kv.second); });
      }))
    profiles.push_back("expr");

  j.object([&] {
    j.attribute("uhdi", kFormatVersion2);
    j.attribute("producer", "firtool");
    j.attribute("profiles", std::move(profiles));
    j.attribute("files", std::move(files));
    j.attribute("types", std::move(liveTypes));
    j.attributeObject("source", [&] {
      for (auto &[name, entry] : sources)
        j.attribute(name, std::move(entry));
    });
    j.attribute("target", std::move(targets));
    j.attributeArray("bindings", [&] {
      for (auto &binding : bindings) {
        Object entry{{"source", binding.source},
                     {"target", binding.target},
                     {"vars", std::move(binding.vars)}};
        if (!binding.scope.empty())
          entry["scope"] = binding.scope;
        j.value(std::move(entry));
      }
    });
  });
}

LogicalResult UhdiEmitter::run(raw_ostream &os) {
  auto top = dyn_cast<mlir::ModuleOp>(root);
  if (!top)
    return root->emitError("EmitUHDI expects a top-level builtin.module");
  collect(top);

  llvm::json::OStream j(os, /*IndentSize=*/2);
  if (options.format == 2) {
    renderLayout2(j);
    os << "\n";
    return success();
  }
  j.object([&] {
    j.attribute("format", Object{{"version", kFormatVersion.str()}});
    j.attribute("source", Object{{"language", "Chisel"},
                                 {"files", chiselFiles.asArray()}});
    j.attribute("target", Object{{"language", "SystemVerilog"},
                                 {"files", verilogFiles.asArray()}});
    j.attribute("types", types.takeObject());
    j.attributeBegin("modules");
    j.objectBegin();
    for (unsigned index : topLevelScopes) {
      j.attributeBegin(scopes[index].id);
      renderScope(j, index);
      j.attributeEnd();
    }
    j.objectEnd();
    j.attributeEnd();
  });
  os << "\n";
  return success();
}

} // namespace

LogicalResult debug::emitUHDI(Operation *module, raw_ostream &os,
                              const EmitUHDIOptions &options) {
  if (options.format != 1 && options.format != 2)
    return mlir::emitError(module->getLoc(), "unsupported UHDI format ")
           << options.format;
  return UhdiEmitter(module, options).run(os);
}
