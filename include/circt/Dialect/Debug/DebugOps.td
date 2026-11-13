//===- DebugOps.td - Debug dialect operations --------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_DEBUG_DEBUGOPS_TD
#define CIRCT_DIALECT_DEBUG_DEBUGOPS_TD

include "circt/Types.td"
include "circt/Dialect/Debug/DebugDialect.td"
include "circt/Dialect/Debug/DebugTypes.td"
include "circt/Dialect/HW/HWAttributesNaming.td"
include "circt/Dialect/HW/HWOpInterfaces.td"
include "mlir/Interfaces/InferTypeOpInterface.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/IR/EnumAttr.td"
include "mlir/IR/OpBase.td"
include "mlir/IR/SymbolInterfaces.td"

def DebugInnerSymAttr : Attr<CPred<"llvm::isa<::circt::hw::InnerSymAttr>($_self)">,
                             "HW inner symbol"> {
  let storageType = "::circt::hw::InnerSymAttr";
  let returnType = "::circt::hw::InnerSymAttr";
  let convertFromStorage = "$_self";
}

class DebugOp<string mnemonic, list<Trait> traits = []> :
  Op<DebugDialect, mnemonic, traits>;

def VariableKind : I32EnumAttr<"VariableKind",
    "what the source declares a variable as", [
      I32EnumAttrCase<"Input", 0, "input">,
      I32EnumAttrCase<"Output", 1, "output">,
      I32EnumAttrCase<"InOut", 2, "inout">,
      I32EnumAttrCase<"Wire", 3, "wire">,
      I32EnumAttrCase<"Reg", 4, "reg">,
      I32EnumAttrCase<"Node", 5, "node">,
      I32EnumAttrCase<"Instance", 6, "instance">
    ]> {
  let cppNamespace = "circt::debug";
}


def ScopeOp : DebugOp<"scope", [
    DeclareOpInterfaceMethods<InnerSymbol, ["getTargetResultIndex"]>]> {
  let summary = "Define a scope for debug values";
  let description = [{
    Creates an additional level of hierarchy in the DI, a "scope", which can be
    used to group variables and other scopes.

    Operations such as `hw.module` introduce an implicit scope. All debug
    operations within a module are added to that implicit scope, unless they
    have an explicit `scope` operand. Providing an explicit scope can be used to
    represent inlined modules.

    `def` references a global `dbg.module` describing the source module
    represented by this scope. The descriptor can outlive its hardware module.

    Scopes in DI do not necessarily have to correspond to levels of a module
    hierarchy. They can also be used to model things like control flow scopes,
    call stacks, and other source-language concepts.

    The `scope` operand of any debug dialect operation must be defined locally
    by a `dbg.scope` operation. It cannot be a block argument. (This is intended
    as a temporary restriction, to be lifted in the future.)
  }];
  let arguments = (ins
    StrAttr:$name,
    Optional<ScopeType>:$scope,
    OptionalAttr<DebugInnerSymAttr>:$inner_sym,
    OptionalAttr<FlatSymbolRefAttr>:$def
  );
  let hasVerifier = 1;
  let builders = [OpBuilder<(ins "StringAttr":$name, "Value":$scope), [{
    build($_builder, $_state, ScopeType::get($_builder.getContext()),
          name, scope, hw::InnerSymAttr(), FlatSymbolRefAttr());
  }]>, OpBuilder<(ins "Type":$resultType, "StringAttr":$name,
      "Value":$scope, "hw::InnerSymAttr":$inner_sym), [{
    build($_builder, $_state, resultType, name, scope,
          inner_sym, FlatSymbolRefAttr());
  }]>];
  let results = (outs ScopeType:$result);
  let assemblyFormat = [{
    $name (`scope` $scope^)?
    (`sym` $inner_sym^)? (`def` $def^)? attr-dict
  }];
}


