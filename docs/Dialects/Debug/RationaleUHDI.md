# Source-Level Debug Info Rationale

This document explains how a frontend describes source-level debug info, how
CIRCT carries it through the pipeline, and how it is written out as UHDI, a
JSON document that links the source design to the emitted netlist.

The implementation uses Debug operations for source metadata and existing HW
symbols and hierarchy paths to identify instances.

[TOC]

## The model

| Rule | Consequence |
|---|---|
| Values use SSA; module descriptions use symbols. | Cloning remaps value operands. Symbol references connect instance descriptions and inlined scopes to global source metadata. |
| No discardable attribute on a non-debug op carries debug info. | No `firrtl.module`, `firrtl.instance` or `hw.*` op gets a debug attribute, so passes that rebuild those ops cannot drop it. |
| No pass links debug info by name. | Nothing in the pipeline joins a variable to a signal, module or instance by a string. The emitter reads final Verilog names once, at the output boundary. |

A pass inside one dialect (folds, canonicalization, port erasure,
LowerSignatures, LowerTypes, LowerToHW, ExportVerilog) has no debug code,
unless it restructures the debug references. A pass
that produces or consumes debug info, or restructures hierarchy, may know
about it:

| Pass | Debug-specific behavior |
|---|---|
| `LowerIntrinsics` | Converts the debug intrinsics to Debug ops, or erases them |
| `MaterializeDebugInfo` | Describes what the frontend left out |
| `Dedup` | Compares source metadata and redirects descriptor references |
| `ModuleInliner`, `hw-flatten-modules` | Give inlined Debug ops and instances a `dbg.scope` |
| `EmitHGLDD`, `EmitUHDI` | Read the Debug ops after ExportVerilog |

## Debug ops

The frontend's intrinsics map 1:1 onto these ops:

| Op | Holds |
|---|---|
| `dbg.variable` | A source variable: `name`, a value, an optional `scope`, an optional `kind` |
| `dbg.value` | Source type name (`type`) and language data (`ext`) of a value |
| `dbg.struct` | Named fields, with optional positional `flips` |
| `dbg.array` | Elements of one type |
| `dbg.enum` | An integer value with its variant names and tags |
| `dbg.module` | A global source description with a symbol, `type`, `ext` and optional `impl` link |
| `dbg.scope` | An inlined or lexical scope, optionally linked to a source description by `def` |

`kind` on `dbg.variable` is one of `input`, `output`, `inout` (analog ports),
`wire`, `reg`, `node` and `instance`. It is absent when the producer cannot tell, for
example for an empty aggregate.

`ext` on `dbg.value` and `dbg.module` holds the frontend's JSON string.
The string is an object whose keys all start with
`x-` and name the language of their value, for example
`{"x-chisel":{"params":[...]}}`. The compiler does not read the values.

## Debug intrinsics

### Handle tree

A frontend describes each variable as a small tree of intrinsics. Every
intrinsic except `circt_debug_var` and `circt_debug_moduleinfo` returns a
`UInt<0>` *handle*, and a parent takes its children's handles as operands. So
children come before their parents.

```firrtl
public module Alu :
  input clock : Clock
  output io : { a : UInt<8>, flip b : UInt<8> }
  input opcode : UInt<1>

  intrinsic(circt_debug_moduleinfo<typeName = "Alu", params = "{\"x-chisel\":{\"params\":[{\"name\":\"width\",\"value\":\"8\"}]}}">)

  node io_a = intrinsic(circt_debug_value<name = "a", typeName = "UInt<8>"> : UInt<0>, io.a)
  node io_b = intrinsic(circt_debug_value<name = "b", flip = 1, typeName = "UInt<8>"> : UInt<0>, io.b)
  node io_s = intrinsic(circt_debug_struct : UInt<0>, io_a, io_b)
  node io_h = intrinsic(circt_debug_value<typeName = "AluIO"> : UInt<0>, io_s)
  intrinsic(circt_debug_var<name = "io">, io_h)

  node op = opcode
  node op_h = intrinsic(circt_debug_enum<typeName = "AluOp", variant_ADD = 0, variant_SUB = 1> : UInt<0>, op)
  intrinsic(circt_debug_var<name = "op">, op_h)

  regreset acc : UInt<8>, clock, UInt<1>(0), UInt<8>(0)
  intrinsic(circt_debug_var<name = "acc">, acc)
```

After circuit-level `LowerIntrinsics` with `emit-debug-info` (body excerpt):

```mlir
dbg.module @AluDebug type "Alu" ext "{\22x-chisel\22:{\22params\22:[{\22name\22:\22width\22,\22value\22:\228\22}]}}" impl @Alu
// The following operations remain inside @Alu.
%2 = dbg.value %1 type "UInt<8>" : !firrtl.uint<8>
%3 = dbg.value %0 type "UInt<8>" : !firrtl.uint<8>
%4 = dbg.struct {"a": %2, "b": %3} {flips = array<i1: false, true>} : !dbg.value, !dbg.value
%5 = dbg.value %4 type "AluIO" : !dbg.struct
dbg.variable "io", %5 kind output : !dbg.value
%6 = dbg.enum %op, "AluOp", {ADD = 0 : i64, SUB = 1 : i64} : !firrtl.uint<1>
dbg.variable "op", %6 kind node : !dbg.enum
dbg.variable "acc", %acc kind reg : !firrtl.uint<8>
```

