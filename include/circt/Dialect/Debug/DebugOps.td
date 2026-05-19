//===- DebugOps.td - Debug dialect operations --------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_DEBUG_DEBUGOPS_TD
#define CIRCT_DIALECT_DEBUG_DEBUGOPS_TD

include "circt/Dialect/Debug/DebugAttributes.td"
include "circt/Dialect/Debug/DebugDialect.td"
include "circt/Dialect/Debug/DebugTypes.td"
include "mlir/Interfaces/InferTypeOpInterface.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/IR/OpBase.td"

class DebugOp<string mnemonic, list<Trait> traits = []> :
  Op<DebugDialect, mnemonic, traits>;


def ScopeOp : DebugOp<"scope"> {
  let summary = "Define a scope for debug values";
  let description = [{
    Creates an additional level of hierarchy in the DI, a "scope", which can be
    used to group variables and other scopes.

    Operations such as `hw.module` introduce an implicit scope. All debug
    operations within a module are added to that implicit scope, unless they
    have an explicit `scope` operand. Providing an explicit scope can be used to
    represent inlined modules.

    Scopes in DI do not necessarily have to correspond to levels of a module
    hierarchy. They can also be used to model things like control flow scopes,
    call stacks, and other source-language concepts.

    The `scope` operand of any debug dialect operation must be defined locally
    by a `dbg.scope` operation. It cannot be a block argument. (This is intended
    as a temporary restriction, to be lifted in the future.)
  }];
  let arguments = (ins
    StrAttr:$instanceName,
    StrAttr:$moduleName,
    Optional<ScopeType>:$scope
  );
  let results = (outs ScopeType:$result);
  let assemblyFormat = [{
    $instanceName `,` $moduleName (`scope` $scope^)? attr-dict
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

    See the rationale for examples and details. See the `dbg.scope` operation
    for additional details on how to use the `scope` operand.
  }];
  let arguments = (ins
    StrAttr:$name,
    AnyType:$value,
    Optional<ScopeType>:$scope
  );
  let assemblyFormat = [{
    $name `,` $value (`scope` $scope^)? attr-dict `:` type($value)
  }];
}


def ValueOp : DebugOp<"value"> {
  let summary = "Attach source-language metadata to a value";
  let description = [{
    Annotates an SSA value with additional source-language information: the
    source type name, its constructor parameters, and a dedicated location.
    The result is a metadata wrapper accepted wherever other debug operations
    accept plain values (`dbg.variable`, `dbg.struct`, `dbg.array`); consumers
    unwrap it to reach the underlying value. Keeping the metadata on a
    separate wrapper keeps `dbg.variable` and the aggregate ops orthogonal to
    source-language type information.

    An enum-typed value embeds a `dbg.enum`, so no enum linkage is carried on
    the wrapper itself. Freshly-created ops with no users are tolerated by
    the verifier to accommodate construction patterns; any surviving user
    must be a debug-dialect op.
  }];
  let arguments = (ins
    AnyType:$value,
    OptionalAttr<StrAttr>:$typeName,
    OptionalAttr<ArrayAttr>:$params
  );
  let results = (outs ValueType:$result);
  let assemblyFormat = [{
    $value (`typeName` $typeName^)? (`params` $params^)?
        attr-dict `:` type($value)
  }];
  let hasVerifier = 1;
}

