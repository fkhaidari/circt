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
/// `dbg.moduleinfo`. The attribute is set once per module by the intrinsic
/// lowering and rides through FIRRTL->HW lowering; inlining copies it onto the
/// `dbg.scope` it creates, since the module op it lived on is gone by then.
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
/// of whichever language the location belongs to.
static std::optional<Object>
locationObject(FileLineColLoc loc, StringRef prefix, FileTable &files) {
  if (!loc)
    return std::nullopt;
  SmallString<128> path;
  if (prefix.empty())
    path = loc.getFilename().getValue();
  else {
    path = prefix;
    llvm::sys::path::append(path, loc.getFilename().getValue());
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
                              SourceType src = {}) {
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
    return internType(value.getType(), value.getLoc(), src);
  }

  /// Intern an IR Type directly (synthesized-port fallback). Preserves
  /// !seq.clock as `kind: clock` (spec §4.2 GroundClock); recurses into
  /// `hw.array` / `hw.struct` so aggregate ports don't silently collapse
  /// to a `uint0` placeholder. Truly opaque types still fall back to
  /// `uint<0>` but surface a warning at `warnLoc` so the corruption is
  /// at least audible.
  std::string internType(mlir::Type type, mlir::Location warnLoc,
                         SourceType src = {}) {
    if (auto i = dyn_cast<IntegerType>(type))
      return internGround(i.isSigned() ? "sint" : "uint", i.getWidth(), src);
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
          source["params"] = std::move(*e.params);
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
    std::string id = (kind == "uint" && width == 1)
                         ? std::string("bool")
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

  /// `flipped: true` when the SSA source is a BlockArgument (mirrors
  /// EmitHGLDD's direction-aware hgl_loc binding on bundle fields).
  std::string internStruct(debug::StructOp op, StringRef nameHint,
                           SourceType src) {
    Array members;
    std::string key = "struct{";
    for (auto [nameAttr, field] : llvm::zip(op.getNames(), op.getFields())) {
      StringRef n = cast<StringAttr>(nameAttr).getValue();
      std::string childHint =
          nameHint.empty() ? std::string() : (nameHint + "_" + n).str();
      // dbg.value wraps the leaf-value with metadata (typeName, params);
      // an enum leaf is additionally wrapped in dbg.enum. Pass the wrapped
      // value to internValueType so the enum/struct typeRef is preserved,
      // not the raw integer. For the BlockArgument check below we need the
      // real HW value, so strip both wrappers — otherwise an input port
      // flowing through the wrappers loses its `flipped` marker.
      std::string ft = internValueType(field, childHint, sourceTypeOf(field));
      mlir::Value innerField = unwrapToHwValue(field);
      bool flipped = isa<BlockArgument>(innerField);
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
    std::string elemId = elems.empty()
                             ? internGround("uint", 0, {})
                             : internValueType(elems.front(), nameHint,
                                               sourceTypeOf(elems.front()));
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

/// Render a hw.constant: `constant` for <=63-bit values (cap at 63 so the
/// cast to int64_t never sign-flips), `bitVector` otherwise. Width is
/// implicit in the variable's typeRef.
static Object renderConstant(const llvm::APInt &val) {
  Object lit;
  unsigned bw = val.getBitWidth();
  if (val.getActiveBits() <= 63) {
    lit["constant"] = static_cast<int64_t>(val.getZExtValue());
    return lit;
  }
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

  std::optional<Object> chiselLoc(Location loc) {
    return locationObject(
        bestLocation(loc, /*emitted=*/false, onlyExisting, &existsCache),
        chiselPrefix, chiselFiles);
  }
  std::optional<Object> verilogLoc(Location loc) {
    return locationObject(
        bestLocation(loc, /*emitted=*/true, onlyExisting, &existsCache),
        verilogPrefix, verilogFiles);
  }
};

/// One `variables[key]` entry, held until the document-wide type-source
/// resolution and the per-scope key assignment have run.
struct VarRecord {
  std::string name;
  std::string typeRef;
  StringRef direction;
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

  bool dropped = false;
  std::string key;
  Object entry;
};

struct InstanceRecord {
  std::string as;
  std::string moduleRef;
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
};

//===----------------------------------------------------------------------===//
// Emitter driver
//===----------------------------------------------------------------------===//

class UhdiEmitter {
public:
  UhdiEmitter(Operation *root, const EmitUHDIOptions &options)
      : root(root), options(options) {}
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
                     existsCache};
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

/// Simulation-side binding of a leaf: the signal it lowered to, or the literal
/// it was folded into. A value tied to neither has no binding at all.
static std::optional<llvm::json::Value> leafBinding(mlir::Value value) {
  mlir::Value hwVal = unwrapToHwValue(value);
  if (auto vname = resolveBundleFieldName(hwVal))
    return llvm::json::Value(vname.getValue().str());
  if (auto opR = dyn_cast<OpResult>(hwVal);
      opR && isa<hw::ConstantOp>(opR.getOwner()))
    return llvm::json::Value(
        renderConstant(cast<hw::ConstantOp>(opR.getOwner()).getValue()));
  return std::nullopt;
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
    if (auto binding = leafBinding(inner)) {
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
  auto binding = leafBinding(inner);
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
    rec.typeRef = types.internValueType(rootVal, structHint, src);

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
    rec.isPort = true;
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
      source["binding"] = binding.str();
  }
  if (!var.sourceParams.empty())
    source["params"] = std::move(var.sourceParams);
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
  if (auto typeName = moduleSourceTypeName(module))
    scope.source["typeName"] = typeName.getValue().str();
  if (Array params = moduleSourceParams(module); !params.empty())
    scope.source["params"] = std::move(params);
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
  if (!scope.getInstanceName().empty())
    rec.source["name"] = scope.getInstanceName().str();
  if (auto typeName = moduleSourceTypeName(scope))
    rec.source["typeName"] = typeName.getValue().str();
  if (Array params = moduleSourceParams(scope); !params.empty())
    rec.source["params"] = std::move(params);
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
      if (StringRef vn = verilogModuleName(ext); vn != scope.id)
        scope.target["name"] = vn.str();
      topLevelScopes.push_back(scopeIndex[ext.getNameAttr().getValue()]);
    }
  }

  // 2. Inline scopes, so a variable can be filed under one straight away. A
  // scope references its container through an SSA operand, which dominance puts
  // ahead of it, so one pass in walk order is enough to nest them.
  SmallVector<std::pair<unsigned, std::optional<unsigned>>> inlineContainers;
  top.walk([&](debug::ScopeOp scope) {
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

LogicalResult UhdiEmitter::run(raw_ostream &os) {
  auto top = dyn_cast<mlir::ModuleOp>(root);
  if (!top)
    return root->emitError("EmitUHDI expects a top-level builtin.module");
  collect(top);

  llvm::json::OStream j(os, /*IndentSize=*/2);
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
  return UhdiEmitter(module, options).run(os);
}
