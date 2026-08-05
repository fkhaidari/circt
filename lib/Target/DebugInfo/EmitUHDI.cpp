//===- EmitUHDI.cpp - Pool-based UHDI emission ----------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Serialise the compile-unit's debug information into the pool-based UHDI
// JSON format. Reads `dbg.*` ops stamped with `uhdi.stable_id`
// (firrtl-uhdi-init); knows nothing else about the producer.
//
// Pools: representations (chisel/verilog), types (uint/sint/clock/struct/
// vector), expressions (comb opcode trees + aggregate '{ literals),
// variables (per-repr name/loc/value with sigName / exprRef / constant /
// bitVector binding), scopes (modules + inline).
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
#include "llvm/Support/JSON.h"
#include "llvm/Support/Path.h"

#define DEBUG_TYPE "emit-uhdi"

using namespace mlir;
using namespace circt;
using namespace debug;

using llvm::json::Array;
using llvm::json::Object;

namespace {

static constexpr StringRef kFormatVersion = "1.0";
static constexpr StringRef kChiselRepr = "chisel";

/// `dbg.value` is a metadata wrapper (typeName / params) materialised by
/// LowerIntrinsics. Unwrap before type interning, name resolution, and
/// expression-pool emission to reach the wrapped SSA value.
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

/// Serialise `params` ArrayAttr (frontend JSON preserved by LowerIntrinsics)
/// into the UHDI `sourceLangType.params` array; native type preservation
/// (StringAttr -> string, BoolAttr -> bool, IntegerAttr -> int).
static Array renderSourceLangParams(ArrayAttr params) {
  Array out;
  if (!params)
    return out;
  for (Attribute entryAttr : params) {
    auto dict = dyn_cast<DictionaryAttr>(entryAttr);
    if (!dict)
      continue;
    Object entry;
    for (NamedAttribute na : dict) {
      StringRef key = na.getName().getValue();
      Attribute v = na.getValue();
      if (auto s = dyn_cast<StringAttr>(v))
        entry[key.str()] = s.getValue().str();
      else if (auto b = dyn_cast<BoolAttr>(v))
        entry[key.str()] = b.getValue();
      else if (auto i = dyn_cast<IntegerAttr>(v))
        entry[key.str()] = i.getValue().getSExtValue();
    }
    if (!entry.empty())
      out.push_back(std::move(entry));
  }
  return out;
}

/// Build the `sourceLangType` object for a typeName / params pair.
/// Returns nullopt when no typeName is present (matches the schema's
/// `required: [typeName]`).
static std::optional<Object> renderSourceLangType(StringAttr typeName,
                                                  ArrayAttr params) {
  if (!typeName || typeName.getValue().empty())
    return std::nullopt;
  Object o{{"typeName", typeName.getValue().str()}};
  Array p = renderSourceLangParams(params);
  if (!p.empty())
    o["params"] = std::move(p);
  return o;
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
static std::optional<unsigned> resolveAsOutputPortId(mlir::Value value) {
  auto *op = value.getDefiningOp();
  if (!op)
    return std::nullopt;
  Operation *wireOp = nullptr;
  if (auto rio = dyn_cast<sv::ReadInOutOp>(op)) {
    if (auto *def = rio.getInput().getDefiningOp())
      if (isa<sv::WireOp, sv::LogicOp>(def))
        wireOp = def;
  } else if (isa<sv::WireOp, sv::LogicOp>(op)) {
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
  if (varName.empty() || !mod || !value || !isa<BlockArgument>(value))
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

/// Per-repr file list, deduplicated, in insertion order.
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

/// Spec sec.6.4 Location object; nullopt if no FileLineColLoc.
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

class TypePool {
public:
  /// Intern the type of `value`. Scalar ints map to canonical ground ids
  /// (`uint8`, `bool`, etc.); aggregates get a structural key + a
  /// hint-derived id (e.g. "BundleTest_io_in") or a `struct_N`/`array_N`
  /// fallback. A `dbg.enum` wrapper overrides the scalar typeRef with the
  /// enum type-pool entry.
  std::string internValueType(mlir::Value value, StringRef nameHint = {}) {
    value = unwrapDbgValue(value);
    if (auto opResult = dyn_cast<OpResult>(value)) {
      // A `dbg.enum` wrapper overrides the underlying integer typeRef with the
      // enum type-pool entry.
      if (auto en = dyn_cast_or_null<debug::EnumOp>(opResult.getOwner()))
        return internEnum(en);
      if (auto s = dyn_cast_or_null<debug::StructOp>(opResult.getOwner()))
        return internStruct(s, nameHint);
      if (auto a = dyn_cast_or_null<debug::ArrayOp>(opResult.getOwner()))
        return internArray(a, nameHint);
    }
    return internType(value.getType(), value.getLoc());
  }

  /// Intern an IR Type directly (synthesized-port fallback). Preserves
  /// !seq.clock as `kind: clock` (spec §4.2 GroundClock); recurses into
  /// `hw.array` / `hw.struct` so aggregate ports don't silently collapse
  /// to a `uint0` placeholder. Truly opaque types still fall back to
  /// `uint<0>` but surface a warning at `warnLoc` so the corruption is
  /// at least audible.
  std::string internType(mlir::Type type, mlir::Location warnLoc) {
    if (auto i = dyn_cast<IntegerType>(type))
      return internGround(i.isSigned() ? "sint" : "uint", i.getWidth());
    if (isa<seq::ClockType>(type))
      return internGround("clock", 0);
    if (auto arr = dyn_cast<hw::ArrayType>(type))
      return internArrayType(arr, warnLoc);
    if (auto st = dyn_cast<hw::StructType>(type))
      return internStructType(st, warnLoc);
    mlir::emitWarning(warnLoc) << "uhdi: unrecognised type " << type
                               << "; falling back to uint<0> placeholder";
    return internGround("uint", 0);
  }

  /// Intern a `dbg.enum` value op as a `kind: "enum"` type-pool entry. The
  /// dedup key is the fqn (preferred) or else the typeName, so identical enums
  /// materialised inline at many use sites — including across modules —
  /// collapse to one pool entry. Width of the underlying int is derived from
  /// the widest IntegerAttr in the variants map. `variantsMap` is stored in IR
  /// as `<name> -> IntegerAttr` (DictionaryAttr keys must be strings); the
  /// emitted UHDI form inverts that to `"<int>" -> "<name>"` to match HGLDD's
  /// `enum_defs` shape. Idempotent across multiple references.
  std::string internEnum(debug::EnumOp op) {
    StringRef fqn = op.getFqn().value_or("");
    std::string id = fqn.empty() ? op.getEnumTypeName().str() : fqn.str();
    DictionaryAttr variantsMap = op.getVariantsMapAttr();
    unsigned width = 1;
    for (NamedAttribute na : variantsMap)
      if (auto intAttr = dyn_cast<IntegerAttr>(na.getValue()))
        width = std::max<unsigned>(width,
                                   intAttr.getType().getIntOrFloatBitWidth());
    std::string underlyingId = internGround("uint", width);
    Object variantsJson;
    for (NamedAttribute na : variantsMap) {
      auto intAttr = dyn_cast<IntegerAttr>(na.getValue());
      if (!intAttr)
        continue;
      llvm::SmallString<16> keyBuf;
      intAttr.getValue().toString(keyBuf, /*Radix=*/10, /*Signed=*/false);
      variantsJson[std::string(keyBuf)] = na.getName().getValue().str();
    }
    llvm::json::Value entry = Object{{"kind", "enum"},
                                     {"underlyingTypeRef", underlyingId},
                                     {"variants", std::move(variantsJson)}};
    // The key identifies the enum, so a second definition claiming it must
    // describe the same layout. When it does not, keeping the first silently
    // would decode the second enum's values against the wrong variant names,
    // so give it a key of its own and say so.
    if (auto *existing = entries.get(id)) {
      if (*existing == entry)
        return id;
      unsigned disambiguator = 1;
      std::string unique;
      do {
        unique = id + "#" + std::to_string(disambiguator++);
      } while (entries.get(unique));
      mlir::emitWarning(op.getLoc())
          << "uhdi: enum '" << id
          << "' redefined with a different layout; emitting it as '" << unique
          << "'";
      id = unique;
    }
    entries[id] = std::move(entry);
    return id;
  }

  Object asObject() const { return entries; }

private:
  Object entries;
  llvm::StringMap<std::string> byKey;
  unsigned structCounter = 0, arrayCounter = 0;

  std::string allocAggregateId(StringRef prefix, unsigned &counter) {
    std::string id;
    do {
      id = (prefix + std::to_string(counter++)).str();
    } while (entries.get(id));
    return id;
  }

  std::string internGround(StringRef kind, unsigned width) {
    std::string id = (kind == "uint" && width == 1)
                         ? std::string("bool")
                         : (kind + std::to_string(width)).str();
    if (byKey.count(id))
      return id;
    byKey[id] = id;
    Object d{{"kind", kind.str()}};
    if (kind == "uint" || kind == "sint")
      d["width"] = int64_t(width);
    entries[id] = std::move(d);
    return id;
  }

  /// `flipped: true` when the SSA source is a BlockArgument (mirrors
  /// EmitHGLDD's direction-aware hgl_loc binding on bundle fields).
  std::string internStruct(debug::StructOp op, StringRef nameHint) {
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
      std::string ft = internValueType(field, childHint);
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
    if (auto it = byKey.find(key); it != byKey.end())
      return it->second;
    std::string id = pickAggregateId(nameHint, "struct_", structCounter);
    byKey[key] = id;
    entries[id] = Object{{"kind", "struct"}, {"members", std::move(members)}};
    return id;
  }

  std::string internArray(debug::ArrayOp op, StringRef nameHint) {
    auto elems = op.getElements();
    std::string elemId = elems.empty()
                             ? internGround("uint", 0)
                             : internValueType(elems.front(), nameHint);
    std::string key =
        "array{" + elemId + ':' + std::to_string(elems.size()) + '}';
    if (auto it = byKey.find(key); it != byKey.end())
      return it->second;
    std::string id = pickAggregateId(nameHint, "array_", arrayCounter);
    byKey[key] = id;
    entries[id] = Object{{"kind", "vector"},
                         {"elementRef", elemId},
                         {"size", int64_t(elems.size())}};
    return id;
  }

  /// Intern a `hw.struct` type directly (port type, no dbg.struct
  /// wrapper). Used by `internType` on aggregate ports that survived
  /// LowerTypes (e.g. extmodule signatures, or ports whose lowering was
  /// skipped). Structural key only — no name hint to honour here.
  std::string internStructType(hw::StructType type, mlir::Location warnLoc) {
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
    if (auto it = byKey.find(key); it != byKey.end())
      return it->second;
    std::string id = allocAggregateId("struct_", structCounter);
    byKey[key] = id;
    entries[id] = Object{{"kind", "struct"}, {"members", std::move(members)}};
    return id;
  }

  /// Intern a `hw.array` type directly (port type, no dbg.array wrapper).
  std::string internArrayType(hw::ArrayType type, mlir::Location warnLoc) {
    std::string elemId = internType(type.getElementType(), warnLoc);
    std::string key =
        "array{" + elemId + ':' + std::to_string(type.getNumElements()) + '}';
    if (auto it = byKey.find(key); it != byKey.end())
      return it->second;
    std::string id = allocAggregateId("array_", arrayCounter);
    byKey[key] = id;
    entries[id] = Object{{"kind", "vector"},
                         {"elementRef", elemId},
                         {"size", int64_t(type.getNumElements())}};
    return id;
  }

  std::string pickAggregateId(StringRef hint, StringRef prefix,
                              unsigned &counter) {
    if (hint.empty())
      return allocAggregateId(prefix, counter);
    std::string id = hint.str();
    while (entries.get(id))
      id = allocAggregateId((hint + "_").str(), counter);
    return id;
  }
};

//===----------------------------------------------------------------------===//
// Expression pool
//===----------------------------------------------------------------------===//

/// A `comb` op -> uhdi opcode (sec.5.2). Empty for variadic / mux /
/// concat / replicate / parity, which `operandFor` handles directly.
static StringRef combBinaryOpcode(Operation *op) {
  if (isa<comb::AndOp>(op))
    return "&";
  if (isa<comb::OrOp>(op))
    return "|";
  if (isa<comb::XorOp>(op))
    return "^";
  if (isa<comb::AddOp>(op))
    return "+";
  if (isa<comb::SubOp>(op))
    return "-";
  if (isa<comb::MulOp>(op))
    return "*";
  if (isa<comb::DivUOp>(op) || isa<comb::DivSOp>(op))
    return "/";
  if (isa<comb::ModUOp>(op) || isa<comb::ModSOp>(op))
    return "%";
  if (isa<comb::ShlOp>(op))
    return "<<";
  if (isa<comb::ShrUOp>(op))
    return ">>";
  if (isa<comb::ShrSOp>(op))
    return ">>>";
  if (auto cmp = dyn_cast<comb::ICmpOp>(op)) {
    using P = comb::ICmpPredicate;
    switch (cmp.getPredicate()) {
    case P::eq:
      return "==";
    case P::ne:
      return "!=";
    case P::ceq:
      return "===";
    case P::cne:
      return "!==";
    case P::weq:
      return "==?";
    case P::wne:
      return "!=?";
    case P::ult:
    case P::slt:
      return "<";
    case P::ugt:
    case P::sgt:
      return ">";
    case P::ule:
    case P::sle:
      return "<=";
    case P::uge:
    case P::sge:
      return ">=";
    }
  }
  return "";
}

/// Render a hw.constant: LeafConst for ≤63-bit values (cap at 63 so the
/// cast to int64_t never sign-flips), LeafBitVec otherwise. When
/// `includeWidth` is true (inside expressions where there is no enclosing
/// typeRef) the `width` key is emitted so the converter can pick the
/// bit_vector path instead of integer_num.
static Object renderConstant(const llvm::APInt &val,
                             bool includeWidth = false) {
  Object lit;
  unsigned bw = val.getBitWidth();
  if (val.getActiveBits() <= 63) {
    lit["constant"] = static_cast<int64_t>(val.getZExtValue());
    if (includeWidth)
      lit["width"] = int64_t(bw);
    return lit;
  }
  llvm::SmallString<128> bits;
  val.toString(bits, /*Radix=*/2, /*Signed=*/false,
               /*formatAsCLiteral=*/false, /*UpperCase=*/false,
               /*InsertSeparators=*/false);
  while (bits.size() < bw)
    bits.insert(bits.begin(), '0'); // toString drops leading zeros.
  lit["bitVector"] = bits.str().str();
  if (includeWidth)
    lit["width"] = int64_t(bw);
  return lit;
}

class ExpressionPool {
public:
  /// uhdi Operand for `value`: prefers a sigName leaf when one resolves;
  /// aggregates / comb ops materialise a fresh pool entry and return
  /// `{exprRef: id}`. `leafNameFn` is the scalar-signal Verilog resolver.
  Object operandFor(mlir::Value value,
                    llvm::function_ref<StringAttr(mlir::Value)> leafNameFn) {
    // Look through dbg.value and dbg.enum: transparent wrappers added by
    // LowerIntrinsics. Without this, the bundle-field operands of a
    // `dbg.struct` post-LowerTypes resolve to empty sigNames (the wrapper
    // result types !dbg.value / !dbg.enum, which sv::resolveVerilogName
    // doesn't know).
    value = unwrapToHwValue(value);
    if (auto nameAttr = leafNameFn(value))
      return Object{{"sigName", nameAttr.getValue().str()}};
    auto opResult = dyn_cast<OpResult>(value);
    if (!opResult)
      return Object{{"sigName", ""}};
    Operation *defOp = opResult.getOwner();

    // Reserve the id BEFORE recursing so outer expressions get the
    // smaller index than the inner ones they depend on (matches HGLDD
    // ordering and avoids forward refs in the diff).
    if (auto it = byValue.find(value); it != byValue.end())
      return Object{{"exprRef", it->second}};

    auto wrap = [&](StringRef opcode, auto fillOperands) -> Object {
      std::string id;
      do {
        id = "expr_" + std::to_string(counter++);
      } while (entries.get(id));
      byValue[value] = id;
      Array operands;
      fillOperands(operands);
      entries[id] =
          Object{{"opcode", opcode.str()}, {"operands", std::move(operands)}};
      return Object{{"exprRef", id}};
    };
    auto fillFrom = [&](auto range) {
      return [&, range](Array &out) {
        for (auto v : range)
          out.push_back(operandFor(v, leafNameFn));
      };
    };

    // A struct operand carries the field name `dbg.struct` pairs it with, so
    // a consumer joins the type-pool member and the operand by name instead
    // of trusting that both lists happen to be in the same order.
    if (auto s = dyn_cast<debug::StructOp>(defOp))
      return wrap("'{", [&](Array &out) {
        for (auto [name, field] : llvm::zip(s.getNames(), s.getFields())) {
          Object operand = operandFor(field, leafNameFn);
          operand["name"] = cast<StringAttr>(name).getValue().str();
          out.push_back(std::move(operand));
        }
      });
    if (auto a = dyn_cast<debug::ArrayOp>(defOp))
      return wrap("'{", fillFrom(a.getElements()));
    if (auto c = dyn_cast<hw::ConstantOp>(defOp))
      return renderConstant(c.getValue(), /*includeWidth=*/true);
    if (auto concat = dyn_cast<comb::ConcatOp>(defOp))
      return wrap("{}", fillFrom(concat.getOperands()));
    if (auto repl = dyn_cast<comb::ReplicateOp>(defOp))
      return wrap("R{}", [&](Array &out) {
        out.push_back(operandFor(repl.getInput(), leafNameFn));
        out.push_back(Object{{"constant", int64_t(repl.getMultiple())},
                             {"width", int64_t(1)}});
      });
    if (auto mux = dyn_cast<comb::MuxOp>(defOp))
      return wrap("?:", [&](Array &out) {
        out.push_back(operandFor(mux.getCond(), leafNameFn));
        out.push_back(operandFor(mux.getTrueValue(), leafNameFn));
        out.push_back(operandFor(mux.getFalseValue(), leafNameFn));
      });
    if (isa<comb::ParityOp>(defOp) && defOp->getNumOperands() == 1)
      return wrap("^", fillFrom(defOp->getOperands()));
    if (StringRef opcode = combBinaryOpcode(defOp);
        !opcode.empty() && defOp->getNumOperands() == 2)
      return wrap(opcode, fillFrom(defOp->getOperands()));

    // Last resort: caller (emitVariable) detects this trivial-empty
    // sigName and suppresses the value rather than emitting `{sigName: ""}`.
    return Object{{"sigName", ""}};
  }

  Object asObject() const { return entries; }

private:
  Object entries;
  unsigned counter = 0;
  /// One entry per value: an aggregate reached both from its parent's
  /// expression and from its own synthetic Variable is one expression.
  llvm::DenseMap<mlir::Value, std::string> byValue;
};

//===----------------------------------------------------------------------===//
// Variable / scope assembly
//===----------------------------------------------------------------------===//

/// Owner scope for a dbg op: the enclosing `dbg.scope`'s stable_id when
/// present, else the enclosing hw.module's stable_id (or symbol name).
static StringRef ownerScopeId(Operation *op) {
  if (auto var = dyn_cast<debug::VariableOp>(op))
    if (auto scope = var.getScope())
      if (auto *def = scope.getDefiningOp())
        if (auto id = def->getAttrOfType<StringAttr>(kUhdiStableIdAttr))
          return id.getValue();
  for (auto *p = op->getParentOp(); p; p = p->getParentOp()) {
    // Break on module first: a module carrying uhdi.stable_id must not
    // shadow the symbol-name fallback below (the stable_id would then
    // reference itself as a scope, which is wrong — modules are keyed
    // by symbol name, not stable_id).
    if (isa<hw::HWModuleOp, hw::HWModuleExternOp>(p))
      break;
    if (auto id = p->getAttrOfType<StringAttr>(kUhdiStableIdAttr))
      return id.getValue();
  }
  if (auto mod = op->getParentOfType<hw::HWModuleOp>())
    return mod.getNameAttr().getValue();
  if (auto mod = op->getParentOfType<hw::HWModuleExternOp>())
    return mod.getNameAttr().getValue();
  return {};
}

namespace {
/// Bundle of per-document mutable state passed through the assembly
/// helpers. Keeps the function signatures from sprouting a half-dozen
/// args each.
struct EmitState {
  TypePool &types;
  ExpressionPool &exprs;
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
} // namespace

/// One `variables[id]` entry for a `dbg.variable`. When the variable's
/// value is an aggregate (`dbg.struct` / `dbg.array`), `syntheticOut`
/// receives one extra `variables[id]` entry per `dbg.value` leaf so
/// that consumers see per-field source-language metadata (typeName /
/// enum typeRef) without recursing through the parent's expression
/// tree themselves.
static Object emitVariable(
    debug::VariableOp var, EmitState &s,
    SmallVectorImpl<std::pair<std::string, Object>> *syntheticOut = nullptr) {
  Object entry;
  // Root-level source-language metadata rides on a `dbg.value` wrapper of the
  // variable's operand; unwrap it once and use the wrapped value for all
  // structural checks (aggregate / port / constant detection).
  debug::ValueOp rootMeta = findDbgValue(var.getValue());
  mlir::Value rootVal = unwrapDbgValue(var.getValue());
  // Hint nested struct/array ids with `<Module>_<var>[_field]...` to
  // match HGLDD's naming so the canonical diff stays name-equal.
  std::string structHint;
  if (isa_and_nonnull<debug::StructOp, debug::ArrayOp>(
          rootVal.getDefiningOp())) {
    if (auto mod = var->getParentOfType<hw::HWModuleOp>())
      structHint = (mod.getNameAttr().getValue() + "_" + var.getName()).str();
    else
      structHint = var.getName().str();
  }
  // typeRef: a `dbg.enum`-valued dbg.variable resolves to the enum type-pool
  // entry inside internValueType; otherwise the value's own type (or aggregate
  // structure) wins.
  entry["typeRef"] = s.types.internValueType(rootVal, structHint);
  if (StringRef owner = ownerScopeId(var); !owner.empty())
    entry["ownerScopeRef"] = owner.str();

  // BlockArgument of an hw.module is always an input port; a value that
  // reaches hw.output via sv.read_inout/sv.wire is an output port.
  // Everything else is a node (named wire / reg / intermediate).
  bool isPort = false;
  bool isOutputPort = false;
  StringRef outputPortName;
  if (auto blockArg = dyn_cast<BlockArgument>(rootVal))
    isPort = isa<hw::HWModuleOp>(blockArg.getOwner()->getParentOp());
  if (!isPort)
    isOutputPort = resolveAsOutputPortId(unwrapToHwValue(rootVal)).has_value();
  // `assign b = a` leaves the output port sharing its value with the input
  // driving it, so a variable whose value is that input can still be the
  // output port. Its name settles which of the two it describes.
  if (auto mod = var->getParentOfType<hw::HWModuleOp>())
    if (resolveAsDirectOutputPortId(unwrapToHwValue(rootVal), var.getName(),
                                    mod)) {
      isPort = false;
      isOutputPort = true;
      outputPortName = var.getName();
    }
  entry["bindKind"] = (isPort || isOutputPort) ? "port" : "node";
  if (isPort)
    entry["direction"] = "input";
  else if (isOutputPort)
    entry["direction"] = "output";

  Object reprs;
  Object chisel{{"name", var.getName().str()}};
  if (auto loc = s.chiselLoc(var.getLoc()))
    chisel["location"] = std::move(*loc);
  if (rootMeta)
    if (auto slt = renderSourceLangType(rootMeta.getTypeNameAttr(),
                                        rootMeta.getParamsAttr()))
      chisel["sourceLangType"] = std::move(*slt);
  reprs[kChiselRepr] = std::move(chisel);

  // Verilog value: aggregate -> exprRef pool; constant -> constant /
  // bitVector; otherwise -> sigName via sv::resolveVerilogName with operandFor
  // as the DCE'd-/inlined fallback.
  Object verilog;
  // Bundle fields (the only place dbg.value surfaces) end up as
  // wires aliasing flat module ports post-LowerTypes: prefer the port
  // name over the lowering-introduced wire identifier.
  auto leafName = [](mlir::Value v) { return resolveBundleFieldName(v); };
  bool isAggregate =
      isa_and_nonnull<debug::StructOp, debug::ArrayOp>(rootVal.getDefiningOp());

  if (!outputPortName.empty()) {
    // Bind to the port itself, not to the signal that happens to drive it.
    verilog["name"] = outputPortName.str();
    verilog["value"] = Object{{"sigName", outputPortName.str()}};
  } else if (isAggregate) {
    verilog["value"] = s.exprs.operandFor(rootVal, leafName);
  } else if (auto opResult = dyn_cast<OpResult>(rootVal);
             opResult && isa_and_nonnull<hw::ConstantOp>(opResult.getOwner())) {
    Object lit =
        renderConstant(cast<hw::ConstantOp>(opResult.getOwner()).getValue());
    verilog["value"] = std::move(lit);
  } else if (auto vname = sv::resolveVerilogName(unwrapToHwValue(rootVal))) {
    verilog["name"] = vname.getValue().str();
    verilog["value"] = Object{{"sigName", vname.getValue().str()}};
  } else if (dyn_cast<OpResult>(rootVal)) {
    Object expr = s.exprs.operandFor(rootVal, leafName);
    bool trivialEmpty = (expr.size() == 1) &&
                        (expr.find("sigName") != expr.end()) &&
                        (expr["sigName"] == "");
    if (!trivialEmpty)
      verilog["value"] = std::move(expr);
  }
  if (auto loc = s.verilogLoc(var.getLoc()))
    verilog["location"] = std::move(*loc);
  reprs[kUhdiVerilogRepr] = std::move(verilog);
  entry["representations"] = std::move(reprs);

  // Materialise synthetic per-field Variables for aggregate parents.
  // Bare field names come from `dbg.struct.$names`; the wrapping
  // `dbg.value` (if any) contributes only its source-language metadata
  // and location. Synthetic ids are joined with `__` so consumers can
  // rpartition any nesting level back into (parent_id, leaf_field)
  // unambiguously even when field names themselves contain `_` or `.`.
  // The leaf also carries a verilog repr naming its own flat signal. The
  // parent's exprRef expansion exposes the same name, but only to a
  // consumer willing to descend the expression tree; one that resolves
  // variables to signals directly would drop every aggregate leaf.
  if (syntheticOut && isAggregate) {
    auto parentId = var->getAttrOfType<StringAttr>(kUhdiStableIdAttr);
    StringRef ownerScope = ownerScopeId(var);
    if (parentId) {
      std::function<void(StringRef, mlir::Value, const Twine &)> visitField;
      visitField = [&](StringRef bareName, mlir::Value fieldVal,
                       const Twine &pathPrefix) {
        std::string fullPath = pathPrefix.isTriviallyEmpty()
                                   ? bareName.str()
                                   : (pathPrefix + "__" + bareName).str();
        std::string synId = (parentId.getValue() + "__" + fullPath).str();

        // Unwrap one dbg.value layer to read metadata (typeName / params).
        // Inner value below is what we recurse on; a `dbg.enum` wrapper there
        // is resolved to the enum type-pool entry inside internValueType.
        debug::ValueOp vw = findDbgValue(fieldVal);
        mlir::Value innerVal = vw ? vw.getValue() : fieldVal;

        Object synEntry;
        synEntry["typeRef"] =
            s.types.internValueType(innerVal, parentId.getValue());
        if (!ownerScope.empty())
          synEntry["ownerScopeRef"] = ownerScope.str();
        synEntry["bindKind"] = "synthetic";
        Object synChisel{{"name", bareName.str()}};
        // Prefer the dbg.value's own location (carries source-loc
        // attached to the originating circt_debug_subfield intrinsic);
        // fall back to the parent Variable's loc so a leaf without a
        // metadata wrapper still gets a usable hgl_loc.
        Location locForLoc = vw ? vw.getLoc() : var.getLoc();
        if (auto loc = s.chiselLoc(locForLoc))
          synChisel["location"] = std::move(*loc);
        if (vw)
          if (auto slt = renderSourceLangType(vw.getTypeNameAttr(),
                                              vw.getParamsAttr()))
            synChisel["sourceLangType"] = std::move(*slt);
        Object synReprs;
        synReprs[kChiselRepr] = std::move(synChisel);
        // A leaf that lowering left as one signal names it; an aggregate
        // leaf gets the expression that rebuilds it from its own leaves,
        // the same one its parent references. A value tied to neither gets
        // no `value` at all.
        Object synVerilog;
        if (auto vname = leafName(unwrapToHwValue(innerVal))) {
          synVerilog["name"] = vname.getValue().str();
          synVerilog["value"] = Object{{"sigName", vname.getValue().str()}};
        } else if (auto opR = dyn_cast<OpResult>(innerVal);
                   opR &&
                   isa<debug::StructOp, debug::ArrayOp>(opR.getOwner())) {
          synVerilog["value"] = s.exprs.operandFor(innerVal, leafName);
        }
        synReprs[kUhdiVerilogRepr] = std::move(synVerilog);
        synEntry["representations"] = std::move(synReprs);
        syntheticOut->emplace_back(std::move(synId), std::move(synEntry));

        // Recurse through nested aggregate. struct names are bare;
        // array indices stringify into one segment each.
        if (auto opR = dyn_cast<OpResult>(innerVal)) {
          if (auto st = dyn_cast<debug::StructOp>(opR.getOwner()))
            for (auto [nm, f] : llvm::zip(st.getNames(), st.getFields()))
              visitField(cast<StringAttr>(nm).getValue(), f, fullPath);
          else if (auto ar = dyn_cast<debug::ArrayOp>(opR.getOwner()))
            for (auto [idx, f] : llvm::enumerate(ar.getElements()))
              visitField(std::to_string(idx), f, fullPath);
        }
      };

      // Driver: enumerate the top-level aggregate's members directly,
      // since `rootVal` is the struct/array itself (not a wrapper
      // around it).
      if (auto opR = dyn_cast<OpResult>(rootVal)) {
        if (auto st = dyn_cast<debug::StructOp>(opR.getOwner()))
          for (auto [nm, f] : llvm::zip(st.getNames(), st.getFields()))
            visitField(cast<StringAttr>(nm).getValue(), f, Twine());
        else if (auto ar = dyn_cast<debug::ArrayOp>(opR.getOwner()))
          for (auto [idx, f] : llvm::enumerate(ar.getElements()))
            visitField(std::to_string(idx), f, Twine());
      }
    }
  }

  return entry;
}

/// Build a `{name?, location?}` per-repr dict (used by inline scopes,
/// instantiates, module reprs).
static Object reprDict(StringRef name, std::optional<Object> loc) {
  Object d;
  if (!name.empty())
    d["name"] = name.str();
  if (loc)
    d["location"] = std::move(*loc);
  return d;
}

/// Adds the source-level type name + constructor params recorded in an op's
/// `dbg.moduleinfo` attribute to a representation entry. The attribute is set
/// once per module by the intrinsic lowering and rides through FIRRTL->HW
/// lowering; uniqueness is structural. Inlining copies it onto the `dbg.scope`
/// it creates, since the module op it lived on is gone by then.
static void addSourceLangType(Object &repr, Operation *op) {
  auto miAttr = op->getAttrOfType<DictionaryAttr>(kDbgModuleInfoAttr);
  if (!miAttr)
    return;
  if (auto slt = renderSourceLangType(miAttr.getAs<StringAttr>("typeName"),
                                      miAttr.getAs<ArrayAttr>("params")))
    repr["sourceLangType"] = std::move(*slt);
}

/// One `scopes[id]` entry for an `hw.module`.
static Object emitModuleScope(hw::HWModuleOp module, EmitState &s) {
  StringRef sym = module.getNameAttr().getValue();
  StringRef vname = sym;
  if (auto attr = module->getAttrOfType<StringAttr>("verilogName"))
    vname = attr.getValue();
  Object entry{{"name", sym.str()}, {"kind", "module"}};
  Object reprs;
  Object chiselRepr = reprDict(sym, s.chiselLoc(module.getLoc()));
  addSourceLangType(chiselRepr, module);
  reprs[kChiselRepr] = std::move(chiselRepr);
  reprs[kUhdiVerilogRepr] = reprDict(vname, s.verilogLoc(module.getLoc()));
  entry["representations"] = std::move(reprs);

  // hw.instance children -> instantiates[].
  Array instantiates;
  module.walk([&](hw::InstanceOp inst) {
    Object e{{"as", inst.getInstanceName().str()},
             {"scopeRef", inst.getModuleName().str()}};
    Object perReprs;
    Object chisel = reprDict("", s.chiselLoc(inst.getLoc()));
    if (!chisel.empty())
      perReprs[kChiselRepr] = std::move(chisel);
    // PrettifyVerilogNames may rename the instance; record only when it
    // diverges from the source-level instanceName.
    StringRef vrename;
    if (auto vn = inst->getAttrOfType<StringAttr>("hw.verilogName");
        vn && vn.getValue() != inst.getInstanceName())
      vrename = vn.getValue();
    Object verilog = reprDict(vrename, s.verilogLoc(inst.getLoc()));
    if (!verilog.empty())
      perReprs[kUhdiVerilogRepr] = std::move(verilog);
    if (!perReprs.empty())
      e["representations"] = std::move(perReprs);
    instantiates.push_back(std::move(e));
  });
  if (!instantiates.empty())
    entry["instantiates"] = std::move(instantiates);
  return entry;
}

/// One `scopes[id]` entry for an inline `dbg.scope`.
/// `containerScopeRef` lets the HGLDD converter graft the inline scope
/// into the right parent's `children[]` array.
static Object emitInlineScope(debug::ScopeOp scope, EmitState &s) {
  Object entry{{"name", scope.getModuleName().str()}, {"kind", "inline"}};
  Object reprs;
  Object chiselRepr =
      reprDict(scope.getInstanceName(), s.chiselLoc(scope.getLoc()));
  addSourceLangType(chiselRepr, scope);
  reprs[kChiselRepr] = std::move(chiselRepr);
  entry["representations"] = std::move(reprs);
  // A scope nested in another one belongs to that scope, not to the hardware
  // module both happen to sit in. Naming the module would flatten a hierarchy
  // the IR keeps nested, since inlining a module that was itself inlined into
  // leaves one scope per level.
  if (auto parent = scope.getScope())
    if (auto *def = parent.getDefiningOp())
      if (auto id = def->getAttrOfType<StringAttr>(kUhdiStableIdAttr)) {
        entry["containerScopeRef"] = id.getValue().str();
        return entry;
      }
  if (auto module = scope->getParentOfType<hw::HWModuleOp>())
    entry["containerScopeRef"] = module.getNameAttr().getValue().str();
  return entry;
}

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
  ExpressionPool exprs;
  FileTable chiselFiles, verilogFiles;
  Object variables, scopes;
  SmallVector<std::string> topScopes;
  llvm::StringMap<bool> existsCache;

  void collect(mlir::ModuleOp top);
  Object render() const;

  EmitState state() {
    return EmitState{types,
                     exprs,
                     chiselFiles,
                     verilogFiles,
                     options.sourceFilePrefix,
                     options.outputFilePrefix,
                     options.onlyExistingFileLocs,
                     existsCache};
  }

  /// Fill in port_var entries for ports that lack a `dbg.variable` cover
  /// (e.g. firtool-emitted SRAM macros, or hand-written hw.module fixtures
  /// with no MaterializeDebugInfo run). Per-port — modules that already
  /// have dbg.variables for *some* of their ports still get synthesized
  /// entries for the *uncovered* ports, so partial coverage doesn't read
  /// as full coverage. Both directions emit a verilog repr with the
  /// port-name sigName so VCD/Tywaves can bind on the signal.
  void synthesizePortVars(hw::HWModuleOp mod,
                          llvm::StringMap<Array> &orderedVarsByScope,
                          const llvm::DenseSet<unsigned> &coveredPortIndices);
};

void UhdiEmitter::synthesizePortVars(
    hw::HWModuleOp mod, llvm::StringMap<Array> &orderedVarsByScope,
    const llvm::DenseSet<unsigned> &coveredPortIndices) {
  StringRef scopeKey = mod.getNameAttr().getValue();
  auto modType = mod.getModuleType();
  if (modType.getNumPorts() == 0)
    return;

  Array &refs = orderedVarsByScope[scopeKey];
  for (size_t i = 0, e = modType.getNumPorts(); i < e; ++i) {
    if (coveredPortIndices.contains(i))
      continue;
    StringRef portName = modType.getPortName(i);
    if (portName.empty())
      continue;
    bool isOutput = modType.isOutput(i);
    std::string varId = (Twine("var_") + scopeKey + "_" + portName).str();
    Object entry{{"ownerScopeRef", scopeKey.str()},
                 {"bindKind", "port"},
                 {"direction", isOutput ? "output" : "input"},
                 {"typeRef",
                  types.internType(modType.getPorts()[i].type, mod.getLoc())}};
    Object reprs;
    reprs[kChiselRepr] = Object{{"name", portName.str()}};
    // Both directions: bind the synthesized variable to the same-named
    // verilog signal. VCD/Tywaves rely on the sigName to lock onto the
    // port; omitting it for outputs leaves the variable unbound.
    reprs[kUhdiVerilogRepr] =
        Object{{"name", portName.str()},
               {"value", Object{{"sigName", portName.str()}}}};
    entry["representations"] = std::move(reprs);
    variables[varId] = std::move(entry);
    refs.push_back(varId);
  }
}

static bool isModuleScope(const llvm::json::Value &val) {
  auto *obj = val.getAsObject();
  auto kind = obj ? obj->getString("kind") : std::nullopt;
  return kind && *kind == "module";
}

void UhdiEmitter::collect(mlir::ModuleOp top) {
  EmitState s = state();

  // Seed the HDL file list with the netlist this document describes, so it is
  // named even when nothing in the IR carries an emitted location.
  verilogFiles.internIfNamed(options.verilogFileName);

  // 1. Module / extmodule scopes; record public modules as `top`.
  // (uhdi-init doesn't stamp modules; the symbol name stands in.)
  for (auto &op : top.getOps()) {
    if (auto mod = dyn_cast<hw::HWModuleOp>(op)) {
      scopes[mod.getNameAttr().getValue().str()] = emitModuleScope(mod, s);
      if (mod.isPublic())
        topScopes.push_back(mod.getNameAttr().getValue().str());
    } else if (auto ext = dyn_cast<hw::HWModuleExternOp>(op)) {
      scopes[ext.getNameAttr().getValue().str()] = Object{
          {"name", ext.getNameAttr().getValue().str()}, {"kind", "extmodule"}};
    }
  }

  // 2. One whole-circuit walk that emits variables and scopes AND collects
  // the per-module port coverage step 3 consumes — so step 3 doesn't
  // re-walk.
  llvm::StringMap<Array> orderedVarsByScope;
  llvm::DenseMap<hw::HWModuleOp, llvm::DenseSet<unsigned>> coveredPortsByMod;
  top.walk([&](Operation *inner) {
    if (auto scope = dyn_cast<debug::ScopeOp>(inner)) {
      if (auto id = scope->getAttrOfType<StringAttr>(kUhdiStableIdAttr))
        scopes[id.getValue().str()] = emitInlineScope(scope, s);
      return;
    }
    if (auto var = dyn_cast<debug::VariableOp>(inner)) {
      auto id = var->getAttrOfType<StringAttr>(kUhdiStableIdAttr);
      if (!id)
        return;
      SmallVector<std::pair<std::string, Object>, 4> synthetic;
      variables[id.getValue().str()] = emitVariable(var, s, &synthetic);
      StringRef owner = ownerScopeId(var);
      if (!owner.empty())
        orderedVarsByScope[owner].push_back(id.getValue().str());
      for (auto &kv : synthetic) {
        if (!owner.empty())
          orderedVarsByScope[owner].push_back(kv.first);
        variables[kv.first] = std::move(kv.second);
      }
      if (auto mod = var->getParentOfType<hw::HWModuleOp>()) {
        auto modType = mod.getHWModuleType();
        // A variable standing for a directly driven output port covers that
        // port, not the input feeding it; synthesising one anyway would
        // describe the same port twice, with conflicting directions.
        auto directOut = resolveAsDirectOutputPortId(
            unwrapToHwValue(var.getValue()), var.getName(), mod);
        if (directOut)
          coveredPortsByMod[mod].insert(
              modType.getPortIdForOutputId(*directOut));
        else if (auto blockArg =
                     dyn_cast<BlockArgument>(unwrapDbgValue(var.getValue())))
          if (mod.getBodyRegion().hasOneBlock() &&
              blockArg.getOwner() == &mod.getBodyRegion().front()) {
            // Body-block args are indexed by input-id (HWOpInterfaces.td);
            // coveredPortsByMod is consumed in synthesizePortVars against
            // absolute port-ids, so translate here.
            coveredPortsByMod[mod].insert(
                modType.getPortIdForInputId(blockArg.getArgNumber()));
          }
        // Output ports reach the variable value through dbg.enum /
        // dbg.value wrappers and then sv.read_inout / sv.wire /
        // hw.output. unwrapToHwValue strips the dbg wrappers; then
        // resolveAsOutputPortId walks the wire-alias chain to find the
        // hw.output operand number (= output-id). Translate to absolute
        // port-id before inserting so synthesizePortVars doesn't emit a
        // redundant synthesised entry for this port.
        if (auto outIdx =
                resolveAsOutputPortId(unwrapToHwValue(var.getValue())))
          coveredPortsByMod[mod].insert(modType.getPortIdForOutputId(*outIdx));
      }
      return;
    }
  });

  auto withScopeEntry = [&](StringRef key,
                            llvm::function_ref<void(Object &)> fn) {
    if (key.empty())
      return;
    auto it = scopes.find(key);
    if (it == scopes.end())
      return;
    if (auto *obj = it->getSecond().getAsObject())
      fn(*obj);
  };

  // 3. Synthesized port_vars for modules with no dbg.variable coverage.
  for (auto mod : top.getOps<hw::HWModuleOp>())
    synthesizePortVars(mod, orderedVarsByScope, coveredPortsByMod[mod]);

  // Stitch ordered variableRefs onto each scope entry.
  for (auto &kv : orderedVarsByScope)
    withScopeEntry(kv.first(), [&](Object &obj) {
      obj["variableRefs"] = std::move(kv.second);
    });

  // 5. Synthetic `_uhdi_empty_design` placeholder so an extmodule-only /
  // empty input still satisfies the schema's `top: minItems=1` invariant.
  bool haveModule = llvm::any_of(
      scopes, [](const auto &kv) { return isModuleScope(kv.getSecond()); });
  if (!haveModule) {
    top.emitWarning() << "uhdi: no hw.module-kind scope found; emitting "
                         "synthetic '_uhdi_empty_design' top scope so the "
                         "document remains schema-valid";
    static constexpr StringRef kEmpty = "_uhdi_empty_design";
    scopes[kEmpty] = Object{{"name", kEmpty.str()}, {"kind", "module"}};
  }
}

Object UhdiEmitter::render() const {
  Object doc;
  doc["format"] = Object{{"name", "uhdi"}, {"version", kFormatVersion.str()}};
  doc["producer"] = Object{{"name", "circt"}};
  doc["representations"] =
      Object{{kChiselRepr, Object{{"kind", "source"},
                                  {"language", "Chisel"},
                                  {"files", chiselFiles.asArray()}}},
             {kUhdiVerilogRepr, Object{{"kind", "hdl"},
                                       {"language", "SystemVerilog"},
                                       {"files", verilogFiles.asArray()}}}};
  doc["roles"] = Object{{"authoring", kChiselRepr.str()},
                        {"simulation", kUhdiVerilogRepr.str()},
                        {"canonical", kUhdiVerilogRepr.str()}};

  Array topArray;
  for (auto &s : topScopes)
    topArray.push_back(s);
  // No public hw.module: prefer first `module`-kind scope (an extmodule
  // chosen as top would mislead consumers). The `_uhdi_empty_design`
  // placeholder is materialised in collect() so this stays const.
  if (topArray.empty()) {
    auto it = llvm::find_if(
        scopes, [](const auto &kv) { return isModuleScope(kv.getSecond()); });
    if (it != scopes.end())
      topArray.push_back(it->getFirst().str());
  }
  doc["top"] = std::move(topArray);

  doc["types"] = types.asObject();
  if (Object e = exprs.asObject(); !e.empty())
    doc["expressions"] = std::move(e);
  doc["variables"] = Object(variables);
  doc["scopes"] = Object(scopes);
  return doc;
}

LogicalResult UhdiEmitter::run(raw_ostream &os) {
  auto top = dyn_cast<mlir::ModuleOp>(root);
  if (!top)
    return root->emitError("EmitUHDI expects a top-level builtin.module");
  collect(top);
  llvm::json::Value rendered(render());
  llvm::json::OStream(os, /*IndentSize=*/2).value(rendered);
  os << "\n";
  return success();
}

} // namespace

LogicalResult debug::emitUHDI(Operation *module, raw_ostream &os,
                              const EmitUHDIOptions &options) {
  return UhdiEmitter(module, options).run(os);
}
