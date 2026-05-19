//===- DebugAttributes.td - Debug dialect attributes -------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_DEBUG_DEBUGATTRIBUTES_TD
#define CIRCT_DIALECT_DEBUG_DEBUGATTRIBUTES_TD

include "circt/Dialect/Debug/DebugDialect.td"
include "mlir/IR/AttrTypeBase.td"

class DebugAttrDef<string name, string attrMnemonic>
    : AttrDef<DebugDialect, name> {
  let mnemonic = attrMnemonic;
}

def VarRefAttr : DebugAttrDef<"VarRef", "varref"> {
  let summary = "Structured reference to a debug variable or one of its parts";
  let description = [{
    Names a `dbg.variable` and, optionally, a path into the aggregate it
    wraps. `root` is the variable name; each `path` element is either a
    `StringAttr` selecting a `dbg.struct` field or an `IntegerAttr`
    selecting a `dbg.array` element.

    The path is kept structured rather than flattened into one name because
    a flattened name is ambiguous: `io_a` could be a signal genuinely named
    `io_a` or field `a` of aggregate `io`, and the separator that used to
    encode the difference varied by root kind. Consumers resolve the
    reference by walking `path` through the aggregate, so a match is
    guaranteed by construction rather than by string coincidence.
  }];
  let parameters = (ins "mlir::StringAttr":$root,
                        OptionalArrayRefParameter<"mlir::Attribute">:$path);
  let assemblyFormat = "`<` $root (`,` `[` $path^ `]`)? `>`";
  let genVerifyDecl = 1;
  let builders = [
    AttrBuilderWithInferredContext<(ins "mlir::StringAttr":$root), [{
      return $_get(root.getContext(), root, llvm::ArrayRef<mlir::Attribute>{});
    }]>
  ];
}

def ConstSourceAttr : DebugAttrDef<"ConstSource", "const_source"> {
  let summary = "Assignment source that has no named debug variable";
  let description = [{
    Marks the source of a `dbg.connect_stmt` as a constant or a compiler
    temporary that carries no source-level name. An explicit attribute
    rather than an absent operand, so that "the source is knowably
    nameless" stays distinguishable from "nothing was recorded".
  }];
}

def OpaqueCondAttr : DebugAttrDef<"OpaqueCond", "opaque_cond"> {
  let summary = "Condition that could not be reduced to a debug entity";
  let description = [{
    Marks the condition of a `dbg.subblock` as present but not reducible
    to a named variable or a materialised `dbg.expression`. Carries the
    fact that a guard exists, which a debugger needs in order to avoid
    reporting the guarded statements as unconditional.
  }];
}

#endif // CIRCT_DIALECT_DEBUG_DEBUGATTRIBUTES_TD