def ExpressionOp : DebugOp<"expression", [Pure, AttrSizedOperandSegments]> {
  let summary = "Named compound expression for source-level debug info";
  let description = [{
    Captures a compound expression (combinational op tree) as a value-
    tracking debug entity, sibling to `dbg.variable`. `firrtl-uhdi-capture-
    when` materialises one for a compound `when` guard, and the guarded
    `dbg.subblock` takes its result as the condition operand.

    `name` is the cross-reference identifier; `firrtl-uhdi-init` stamps a
    matching `uhdi.stable_id` for downstream consumers. `opcode` matches
    the UHDI expressions-pool opcode enum (`&&`, `||`, `!`, `==`, `<`,
    arithmetic, ...). Value operands track through RAUW so the expression
    survives ExpandWhens / LowerTypes / FIRRTL-to-HW lowering.

    `Pure` is only sound because the result is used. Referring to this op
    by name instead would leave it without uses, and `isOpTriviallyDead`
    would then delete it out from under the statement tree.
  }];
  let arguments = (ins
    StrAttr:$name,
    StrAttr:$opcode,
    Variadic<AnyType>:$exprOperands,
    Optional<ScopeType>:$scope
  );
  let results = (outs RefType:$result);
  let assemblyFormat = [{
    $name `,` `opcode` $opcode (`,` `operands` `(` $exprOperands^ `:` type($exprOperands) `)`)?
    (`scope` $scope^)? attr-dict
  }];
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

    `enumTypeName` is the source-language type name; the optional `fqn` is the
    fully-qualified name used as the stable type-pool key. Consumers use it to
    dedup identical enums that appear at many use sites or across modules.

    This models tag-only enums: `variantsMap` is keyed by variant name with
    `IntegerAttr` tags and has no slot for per-variant payload types, so
    data-carrying variants are out of scope.
  }];
  let arguments = (ins
    AnyType:$value,
    StrAttr:$enumTypeName,
    DictionaryAttr:$variantsMap,
    OptionalAttr<StrAttr>:$fqn
  );
  let results = (outs EnumType:$result);
  let assemblyFormat = [{
    $value `,` $enumTypeName `,` $variantsMap (`fqn` $fqn^)? attr-dict
        `:` type($value)
  }];
  let hasVerifier = 1;
}