def VariableOp : DebugOp<"variable"> {
  let summary = "A named value to be captured in debug info";
  let description = [{
    Marks a value to be tracked in DI under the given name. The `dbg.variable`
    operation is useful to represent named values in a source language. For
    example, ports, constants, parameters, variables, nodes, or name aliases can
    all be represented as a variable. In combination with `dbg.array` and
    `dbg.struct`, complex aggregate source language values can be described and
    reconstituted from individual IR values. The `dbg.variable` operation acts
    as a tracker that follows the evolution of its assigned value throughout the
    compiler's pass pipelines. The debug info analysis uses this op to populate
    a module's scope with named source language values, and to establish how
    these source language values can be reconstituted from the actual IR values
    present at the end of compilation.

    An enum-typed variable embeds a `dbg.enum` value, which carries the named
    variants. Source-language type information is not carried on the variable
    itself; wrap the value in a `dbg.value` to attach it.

    The optional `kind` is what the source declares the variable as: a port
    (`input`, `output`, `inout`, the last for analog ports), or a `wire`,
    `reg`, `node` or `instance`. Without `kind` the producer did not say, for example for
    an empty aggregate.

    See the rationale for examples and details. See the `dbg.scope` operation
    for additional details on how to use the `scope` operand.
  }];
  let arguments = (ins
    StrAttr:$name,
    AnyType:$value,
    Optional<ScopeType>:$scope,
    OptionalAttr<VariableKind>:$kind
  );
  let assemblyFormat = [{
    $name `,` $value (`scope` $scope^)? (`kind` $kind^)? attr-dict
        `:` type($value)
  }];
  let builders = [
    OpBuilder<(ins "::mlir::StringAttr":$name, "::mlir::Value":$value,
                   "::mlir::Value":$scope), [{
      build($_builder, $_state, name, value, scope, VariableKindAttr{});
    }]>,
    OpBuilder<(ins "::llvm::StringRef":$name, "::mlir::Value":$value,
                   "::mlir::Value":$scope), [{
      build($_builder, $_state, $_builder.getStringAttr(name), value, scope);
    }]>
  ];
}


def ValueOp : DebugOp<"value", [Pure,
    DeclareOpInterfaceMethods<InnerRefUserOpInterface>]> {
  let summary = "Attach source-language metadata to a value";
  let description = [{
    Annotates an SSA value or an operation selected by a hierarchy path.
    Exactly one of `value` and `path` must be present. Both forms carry
    additional source-language information: the
    source type name, language-specific data, and a dedicated location.
    The result is a metadata wrapper accepted wherever other debug operations
    accept plain values (`dbg.variable`, `dbg.struct`, `dbg.array`); consumers
    unwrap it to reach the underlying value. Keeping the metadata on a
    separate wrapper keeps `dbg.variable` and the aggregate ops orthogonal to
    source-language type information.

    `ext` is language-specific data that the compiler does not read: the
    frontend's JSON string, an object whose top-level keys start with `x-`, one
    per language.

    For an instance description, `def` references its global `dbg.module`.
    `path` identifies the hardware instance; `def` supplies source metadata.
    `def` and `type` are mutually exclusive; the source module type
    name is read from the descriptor when `def` is present.

    An enum-typed value embeds a `dbg.enum`, so no enum linkage is carried on
    the wrapper itself. Freshly-created ops with no users are tolerated by
    the verifier to accommodate construction patterns; any surviving user
    must be a debug-dialect op.
  }];
  let arguments = (ins
    Optional<AnyType>:$value,
    OptionalAttr<StrAttr>:$type,
    OptionalAttr<StrAttr>:$ext,
    OptionalAttr<FlatSymbolRefAttr>:$path,
    OptionalAttr<FlatSymbolRefAttr>:$def
  );
  let results = (outs ValueType:$result);
  let assemblyFormat = [{
    ($value^)? (`path` $path^)? (`def` $def^)?
    (`type` $type^)? (`ext` $ext^)?
    attr-dict (`:` type($value)^)?
  }];
  let builders = [OpBuilder<(ins "Value":$value, "StringAttr":$type,
                                "StringAttr":$ext), [{
    build($_builder, $_state, ValueType::get($_builder.getContext()), value,
          type, ext, FlatSymbolRefAttr(), FlatSymbolRefAttr());
  }]>, OpBuilder<(ins "Type":$resultType, "Value":$value,
      "StringAttr":$type, "StringAttr":$ext, "FlatSymbolRefAttr":$path), [{
    build($_builder, $_state, resultType, value, type, ext, path,
          FlatSymbolRefAttr());
  }]>];
  let hasVerifier = 1;
}

