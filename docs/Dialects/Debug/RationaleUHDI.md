# UHDI Rationale

This document explains the design of UHDI, the debug-info document that CIRCT
writes from the `debug` dialect, in the spirit of other [MLIR Rationale
docs](https://mlir.llvm.org/docs/Rationale/).

[TOC]

## Introduction

UHDI (Unified Hardware Debug Information) is one JSON document per
compilation. It links the design the frontend declared to the netlist the
compiler emitted. The emitter is `EmitUHDI` in `lib/Target/DebugInfo`,
registered as `circt-translate --emit-uhdi`.

| Key | Holds |
|---|---|
| `uhdi` | Format version, `<major>.<minor>`. |
| `profiles` | Optional parts of the format the document uses. |
| `files` | Every file a location refers to. A location is `[file, line, column]`. |
| `types` | The type table. |
| `original` | Modules the frontend declared, with their variables. |
| `generated` | Modules of the emitted netlist, by Verilog name. |
| `bindings` | How the variables of an original module read in a generated one. |

## Why not extend HGLDD

An HGLDD object mixes the source view and the netlist view. After dedup merges
`B` into `A`, the mapping is recovered from names. `EmitHGLDD` also drops the
frontend's type names, shows an enum as a bare integer, and gives no value to a
leaf of a packed aggregate. UHDI keeps the two views apart instead.

## The source side and the netlist side are separate

`original` describes what the frontend declared, `generated` what the compiler
emitted. Only `bindings` links them. This is the split DWARF makes between the
abstract and the concrete instance of a subprogram.

| DWARF | UHDI |
|---|---|
| Abstract instance of a subprogram | `original[M]` with its `vars` |
| Concrete out-of-line instance | a binding without `inline_path` |
| `DW_TAG_inlined_subroutine` | a binding with `inline_path` |

One original module may bind into several generated modules, and one generated
module may hold several original ones. A module made by lowering is left out of
`original`, unless it holds variables the frontend declared: a layer module
(marked `artificial`) or the module of a memory.

## An instance is a variable of module type

An instance is a variable in `original[M].vars` whose type has kind `module`.
Its value in a binding says where the instance went.

```json
{"original": "Top", "generated": "Top",
 "vars": {"u0": {"$inst": "u0", "module": "Child"}, "u1": {"$inline": ["u1"]}}},
{"original": "Leaf", "generated": "Top", "inline_path": ["u1"],
 "vars": {"x": "u1_x"}}
```

Instances and signals then share one namespace, one location field and one
lookup rule.

## Types are interned by structure

`types` is an array, and a type refers to another type by index, as DWARF type
DIEs do. Two variables share an entry when their serialized records are equal.
A type may carry `name`, the source name of the type. It is shown to the user
and never needed to decode the bits.

## Values say where the bits are

A binding maps each variable key to a value of the shape of its type: a signal
name, a `$slice` of a signal, a `$const`, a struct or vector of values, or
`$optimized_out`. A variable that lost its signal keeps its record in
`original`, so the debugger can still show its name and type.

When the netlist keeps an aggregate in one packed signal, each leaf is bound to
a `$slice` of it. The reader then does not need to know the SystemVerilog
packed layout.

## Extensions

A change that only adds keys, kinds or values raises the minor version.
`profiles` lists the optional parts a document uses, so a reader knows up front
what it will not understand. A key `x-<lang>` holds data only that language
knows; CIRCT does not interpret it. It parses the JSON and writes it again,
so key order is not kept. A reader ignores keys it does not know.

## Dedup and inlining keep every source module

`original` holds one entry per module as written, not per module emitted.

| Transform | Result in the document |
|---|---|
| Dedup merges `A` and `B` into `A` | `original.A` and `original.B`, two bindings into `generated.A` |
| Inlining copies `Leaf` into `Top` twice | one `original.Leaf`, two bindings into `generated.Top` |

A debugger shows each instance under its own module and variable names, even
when the Verilog behind it is shared.

## Class information lives on the instance

The class a module was elaborated from goes in `name` on the `module` type of
the instance, not on the module. Dedup merges modules whose bodies match even
when their classes differ, so the class has to stay with each instance. A
`circt_debug_type` intrinsic that targets an instance gives its class. A public
module can be a top with no instance, so a `circt_debug_type` without a target
gives its class on its `original` entry. A public module that is also
instantiated can have both; they land in different places.

## What the debug dialect carries

The emitter reads `dbg` ops after lowering. Keeping the facts on debug ops lets
passes that know nothing about debug info carry them along.

- **`dbg.instance`** describes an instance: its source name, its
  name in the IR after renaming (`linkage`), its class and `ext`. It names the
  instance rather than using it, so it does not keep it alive. When the
  instance is inlined, a `dbg.scope` for the inlined body can take its place
  and keeps the class and `ext`.
  A pass that moves an instance to another module without moving the op,
  such as FIRRTL ExtractInstances, loses its class.
  Discardable attributes on the instance would not do: MLIR drops them when a
  pass rebuilds the op.
- **`kind` and `dir` on `dbg.variable`** say what the source declares (`reg`,
  `mem`, `node`) and the port direction. They describe the declaration, not the
  value, as DWARF puts them on the variable entry.
- **`kind` on `dbg.value`** keeps what lowering erases from a ground type:
  `clock`, `reset`, `asyncreset` or `sint`. It becomes the `kind` of the
  value's type in `types`.
- **`flips` on `dbg.struct`** marks the flipped fields of a bundle. A flip is
  relative to the struct; `dir` on the variable gives the absolute direction.
- **`ext`** on `dbg.instance`, `dbg.scope`, `dbg.value` and `dbg.enum` maps a language to a
  JSON string, written as `x-<lang>`.

A few facts belong to a module and have no op to live on, so they are module
attributes:

| Attribute | Meaning |
|---|---|
| `dbg.moduleinfo` | Class of a public module. |
| `dbg.module_locs` | Location of the module and of each module merged into it. |
| `dbg.lowered` | Made by lowering; left out of `original`. |
| `dbg.memory` | Module of a memory that debug info describes. |
| `dbg.artificial` | In the source but made by the compiler, such as a layer module. |

## Status

The emitter does not write expressions (`$op`), statements or dependencies
yet: a variable bound to a combinational expression is `$optimized_out`. A
variable of a type the emitter cannot represent is left out without a
diagnostic, as in EmitHGLDD. A memory replaced by an external module
(`--repl-seq-mem`) is not described.

The format has no sum types with payloads and no location lists: a binding
gives one value for the whole simulation.
