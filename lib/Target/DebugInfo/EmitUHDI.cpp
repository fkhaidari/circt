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
// (firrtl-uhdi-init) and `uhdi.repr_entry` (hw-uhdi-verilog-snapshot);
// knows nothing else about the producer.
//
// Pools: representations (chisel/verilog), types (uint/sint/clock/struct/
// vector), expressions (comb opcode trees + aggregate '{ literals),
// variables (per-repr name/loc/value with sigName / exprRef / constant /
// bitVector binding), scopes (modules + inline + body[] from
// dbg.rootblock).
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

/// `dbg.subfield` is a metadata wrapper (typeName / params / enumDef)
/// materialised by LowerIntrinsics. Unwrap before type interning, name
/// resolution, and expression-pool emission to reach the leaf SSA value.
static mlir::Value unwrapDbgSubField(mlir::Value v) {
  while (auto opResult = dyn_cast<OpResult>(v))
    if (auto sf = dyn_cast<debug::SubFieldOp>(opResult.getOwner()))
      v = sf.getValue();
    else
      break;
  return v;
}

/// Innermost `dbg.subfield` wrapping `v`, if any -- carries source-language
/// metadata (`typeName` / `params` / `enumDef`).
///
/// TODO(uhdi/C3): only inspects the outermost SSA hop. If a future
/// producer stacks `dbg.subfield(dbg.subfield(...))` with `enumDef` on
/// the inner subfield, this returns the outer wrapper and the enum tag
/// is missed (typeRef would fall back to `uint<N>`). Current
/// LowerIntrinsics doesn't stack subfields, so this is a deferred fix.
static debug::SubFieldOp findDbgSubField(mlir::Value v) {
  if (auto opResult = dyn_cast<OpResult>(v))
    if (auto sf = dyn_cast<debug::SubFieldOp>(opResult.getOwner()))
      return sf;
  return {};
}