The converter change adds the intrinsics, their parameters and the rules the
converter checks to [FIRRTL Intrinsics](../FIRRTL/FIRRTLIntrinsics.md). Each
rule violation is an error with its own diagnostic.

## Pipeline placement

| Step | `-g` | Without `-g` |
|---|---|---|
| `LowerIntmodules` | Produces the `int.generic` ops | Same |
| `LowerIntrinsics` on modules | Converts the debug intrinsics (`emit-debug-info`) before the other intrinsic lowerings | Erases every `circt_debug_*` intrinsic and its alias nodes |
| `LowerIntrinsics` on class bodies | Erases them with a warning; class data has no hardware leaf | Erases them |
| `LowerAnnotations` on extmodules | Emits a module-targeted `dbg.module` | Drops the source annotation |
| `MaterializeDebugInfo` | Runs after `LowerIntrinsics`. Adds variables for ports and declarations that no Debug op describes yet, with `kind` and `flips`. Warns on FIRRTL enum values and skips them. | Does not run |
| `Dedup`, `ModuleInliner` | See below | Unchanged |
| LowerToHW, ExportVerilog | Carry the Debug ops over; ExportVerilog emits nothing for them | Unchanged |
| `EmitUHDI` (`--emit-uhdi`) | Runs after ExportVerilog | Not used |

`MaterializeDebugInfo` collects the declaration of every FIRRTL value that a
Debug op points at, and skips those. It assumes that a frontend that describes
a declaration describes all of it.

Without `-g`, the Verilog is expected to be the same as for the input with the
debug intrinsics removed. The firtool tests check this with a diff.

## Module class and transparency

A global `dbg.module` describes a source module. Its `impl` symbol
reference associates it with a hardware module, including top and external
modules. Instance `dbg.value` operations and inlined `dbg.scope` operations
refer to the description through `def`. There is no explicit root scope.

| Module | Meaning in UHDI |
|---|---|
| Has a `dbg.module` impl binding | A source scope with that class |
| Has none, and nothing instantiates it | A scope with no class (a top module) |
| Has none, and is instantiated | Made by the compiler; transparent |
| External module | A scope whose variables are its ports, with source metadata when available |

A transparent module adds no level to the source hierarchy. Its variables and
instances move into the scope that instantiates it. Generated layer modules
are transparent this way.

`impl` is a strong symbol reference. Generic symbol-DCE may retain
otherwise unused hardware through it; this is accepted. No preparation pass
is required. Inlining detaches the reference before deleting its target.
Descriptors with implementations are retained. Detached descriptions remain
live while debug scopes or values reference them.

`LowerIntrinsics` runs at circuit level to create global descriptions without
mutating an ancestor from parallel module passes. `MaterializeDebugInfo` does
not invent source module descriptions for modules without frontend metadata.

### External module classes

`circt.DebugSourceNameAnnotation` with a `name` field targets a local
extmodule. LowerAnnotations emits a module-targeted `dbg.module` outside
the extmodule and drops the annotation. The metadata stays in the Debug
dialect; external module operations need no source-name attribute.

Dedup compares these source descriptions. Without `-g`, LowerAnnotations
drops the source annotation without creating a description.

## Dedup

Dedup compares Debug variable names, struct field names, and source module
`type` and `ext`. Modules with different source metadata remain separate.
When equivalent modules merge, references to their descriptions are redirected
to the surviving description before the duplicate is erased. This applies to
both ordinary and external modules.

## Inliner

When `ModuleInliner` inlines an instance, it creates a `dbg.scope` and attaches
otherwise unscoped copied debug operations to it. Nested scopes keep their
parents. The new scope's `def` refers to the global source description;
its location records the instantiation site, while the descriptor retains the
class declaration location. Removing the hardware module clears the description's
`impl` without deleting metadata referenced by scopes.

Live instances are described by `dbg.value path` and `dbg.variable`:

```mlir
dbg.module @LeafDebug type "Leaf" impl @Leaf
hw.hierpath private @left_path [@Top::@left]
// In Top:
hw.instance "left" sym @left @Leaf() -> ()
%value = dbg.value path @left_path def @LeafDebug
dbg.variable "left", %value kind instance : !dbg.value
```

The value carries the path and source description reference; the variable carries
its source name and parent scope. The module name comes from `def`;
`dbg.scope` stores no separate module name and has no instance binding.
`MaterializeDebugInfo` runs on the circuit so it can create hierarchy paths
without modifying an ancestor from a parallel module pass. Dedup compares
local debug paths by their targets rather than their path symbol names.