def StructOp : DebugOp<"struct", [
  Pure,
  PredOpTrait<"number of fields and names match",
    CPred<"$fields.size() == $names.size()">>
]> {
  let summary = "Aggregate values into a struct";
  let description = [{
    Creates a struct aggregate from a list of names and values. The `dbg.struct`
    operation allows for struct-like source language values to be captured in
    the debug info. This includes structs, unions, bidirectional bundles,
    interfaces, classes, and other similar structures.

    See the rationale for examples and details.
  }];
  let arguments = (ins Variadic<AnyType>:$fields, StrArrayAttr:$names);
  let results = (outs StructType:$result);
  let hasCustomAssemblyFormat = 1;
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

//===----------------------------------------------------------------------===//
// Scope body -- statement tree that survives ExpandWhens
//===----------------------------------------------------------------------===//
//
// Produced by `firrtl-uhdi-capture-when` before ExpandWhens destroys the
// when/else tree. `firrtl-uhdi-init` later assigns the stable IDs the
// emitter resolves at serialization time.
//
// These are operations rather than attributes on the hardware they
// describe because statement order carries meaning -- it is what encodes
// FIRRTL's last-connect-wins -- and there is no ordered carrier to attach
// an attribute to. An `hw.module` body is a `RegionKind::Graph` region, so
// its operations have no program order at all; the regions below declare
// no RegionKindInterface and are therefore SSACFG, where the order of the
// operation list is meaningful and verified. This is the one structural
// difference from LLVM's model, where a scope attribute can ride on an
// instruction because a basic block is already an ordered list.
//
// References into the value-mapping ops above take three forms, chosen by
// what the referent is rather than by convenience: an SSA operand when the
// referent is an operation in this module, a symbol when it lives in
// another module, and a typed attribute when it is a name whose defining
// operation carries no result to point at.

def RootBlockOp : DebugOp<"rootblock", [NoTerminator]> {
  let summary = "Root statement tree for an hw.module or dbg.scope";
  let description = [{
    Region-containing op holding the ordered statement tree captured by
    `firrtl-uhdi-capture-when`. Capture-when produces exactly one per
    enclosing module / scope, but `firrtl-inliner` may clone additional
    rootblocks under a caller; downstream UhdiInit / EmitUHDI must tolerate
    or merge duplicates. Body may only contain `dbg.subblock`,
    `dbg.connect_stmt`, or `dbg.decl_stmt`; order is significant (preserves
    FIRRTL last-connect semantics). Serialised as the `body` array on the
    owning scope entry.
  }];
  let arguments = (ins Optional<ScopeType>:$scope);
  let results = (outs);
  let regions = (region AnyRegion:$body);
  let assemblyFormat = "(`scope` $scope^)? attr-dict-with-keyword $body";
  let hasVerifier = 1;
}

def SubBlockOp : DebugOp<"subblock", [NoTerminator, ParentOneOf<["RootBlockOp", "SubBlockOp"]>]> {
  let summary = "Guarded group of statements within a rootblock";
  let description = [{
    Groups a subtree of `dbg.rootblock` statements under a single
    boolean condition. Mirrors one `when` / `else` branch, or the implicit
    priority of a reset over the connects it overrides. `negated = true`
    marks the else arm. Serialised as `kind: "block"` (the IR name avoids
    confusion with `dbg.scope` and the MLIR `Block` primitive).
    Body may only contain `dbg.subblock`, `dbg.connect_stmt`, or
    `dbg.decl_stmt`.

    The condition is given exactly one of three ways: `condition` when a
    `dbg.expression` was materialised for it, `conditionRef` when it is a
    named variable, or `#dbg.opaque_cond` when it could not be reduced to
    either. There is no fourth "unrecorded" state -- a subblock always
    says under what it applies, so a consumer never has to guess whether
    the statements below are conditional.
  }];
  let arguments = (ins
    Optional<RefType>:$condition,
    OptionalAttr<AnyAttrOf<[VarRefAttr, OpaqueCondAttr]>>:$conditionRef,
    DefaultValuedAttr<BoolAttr, "false">:$negated
  );
  let results = (outs);
  let regions = (region AnyRegion:$body);
  let assemblyFormat = [{
    (`condition` $condition^)? (`conditionRef` $conditionRef^)?
    (`negated` $negated^)? attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

def ConnectStmtOp : DebugOp<"connect_stmt", [ParentOneOf<["RootBlockOp", "SubBlockOp"]>]> {
  let summary = "Statement-level record of a `firrtl.connect`";
  let description = [{
    Records a single source-level connect, naming the two sides the way
    `firrtl.connect` does. `dest` is the assignment target. `src` is the
    source: a `#dbg.varref` when it has a name, `#dbg.const_source` when
    it is a constant or an unnamed temporary, or a symbol reference to an
    `hw.hierpath` when it lives in another module.

    The condition under which the connect happens is not recorded here.
    It is the conjunction of the enclosing `dbg.subblock` conditions, and
    duplicating it on the statement would be a second representation of
    the same fact -- one that has already been observed to drift from the
    tree it duplicates.
  }];
  let arguments = (ins
    VarRefAttr:$dest,
    AnyAttrOf<[VarRefAttr, ConstSourceAttr, FlatSymbolRefAttr]>:$src
  );
  let assemblyFormat = [{
    qualified($dest) `=` $src attr-dict
  }];
}

def DeclStmtOp : DebugOp<"decl_stmt", [ParentOneOf<["RootBlockOp", "SubBlockOp"]>]> {
  let summary = "Statement-level declaration marker";
  let description = [{
    Marks the point at which `target` becomes visible to a debugger.
    Useful for step-in behaviour (stop at declaration) and for
    differentiating a wire declaration from its first connect.

    Named `target` rather than `dest` because this is not an assignment:
    nothing flows into the variable here, it merely comes into scope.
  }];
  let arguments = (ins VarRefAttr:$target);
  let assemblyFormat = "qualified($target) attr-dict";
}

#endif // CIRCT_DIALECT_DEBUG_DEBUGOPS_TD