/// Stable enum type-pool key: prefer fqn (e.g. `Top.AluOp`); fall back to
/// `enumTypeName` when fqn is empty.
static std::string enumTypeId(debug::EnumDefOp op) {
  StringRef fqn = op.getFqn();
  if (!fqn.empty())
    return fqn.str();
  return op.getEnumTypeName().str();
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
  Object o{{"file", int64_t(files.intern(path))}};
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
  /// fallback. An enum-tagged `dbg.subfield` wrapper override the
  /// scalar typeRef with the enum type-pool entry.
  std::string internValueType(mlir::Value value, StringRef nameHint = {}) {
    if (auto sf = findDbgSubField(value))
      if (mlir::Value e = sf.getEnumDef())
        if (auto edOp = e.getDefiningOp<debug::EnumDefOp>())
          return internEnumDef(edOp);
    value = unwrapDbgSubField(value);
    if (auto opResult = dyn_cast<OpResult>(value)) {
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

  /// Intern a `dbg.enumdef` as a `kind: "enum"` type-pool entry. Width
  /// of the underlying int is derived from the widest IntegerAttr in
  /// the variants map. `variantsMap` is stored in IR as
  /// `<name> -> IntegerAttr` (DictionaryAttr keys must be strings); the
  /// emitted UHDI form inverts that to `"<int>" -> "<name>"` to match
  /// HGLDD's `enum_defs` shape. Idempotent across multiple references.
  std::string internEnumDef(debug::EnumDefOp op) {
    std::string id = enumTypeId(op);
    if (entries.get(id))
      return id;
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
    entries[id] = Object{{"kind", "enum"},
                         {"underlyingTypeRef", underlyingId},
                         {"variants", std::move(variantsJson)}};
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
      // dbg.subfield wraps the leaf-value with metadata (typeName, params,
      // enumDef). Pass the wrapped value to internValueType so an
      // enum-tagged subfield resolves to its enum-type pool entry, not
      // the raw integer. unwrapDbgSubField is still needed for the
      // BlockArgument check below — otherwise an input port flowing
      // through a SubFieldOp loses its `flipped` marker.
      std::string ft = internValueType(field, childHint);
      mlir::Value innerField = unwrapDbgSubField(field);
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
/// cast to int64_t never sign-flips), LeafBitVec otherwise. Neither
/// variant carries a `width` key — schema is additionalProperties:false
/// and width is implicit from the enclosing variable's typeRef
/// (LeafConst) or the bit-string length (LeafBitVec).
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

class ExpressionPool {
public:
  /// uhdi Operand for `value`: prefers a sigName leaf when one resolves;
  /// aggregates / comb ops materialise a fresh pool entry and return
  /// `{exprRef: id}`. `leafNameFn` is the scalar-signal Verilog resolver.
  Object operandFor(mlir::Value value,
                    llvm::function_ref<StringAttr(mlir::Value)> leafNameFn) {
    // Look through dbg.subfield: a transparent metadata wrapper added by
    // LowerIntrinsics on circt_debug_subfield refs. Without this, the
    // bundle-field operands of a `dbg.struct` post-LowerTypes resolve to
    // empty sigNames (the SubFieldOp result has type !dbg.subfield, which
    // sv::resolveVerilogName doesn't know).
    value = unwrapDbgSubField(value);
    if (auto nameAttr = leafNameFn(value))
      return Object{{"sigName", nameAttr.getValue().str()}};
    auto opResult = dyn_cast<OpResult>(value);
    if (!opResult)
      return Object{{"sigName", ""}};
    Operation *defOp = opResult.getOwner();

    // Reserve the id BEFORE recursing so outer expressions get the
    // smaller index than the inner ones they depend on (matches HGLDD
    // ordering and avoids forward refs in the diff).
    auto wrap = [&](StringRef opcode, auto fillOperands) -> Object {
      std::string id;
      do {
        id = "expr_" + std::to_string(counter++);
      } while (entries.get(id));
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

    // dbg.expression result -> reference into the expressions pool by
    // its uhdi.stable_id (the entry itself is emitted in collect()).
    if (auto e = dyn_cast<debug::ExpressionOp>(defOp))
      if (auto id = e->getAttrOfType<StringAttr>(kUhdiStableIdAttr))
        return Object{{"exprRef", id.getValue().str()}};
    if (auto s = dyn_cast<debug::StructOp>(defOp))
      return wrap("'{", fillFrom(s.getFields()));
    if (auto a = dyn_cast<debug::ArrayOp>(defOp))
      return wrap("'{", fillFrom(a.getElements()));
    if (auto c = dyn_cast<hw::ConstantOp>(defOp))
      return renderConstant(c.getValue());
    if (auto concat = dyn_cast<comb::ConcatOp>(defOp))
      return wrap("{}", fillFrom(concat.getOperands()));
    if (auto repl = dyn_cast<comb::ReplicateOp>(defOp))
      return wrap("R{}", [&](Array &out) {
        out.push_back(operandFor(repl.getInput(), leafNameFn));
        out.push_back(Object{{"constant", int64_t(repl.getMultiple())}});
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

  /// Insert an externally-keyed entry (used for `dbg.expression` ops
  /// whose key is the uhdi.stable_id rather than an auto-generated
  /// `expr_N`). No-op if the key is already populated.
  void insertEntry(StringRef key, Object entry) {
    if (!entries.get(key))
      entries[key] = std::move(entry);
  }

private:
  Object entries;
  unsigned counter = 0;
};

//===----------------------------------------------------------------------===//
// Verilog-name resolver
//===----------------------------------------------------------------------===//

/// Read the per-repr `name` from an op's uhdi.repr_entry stamp, if any.
static StringAttr readReprName(Operation *op, StringRef reprKey) {
  auto dict = op->getAttrOfType<DictionaryAttr>(kUhdiReprEntryAttr);
  if (!dict)
    return {};
  auto inner = dict.getNamed(reprKey);
  if (!inner)
    return {};
  if (auto innerDict = dyn_cast<DictionaryAttr>(inner->getValue()))
    return innerDict.getAs<StringAttr>("name");
  return {};
}

/// Live IR walk wins over the snapshot stamp (the walk sees ExportVerilog's
/// freshly spilled wires; a stale stamp would shadow them).
static StringAttr bestVerilogName(Operation *op, mlir::Value value) {
  if (auto name = sv::resolveVerilogName(value))
    return name;
  return readReprName(op, kUhdiVerilogRepr);
}

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
    if (auto id = p->getAttrOfType<StringAttr>(kUhdiStableIdAttr))
      return id.getValue();
    if (isa<hw::HWModuleOp, hw::HWModuleExternOp>(p))
      break;
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
/// receives one extra `variables[id]` entry per `dbg.subfield` leaf so
/// that consumers see per-field source-language metadata (typeName /
/// enum typeRef) without recursing through the parent's expression
/// tree themselves.
static Object emitVariable(
    debug::VariableOp var, EmitState &s,
    SmallVectorImpl<std::pair<std::string, Object>> *syntheticOut = nullptr) {
  Object entry;
  // Hint nested struct/array ids with `<Module>_<var>[_field]...` to
  // match HGLDD's naming so the canonical diff stays name-equal.
  std::string structHint;
  if (isa_and_nonnull<debug::StructOp, debug::ArrayOp>(
          var.getValue().getDefiningOp())) {
    if (auto mod = var->getParentOfType<hw::HWModuleOp>())
      structHint = (mod.getNameAttr().getValue() + "_" + var.getName()).str();
    else
      structHint = var.getName().str();
  }
  // typeRef: an enumDef-tagged dbg.variable overrides the raw value
  // type with the enum type-pool entry; otherwise the value's own type
  // (or aggregate structure) wins.
  entry["typeRef"] = [&]() -> std::string {
    if (mlir::Value e = var.getEnumDef())
      if (auto edOp = e.getDefiningOp<debug::EnumDefOp>())
        return s.types.internEnumDef(edOp);
    return s.types.internValueType(var.getValue(), structHint);
  }();
  if (StringRef owner = ownerScopeId(var); !owner.empty())
    entry["ownerScopeRef"] = owner.str();

  // BlockArgument of an hw.module is always an input port; everything else
  // is a node (named wire / reg / intermediate).
  bool isPort = false;
  if (auto blockArg = dyn_cast<BlockArgument>(var.getValue()))
    isPort = isa<hw::HWModuleOp>(blockArg.getOwner()->getParentOp());
  entry["bindKind"] = isPort ? "port" : "node";
  if (isPort)
    entry["direction"] = "input";

  Object reprs;
  Object chisel{{"name", var.getName().str()}};
  if (auto loc = s.chiselLoc(var.getLoc()))
    chisel["location"] = std::move(*loc);
  if (auto slt =
          renderSourceLangType(var.getTypeNameAttr(), var.getParamsAttr()))
    chisel["sourceLangType"] = std::move(*slt);
  // Spec linter wants `status` set explicitly; omitted reads as "emitter
  // didn't check" rather than "preserved".
  chisel["status"] = "preserved";
  reprs[kChiselRepr] = std::move(chisel);

  // Verilog value: aggregate -> exprRef pool; constant -> constant /
  // bitVector; otherwise -> sigName via bestVerilogName with operandFor
  // as the DCE'd-/inlined fallback.
  Object verilog;
  bool haveValue = false;
  // Bundle fields (the only place dbg.subfield surfaces) end up as
  // wires aliasing flat module ports post-LowerTypes: prefer the port
  // name over the lowering-introduced wire identifier.
  auto leafName = [](mlir::Value v) { return resolveBundleFieldName(v); };
  bool isAggregate = isa_and_nonnull<debug::StructOp, debug::ArrayOp>(
      var.getValue().getDefiningOp());

  if (isAggregate) {
    verilog["value"] = s.exprs.operandFor(var.getValue(), leafName);
    haveValue = true;
  } else if (auto opResult = dyn_cast<OpResult>(var.getValue());
             opResult && isa_and_nonnull<hw::ConstantOp>(opResult.getOwner())) {
    Object lit =
        renderConstant(cast<hw::ConstantOp>(opResult.getOwner()).getValue());
    verilog["value"] = std::move(lit);
    haveValue = true;
  } else if (auto vname =
                 bestVerilogName(var, unwrapDbgSubField(var.getValue()))) {
    verilog["name"] = vname.getValue().str();
    verilog["value"] = Object{{"sigName", vname.getValue().str()}};
    haveValue = true;
  } else if (dyn_cast<OpResult>(var.getValue())) {
    Object expr = s.exprs.operandFor(var.getValue(), leafName);
    bool trivialEmpty = (expr.size() == 1) &&
                        (expr.find("sigName") != expr.end()) &&
                        (expr["sigName"] == "");
    if (!trivialEmpty) {
      verilog["value"] = std::move(expr);
      haveValue = true;
    }
  }
  if (haveValue) {
    if (auto loc = s.verilogLoc(var.getLoc()))
      verilog["location"] = std::move(*loc);
    verilog["status"] = "preserved";
    reprs[kUhdiVerilogRepr] = std::move(verilog);
  }
  entry["representations"] = std::move(reprs);

  // Materialise synthetic per-field Variables for aggregate parents.
  // Naming structure:
  //   dbg.struct.$names  carries the BARE field name ("a"/"b"/"op")
  //   dbg.subfield.$name carries the DOTTED full path ("io.in.a")
  // We always take bare names from the enclosing struct/array and use
  // the wrapping subfield (if any) only for its source-language
  // metadata. Synthetic ids are joined with `__` so consumers can
  // rpartition any nesting level back into (parent_id, leaf_field)
  // unambiguously even when field names themselves contain `_` or `.`.
  // The emitted Variable carries only a chisel repr — the flat HDL
  // signal is already exposed via the parent's exprRef expansion, so
  // the verilog repr is intentionally omitted.
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

        // Unwrap one subfield layer to read metadata (typeName /
        // params / enumDef). Inner value below is what we recurse on.
        debug::SubFieldOp sf = findDbgSubField(fieldVal);
        mlir::Value innerVal = sf ? sf.getValue() : fieldVal;

        Object synEntry;
        synEntry["typeRef"] = [&]() -> std::string {
          if (sf)
            if (mlir::Value e = sf.getEnumDef())
              if (auto edOp = e.getDefiningOp<debug::EnumDefOp>())
                return s.types.internEnumDef(edOp);
          return s.types.internValueType(innerVal, parentId.getValue());
        }();
        if (!ownerScope.empty())
          synEntry["ownerScopeRef"] = ownerScope.str();
        synEntry["bindKind"] = "synthetic";
        Object synChisel{{"name", bareName.str()}};
        // Prefer the SubFieldOp's own location (carries source-loc
        // attached to the originating circt_debug_subfield intrinsic);
        // fall back to the parent Variable's loc so a leaf without a
        // subfield wrapper still gets a usable hgl_loc.
        Location locForLoc = sf ? sf.getLoc() : var.getLoc();
        if (auto loc = s.chiselLoc(locForLoc))
          synChisel["location"] = std::move(*loc);
        if (sf)
          if (auto slt = renderSourceLangType(sf.getTypeNameAttr(),
                                              sf.getParamsAttr()))
            synChisel["sourceLangType"] = std::move(*slt);
        synChisel["status"] = "preserved";
        Object synReprs;
        synReprs[kChiselRepr] = std::move(synChisel);
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
      // since `var.getValue()` is the struct/array itself (not a
      // subfield wrapping it).
      if (auto opR = dyn_cast<OpResult>(var.getValue())) {
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

/// One `scopes[id]` entry for an `hw.module`.
static Object emitModuleScope(hw::HWModuleOp module, EmitState &s) {
  StringRef sym = module.getNameAttr().getValue();
  StringRef vname = sym;
  if (auto attr = module->getAttrOfType<StringAttr>("verilogName"))
    vname = attr.getValue();
  Object entry{{"name", sym.str()}, {"kind", "module"}};
  Object reprs;
  Object chiselRepr = reprDict(sym, s.chiselLoc(module.getLoc()));
  // First dbg.moduleinfo inside this module supplies the source-level
  // type name + constructor params. There is at most one per module by
  // construction (DebugMetaEmitter emits a single
  // circt_debug_moduleinfo intrinsic per Chisel module).
  module.walk([&](debug::ModuleInfoOp mi) {
    if (auto slt =
            renderSourceLangType(mi.getTypeNameAttr(), mi.getParamsAttr()))
      chiselRepr["sourceLangType"] = std::move(*slt);
    return WalkResult::interrupt();
  });
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
  reprs[kChiselRepr] =
      reprDict(scope.getInstanceName(), s.chiselLoc(scope.getLoc()));
  if (auto vname = readReprName(scope, kUhdiVerilogRepr))
    reprs[kUhdiVerilogRepr] = Object{{"name", vname.getValue().str()}};
  entry["representations"] = std::move(reprs);
  if (auto module = scope->getParentOfType<hw::HWModuleOp>())
    entry["containerScopeRef"] = module.getNameAttr().getValue().str();
  return entry;
}

//===----------------------------------------------------------------------===//
// Scope body
//===----------------------------------------------------------------------===//

struct VarRefIndex {
  llvm::DenseMap<std::pair<mlir::Value, llvm::StringRef>, std::string> map;
};

static void indexStructFields(VarRefIndex &idx, mlir::Value scope,
                              StringRef parentName, debug::StructOp structOp) {
  for (auto [nameAttr, fieldVal] :
       llvm::zip(structOp.getNames(), structOp.getFields())) {
    StringRef fieldName = cast<StringAttr>(nameAttr).getValue();
    std::string path = (parentName + "." + fieldName).str();
    mlir::Value innerField = unwrapDbgSubField(fieldVal);
    if (auto vname = resolveBundleFieldName(innerField))
      idx.map.try_emplace({scope, path}, vname.getValue().str());
    if (auto *fieldDefOp = innerField.getDefiningOp())
      if (auto nested = dyn_cast<debug::StructOp>(fieldDefOp))
        indexStructFields(idx, scope, path, nested);
  }
}

static void addVarToIndex(VarRefIndex &idx, debug::VariableOp var,
                          hw::HWModuleOp mod) {
  auto id = var->getAttrOfType<StringAttr>(kUhdiStableIdAttr);
  if (!id)
    return;
  if (var.getName().empty())
    return;
  mlir::Value scope = var.getScope();
  auto key = std::make_pair(scope, var.getName());
  auto [it, inserted] = idx.map.try_emplace(key, id.getValue().str());
  if (!inserted && it->second != id.getValue()) {
    var.emitWarning() << "uhdi: dbg.variable name '" << var.getName()
                      << "' collides within module '" << mod.getName()
                      << "'; body varRef tokens for this name will be "
                         "left unresolved";
    it->second = "";
  }
  if (auto *defOp = var.getValue().getDefiningOp())
    if (auto structOp = dyn_cast<debug::StructOp>(defOp))
      indexStructFields(idx, scope, var.getName(), structOp);
}

static void addExprToIndex(VarRefIndex &idx, debug::ExpressionOp expr,
                           hw::HWModuleOp mod) {
  auto id = expr->getAttrOfType<StringAttr>(kUhdiStableIdAttr);
  if (!id)
    return;
  mlir::Value scope = expr.getScope();
  auto key = std::make_pair(scope, expr.getName());
  auto [it, inserted] = idx.map.try_emplace(key, id.getValue().str());
  if (!inserted && it->second != id.getValue()) {
    expr.emitWarning() << "uhdi: dbg.expression name '" << expr.getName()
                       << "' collides in module '" << mod.getName()
                       << "'; refs will be left unresolved";
    it->second = "";
  }
}

static std::string resolveVarRef(const VarRefIndex &index, StringRef name,
                                 mlir::Value currentScope) {
  if (auto it = index.map.find({currentScope, name}); it != index.map.end())
    if (!it->second.empty())
      return it->second;
  if (currentScope)
    if (auto it = index.map.find({mlir::Value(), name}); it != index.map.end())
      if (!it->second.empty())
        return it->second;
  return name.str();
}

static Object emitBreakpointMeta(DictionaryAttr bp, const VarRefIndex &varIndex,
                                 mlir::Value currentScope) {
  if (!bp)
    return {};
  auto enable = bp.getAs<StringAttr>("enableRef");
  if (!enable)
    return {};
  std::string resolved;
  SmallVector<StringRef, 4> tokens;
  enable.getValue().split(tokens, '&', -1, /*KeepEmpty=*/false);
  for (auto tok : tokens) {
    bool negated = tok.starts_with("!");
    if (negated)
      tok = tok.drop_front();
    if (!resolved.empty())
      resolved += '&';
    if (negated)
      resolved += '!';
    resolved += resolveVarRef(varIndex, tok, currentScope);
  }
  return Object{{"enableRef", resolved}};
}

/// Per-statement `locations` map (chisel/verilog).
static void attachLocations(Object &entry, Operation *op, EmitState &s) {
  Object locs;
  if (auto loc = s.chiselLoc(op->getLoc()))
    locs[kChiselRepr] = std::move(*loc);
  if (auto loc = s.verilogLoc(op->getLoc()))
    locs[kUhdiVerilogRepr] = std::move(*loc);
  if (!locs.empty())
    entry["locations"] = std::move(locs);
}

static Array emitStatementList(Region &region, const VarRefIndex &varIndex,
                               EmitState &s, mlir::Value currentScope) {
  Array body;
  if (region.empty())
    return body;
  for (Operation &op : region.front()) {
    Object entry;
    if (auto connect = dyn_cast<debug::ConnectStmtOp>(op)) {
      entry["kind"] = "connect";
      entry["varRef"] =
          resolveVarRef(varIndex, connect.getVarRef(), currentScope);
      entry["valueRef"] =
          Object{{"varRef", resolveVarRef(varIndex, connect.getValueRef(),
                                          currentScope)}};
      if (auto bp =
              emitBreakpointMeta(connect.getBpAttr(), varIndex, currentScope);
          !bp.empty())
        entry["bp"] = std::move(bp);
    } else if (auto block = dyn_cast<debug::SubBlockOp>(op)) {
      entry["kind"] = "block";
      entry["guardRef"] =
          resolveVarRef(varIndex, block.getGuardRef(), currentScope);
      if (block.getNegated())
        entry["negated"] = true;
      entry["body"] =
          emitStatementList(block.getBody(), varIndex, s, currentScope);
    } else if (auto decl = dyn_cast<debug::DeclStmtOp>(op)) {
      entry["kind"] = "decl";
      entry["varRef"] = resolveVarRef(varIndex, decl.getVarRef(), currentScope);
    } else {
      continue;
    }
    attachLocations(entry, &op, s);
    body.push_back(std::move(entry));
  }
  return body;
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

  // Pre-pass: intern every dbg.enumdef so any dbg.subfield /
  // dbg.variable later referencing one resolves to a ready-made
  // type-pool entry. Canonicalizer dedups identical EnumDefOps; this
  // walk is idempotent thanks to internEnumDef's entries-already-
  // present check.
  top.walk([&](debug::EnumDefOp edOp) { s.types.internEnumDef(edOp); });

  // 2. One whole-circuit walk that does step 2's variable/scope/expression
  // emission AND collects per-module indexes consumed by steps 3 and 4
  // (port coverage, varRef map, root block) — so steps 3/4 don't re-walk.
  llvm::StringMap<Array> orderedVarsByScope;
  llvm::DenseMap<hw::HWModuleOp, llvm::DenseSet<unsigned>> coveredPortsByMod;
  llvm::DenseMap<hw::HWModuleOp, VarRefIndex> varRefIndexByMod;
  llvm::DenseMap<hw::HWModuleOp, llvm::SmallVector<debug::RootBlockOp, 1>>
      rootBlocksByMod;
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
        addVarToIndex(varRefIndexByMod[mod], var, mod);
        if (auto blockArg = dyn_cast<BlockArgument>(var.getValue()))
          if (mod.getBodyRegion().hasOneBlock() &&
              blockArg.getOwner() == &mod.getBodyRegion().front()) {
            // Body-block args are indexed by input-id (HWOpInterfaces.td);
            // coveredPortsByMod is consumed in synthesizePortVars against
            // absolute port-ids, so translate here.
            auto modType = mod.getHWModuleType();
            coveredPortsByMod[mod].insert(
                modType.getPortIdForInputId(blockArg.getArgNumber()));
          }
      }
      return;
    }
    if (auto expr = dyn_cast<debug::ExpressionOp>(inner)) {
      // dbg.expression: compound expression captured by capture-when for
      // `when` guards / non-trivial valueRefs. Serialise into the
      // expressions pool keyed by stable_id so statement-tree refs
      // resolve into a real spec §5 opcode tree.
      auto id = expr->getAttrOfType<StringAttr>(kUhdiStableIdAttr);
      if (!id)
        return;
      Array operands;
      auto leafName = [](mlir::Value v) { return resolveBundleFieldName(v); };
      for (auto operand : expr.getExprOperands())
        operands.push_back(s.exprs.operandFor(operand, leafName));
      s.exprs.insertEntry(id.getValue(),
                          Object{{"opcode", expr.getOpcode().str()},
                                 {"operands", std::move(operands)}});
      if (auto mod = expr->getParentOfType<hw::HWModuleOp>())
        addExprToIndex(varRefIndexByMod[mod], expr, mod);
      return;
    }
    if (auto rb = dyn_cast<debug::RootBlockOp>(inner))
      if (auto mod = rb->getParentOfType<hw::HWModuleOp>())
        rootBlocksByMod[mod].push_back(rb);
  });

  auto stableIdOf = [](mlir::Value v) -> StringRef {
    if (!v)
      return {};
    if (auto *def = v.getDefiningOp())
      if (auto id = def->getAttrOfType<StringAttr>(kUhdiStableIdAttr))
        return id.getValue();
    return {};
  };
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

  // 4. Per-module body[] from dbg.rootblock (placed by capture-when).
  for (auto mod : top.getOps<hw::HWModuleOp>()) {
    auto rbsIt = rootBlocksByMod.find(mod);
    if (rbsIt == rootBlocksByMod.end())
      continue;
    for (auto rb : rbsIt->second) {
      mlir::Value rbScope = rb.getScope();
      StringRef targetKey =
          rbScope ? stableIdOf(rbScope) : mod.getNameAttr().getValue();
      withScopeEntry(targetKey, [&](Object &obj) {
        Array body =
            emitStatementList(rb.getBody(), varRefIndexByMod[mod], s, rbScope);
        if (!body.empty())
          obj["body"] = std::move(body);
      });
    }
  }

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