Inlining transfers the instance symbol to the scope for its body. A local
path-backed variable is consumed into that scope, preserving its name, type,
extensions and parent. A nonlocal description retains its path to the scope:
the instance steps distinguish occurrences of a shared containing module.
Paths also remain available to unrelated users until normal symbol cleanup.

## What `-g` costs

`-g` may change the Verilog. The effects below were seen on a few small
designs, compiled with and without `-g` with the planned converter; no real
design has been measured. The tests that show them come with the converter.

| Effect | What changes |
|---|---|
| Spilled wires | An expression that a `dbg.variable` uses gets its own named wire |
| Unmerged modules | Modules of different source classes stay separate; modules with different debug names also stay separate |
| Live layer modules | A `dbg.variable` in a layer block keeps the layer module and its `bind` alive, and captured values become named wires |

## The emitter

`EmitUHDI` (`circt-translate --emit-uhdi`, `firtool --emit-uhdi=<file>`) runs
after ExportVerilog. It reads `hw.verilogName` and `verilogName`, falling back
to `name`, as `EmitHGLDD` does. These are the final names, after every rename,
and the emitter also sees the wires ExportVerilog spilled.

The document format is specified separately in the UHDI specification. This
section covers only how the emitter maps the IR onto it.

### Scopes

- A source module is a scope, and so is an inlined instance (a `dbg.scope`
  with a `def` reference), bound to the module it was inlined into. A
  `dbg.scope` without a def is transparent, like a module without one.
- An instance is a variable whose type is a module. Its value is the
  instance's path, or its inline path if it was inlined.
- Inlined copies of one module that produce equal entries share one entry.
- More than one `dbg.module` bound to the same hardware module is an error.

### Values

| Leaf value | Emitted as |
|---|---|
| `hw.constant` | `$const` with all its bits; a zero-width one is `$zero_width` |
| A wire that only aliases a port (driven by an input port, or read by `hw.output`) | The port's Verilog name |
| Input port | The port's Verilog name |
| `hw.wire`, `sv.wire`, `sv.reg`, `sv.logic`, `seq.firreg` | Its `hw.verilogName`, else `name` |
| A value with no name of its own that feeds `hw.output` | The output port's Verilog name |
| A read of `sv.xmr.ref` | The target of the `hw.hierpath`, as a path from the scope's module |
| A field, constant index or bit range of a named signal | `$slice` of that signal with `hi` and `lo` |
| Anything else, such as a comb expression | `$optimized_out` |

Folds may leave a variable pointing at its driver. An output port driven by a
register then reads the register's signal.

### Relative paths

A variable hoisted out of a transparent module lives in another Verilog
instance. Its signal is named by the Verilog names of the instances from the
scope's module down to the signal's module, then the signal, joined with `.`
(for example `verif.lw`).

### Types and language data

Types are interned by their serialized record: kind, width, field names,
flips, element type, enum variants and type name. The type name is a label;
two types with one name and different shapes are two entries.

`ext` is parsed as JSON. The emitter copies each top-level key and value,
unread, into the type or scope, and lists each key in `profiles`. The frontend
chooses the keys, so the emitter knows no language. A string that does not
parse, is not an object, or has a key without the `x-` prefix is an error on
the op.

## Compatibility with the older protocol

An older protocol is in use: `circt_debug_subfield` linked to its root by a
`parent` FQN string, `circt_debug_enumdef`, and `circt_debug_var` with
`typeName`, `params`, `enumTypeName` or `enumFqn`.

| Mode | Behavior |
|---|---|
| Without `-g` | Erased by the `circt_debug_` prefix, so such FIRRTL compiles as before |
| With `-g` | An unknown debug intrinsic or parameter is an error that suggests updating the frontend or compiling without debug info |

An error is preferred over a partial description: the user can drop `-g`.

## Known gaps

| Gap | Current behavior |
|---|---|
| Memories | No SSA value holds their contents; an operand-less `circt_debug_var` is dropped with a warning |
| External module classes | A name from `circt.DebugSourceNameAnnotation`, no `ext` |
| FIRRTL enums (`FEnumType`) | An enum operand is an error in the converter; `MaterializeDebugInfo` warns and skips it |
| Instance choices inside an inlined module | Listed under the enclosing module (`firrtl.instance_choice` has no scope operand) |
| `instance_choice` alternatives | Each alternative is its own instance under its Verilog name, not one scope with options |
| Statement-level info | No connect enables, reset guards or breakpoint lines |
| Expressions | Supported operations are emitted as expressions; unsupported values remain unavailable |

## Open questions

| Question | Today |
|---|---|
| Should `MaterializeDebugInfo` add source descriptions without frontend metadata? | It does not, so only top modules become source scopes in that case |
| How should the emitter pick the language-data key? | The frontend chooses the `x-<lang>` keys; the emitter copies them verbatim |
| Where does module metadata live? | A global `dbg.module`, shared by live instance descriptions and inlined scopes |
| Should Dedup compare the `name` of Debug ops? | Yes; source debug names participate in comparison (see [Dedup](#dedup)) |