def EnumOp : DebugOp<"enum", [Pure]> {
  let summary = "Interpret an integer value as an enumeration";
  let description = [{
    Wraps an integer value as a tag-only (C-style) enumeration, producing an
    enum-typed debug value. Behaves like a cast: the `value` operand is the raw
    integer tag, and `variantsMap` provides the `name -> tag` mapping consumers
    use to reconstruct the named variant. The result is an ordinary value that
    can be embedded in `dbg.variable`, `dbg.struct`, and `dbg.array` just like
    any other debug value, so enum tracking needs no separate definition op,
    scope, or subfield linkage.

    `enumTypeName` is the source-language type name.

    This models tag-only enums: `variantsMap` is keyed by variant name with
    `IntegerAttr` tags and has no slot for per-variant payload types, so
    data-carrying variants are out of scope.
  }];
  let arguments = (ins
    AnyType:$value,
    StrAttr:$enumTypeName,
    DictionaryAttr:$variantsMap
  );
  let results = (outs EnumType:$result);
  let assemblyFormat = [{
    $value `,` $enumTypeName `,` $variantsMap attr-dict
        `:` type($value)
  }];
  let hasVerifier = 1;
}

def StructOp : DebugOp<"struct", [
  Pure,
  PredOpTrait<"number of fields and names match",
    CPred<"$fields.size() == $names.size()">>,
  PredOpTrait<"number of fields and flips match",
    CPred<"!$flips || $flips->size() == $fields.size()">>
]> {
  let summary = "Aggregate values into a struct";
  let description = [{
    Creates a struct aggregate from a list of names and values. The `dbg.struct`
    operation allows for struct-like source language values to be captured in
    the debug info. This includes structs, unions, bidirectional bundles,
    interfaces, classes, and other similar structures.

    The optional `flips` marks, positionally with the fields, those that are
    flipped (point against the struct's direction), as in a bidirectional
    bundle. Absent means no field is flipped.

    See the rationale for examples and details.
  }];
  let arguments = (ins
    Variadic<AnyType>:$fields,
    StrArrayAttr:$names,
    OptionalAttr<DenseBoolArrayAttr>:$flips
  );
  let results = (outs StructType:$result);
  let hasCustomAssemblyFormat = 1;
  let builders = [
    OpBuilder<(ins "::mlir::ValueRange":$fields, "::mlir::ArrayAttr":$names), [{
      build($_builder, $_state, fields, names, ::mlir::DenseBoolArrayAttr{});
    }]>
  ];
}


def ArrayOp : DebugOp<"array", [Pure, SameTypeOperands]> {
  let summary = "Aggregate values into an array";
  let description = [{
    Creates an array aggregate from a list of values. The first operand is
    placed at array index 0. The last operand is placed at the highest array
    index. The `dbg.array` operation allows for array-like source language
    values to be captured in the debug info. This includes arrays, or in the
    case of SystemVerilog, packed and unpacked arrays, lists, sequences, queues,
    FIFOs, channels, and vectors.

    See the rationale for examples and details.
  }];
  let arguments = (ins Variadic<AnyType>:$elements);
  let results = (outs ArrayType:$result);
  let hasCustomAssemblyFormat = 1;
}


def ModuleInfoOp : DebugOp<"module", [SymbolName, SymbolVisibility, Symbol]> {
  let extraClassDeclaration = [{
    bool canDiscardOnUseEmpty();
  }];
  let summary = "Describe a source module independently of its implementation";
  let description = [{
    Defines a symbol carrying a source module's type name and extension data.
    `impl` optionally references its hardware module, including top
    and external modules. This is a strong symbol reference and may retain
    otherwise unused hardware during symbol DCE.

    Instance values and inlined scopes reference this descriptor through
    `def`. When inlining deletes the hardware module, it removes the
    `impl` reference while preserving the descriptor for those users.
  }];
  let arguments = (ins SymbolNameAttr:$sym_name, StrAttr:$type,
    OptionalAttr<StrAttr>:$ext, OptionalAttr<FlatSymbolRefAttr>:$impl,
    OptionalAttr<StrAttr>:$sym_visibility);
  let hasVerifier = 1;
  let assemblyFormat = [{
    $sym_name `type` $type (`ext` $ext^)?
    (`impl` $impl^)? (`visibility` $sym_visibility^)? attr-dict
  }];
}

#endif // CIRCT_DIALECT_DEBUG_DEBUGOPS_TD
