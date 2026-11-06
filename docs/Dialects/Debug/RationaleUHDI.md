# UHDI Rationale

This document explains how a frontend describes source-level debug info, how
CIRCT carries it through the pipeline, and how it is written out as UHDI, a
JSON document that links the source design to the emitted netlist.

[TOC]

## The model

| Rule | Consequence |
|---|---|
| All debug structure lives in SSA. | A Debug op refers to the values it describes and to its children by operands. Passes that RAUW, clone or move ops carry it along. |
| No discardable attribute on a non-debug op carries debug info. | No `firrtl.module`, `firrtl.instance` or `hw.*` op gets a debug attribute, so passes that rebuild those ops cannot drop it. The one debug link on a non-debug op is the optional `scope` operand of an instance (see [Inliner](#inliner)). |
| No pass links debug info by name. | Nothing in the pipeline joins a variable to a signal, module or instance by a string. The emitter reads final Verilog names once, at the output boundary. |

A pass inside one dialect (folds, canonicalization, port erasure,
LowerSignatures, LowerTypes, LowerToHW, ExportVerilog) has no debug code,
except that a pass that rebuilds an instance copies its `scope` operand. A pass
that produces or consumes debug info, or restructures hierarchy, may know
about it:

| Pass | Debug-specific behavior |
|---|---|
| `LowerIntrinsics` | Converts the debug intrinsics to Debug ops, or erases them |
| `MaterializeDebugInfo` | Describes what the frontend left out |
| `Dedup` | Compares the `name` of Debug ops |
| `ModuleInliner`, `hw-flatten-modules` | Give inlined Debug ops and instances a `dbg.scope` |
| `EmitHGLDD`, `EmitUHDI` | Read the Debug ops after ExportVerilog |

## Debug ops

The frontend's intrinsics map 1:1 onto these ops:

| Op | Holds |
|---|---|
| `dbg.variable` | A source variable: `name`, a value, an optional `scope`, an optional `kind` |
| `dbg.value` | Source type name (`typeName`) and language data (`params`) of a value |
| `dbg.struct` | Named fields, with optional positional `flips` |
| `dbg.array` | Elements of one type |
| `dbg.enum` | An integer value with its variant names and tags |
| `dbg.moduleinfo` | The source class of the enclosing module, or of a `dbg.scope` after inlining |

`kind` on `dbg.variable` is one of `input`, `output`, `inout` (analog ports),
`wire`, `reg` and `node`. It is absent when the producer cannot tell, for
example for an empty aggregate.

`params` on `dbg.value` and `dbg.moduleinfo` is a one-element array that holds
the frontend's JSON string. The string is an object whose keys all start with
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

After `LowerIntrinsics` with `emit-debug-info`:

```mlir
dbg.moduleinfo "Alu" params ["{\22x-chisel\22:{\22params\22:[{\22name\22:\22width\22,\22value\22:\228\22}]}}"]
%2 = dbg.value %1 typeName "UInt<8>" : !firrtl.uint<8>
%3 = dbg.value %0 typeName "UInt<8>" : !firrtl.uint<8>
%4 = dbg.struct {"a": %2, "b": %3} {flips = array<i1: false, true>} : !dbg.value, !dbg.value
%5 = dbg.value %4 typeName "AluIO" : !dbg.struct
dbg.variable "io", %5 kind output : !dbg.value
%6 = dbg.enum %op, "AluOp", {ADD = 0 : i64, SUB = 1 : i64} : !firrtl.uint<1>
dbg.variable "op", %6 kind node : !dbg.enum
dbg.variable "acc", %acc kind reg : !firrtl.uint<8>
```

The intrinsics, their parameters and the rules the converter checks are
specified in [FIRRTL Intrinsics](../FIRRTL/FIRRTLIntrinsics.md#debug-intrinsics).
Each rule violation is an error with its own diagnostic.

## Pipeline placement

| Step | `-g` | Without `-g` |
|---|---|---|
| `LowerIntmodules` | Produces the `int.generic` ops | Same |
| `LowerIntrinsics` on modules | Converts the debug intrinsics (`emit-debug-info`) before the other intrinsic lowerings | Erases every `circt_debug_*` intrinsic and its alias nodes |
| `LowerIntrinsics` on class bodies | Erases them with a warning; class data has no hardware leaf | Erases them |
| `LowerIntrinsics` on extmodules | Not run; `sourceName` stays | Drops `sourceName` |
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

A module's source class is its `dbg.moduleinfo`. It is a body op, so it moves
with the module's region, Dedup hashes it, and passes that rebuild instances
cannot lose it. An instance's class is the `dbg.moduleinfo` of the module it
instantiates. External modules have no body, so their class is the optional
inherent attribute `sourceName` (see [External module classes](#external-module-classes)).

| Module | Meaning in UHDI |
|---|---|
| Has an unscoped `dbg.moduleinfo` | Written in the source; a scope with that class |
| Has none, and nothing instantiates it | A scope with no class (a top module) |
| Has none, and is instantiated | Made by the compiler; transparent |
| External module | A scope whose variables are its ports; its class is `sourceName`, if set |

The rows for a top module without a `dbg.moduleinfo` and for an external
module state what the emitter does today; the design does not fix them. An
external module is a scope even when it is instantiated.

A transparent module adds no level to the source hierarchy. Its variables and
instances move into the scope that instantiates it. Layer modules, the bound
instances that carry them, and other modules made by lowering are transparent
this way, with no marker of their own.

`MaterializeDebugInfo` adds no `dbg.moduleinfo` today. So with `-g` and no
frontend intrinsics, only modules that nothing instantiates are scopes, and
everything under them is hoisted. Whether it should add an empty
`dbg.moduleinfo ""` to every module without one is open.

### External module classes

`circt.DebugSourceNameAnnotation` with a `name` field targets a local
extmodule. LowerAnnotations stores the name in the extmodule's `sourceName`
and drops the annotation. LowerToHW copies it to `hw.module.extern`, or to
`sv.verbatim.module` for a black box with inline Verilog. The class is a name
only; there are no `params`.

`sourceName` is inherent, so Dedup hashes it: under `-g`, two extmodules that
differ only in it do not merge. Without `-g`, `LowerIntrinsics` drops it
before Dedup, and the Verilog is the same as without the annotation.

## Dedup

The `name` of a Debug op is essential in Dedup, both in the structural hash and
in the equivalence check, through one shared predicate (`isNonessential`).
Modules that differ only in debug variable names do not merge; otherwise an
instance of one would report the names of the other. `typeName` and `params` of
`dbg.moduleinfo` are already hashed, so modules of different classes do not
merge either. Whether to make every attribute of a Debug op essential, not only
`name`, is open; Debug ops carry no other attribute that Dedup skips, so both
choices behave the same today.

So `-g` merges less. Modules with the same body but different source names or
class parameters stay separate.

## Inliner

When `ModuleInliner` inlines an instance, it creates a `dbg.scope` for it and
gives that scope to the inlined `dbg.variable`, `dbg.scope` and
`dbg.moduleinfo` ops. A `dbg.moduleinfo` that already has a scope from an
earlier inline keeps it, and that scope is nested in the new one. The class of
an inlined instance is the `dbg.moduleinfo` whose scope is that instance's
`dbg.scope`, never the scope's `moduleName` string.

The instances of the inlined module move into the parent too. The inliner
sets their optional `scope` operand to the new `dbg.scope`, so UHDI lists them
under the inlined instance. `firrtl.instance` and `hw.instance` have this
operand; LowerToHW and the passes that rebuild an instance copy it. Without
`-g` the inliner creates no scope and the operand stays empty. A pass that
drops it only moves the instance to the enclosing module in the debug info;
the operand is not a port, so the Verilog does not change.

`hw-flatten-modules` does the same for `hw.instance`: the scope's parent is the
instance's own `scope` operand, if it has one. Debug ops are not renamed with
the instance prefix, since the scope carries the path. A scope that only
instances would use is dropped, so a design without Debug ops is unchanged.

## What `-g` costs

`-g` may change the Verilog. This was measured on a few small designs only, by
compiling each with and without `-g` and diffing the Verilog. No real design
has been measured.

| Effect | Seen on |
|---|---|
| Spilled wires: an expression that a `dbg.variable` uses gets its own named wire | `test/firtool/debug-info-alu.fir`: 4 wires (`next`, `selOp`, `io_lanes_1_valid_0`, `io_result_valid_0`). `test/firtool/debug-info-dedup-layer.fir`: `_inc_T`, `_out_output` |
| Unmerged modules: debug names and classes are essential in Dedup | `test/firtool/debug-info-dedup-layer.fir`: three children with one body give one module without `-g`, two with it |
| Live layer modules: a `dbg.variable` in a layer block keeps it alive | `test/firtool/debug-info-dedup-layer.fir`: only under `-g` do `module Top_Verification();` and `bind Top Top_Verification verification ();` appear, and the captured instance outputs become `c0_out_layerCapture` and `c2_out_layerCapture` wires, which carry inner symbols in `--ir-hw` |

`test/firtool/debug-info-class.fir` gives the same Verilog with and without
`-g`.

## The emitter

`EmitUHDI` (`circt-translate --emit-uhdi`, `firtool --emit-uhdi=<file>`) runs
after ExportVerilog. It reads `hw.verilogName` and `verilogName`, falling back
to `name`, as `EmitHGLDD` does. These are the final names, after every rename,
and the emitter also sees the wires ExportVerilog spilled.

The document format is specified separately in the UHDI specification. This
section covers only how the emitter maps the IR onto it.

### Scopes

- A source module is a scope, and so is an inlined instance (a `dbg.scope`
  with a `dbg.moduleinfo`), bound to the module it was inlined into. A
  `dbg.scope` without one is transparent, like a module without one.
- An instance is a variable whose type is a module. Its value is the
  instance's path, or its inline path if it was inlined.
- Inlined copies of one module that produce equal entries share one entry.
- More than one unscoped `dbg.moduleinfo` in a module, or more than one per
  scope, is an error.

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

`params` is parsed as JSON. The emitter copies each top-level key and value,
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
| External module classes | A name from `circt.DebugSourceNameAnnotation`, no `params` |
| FIRRTL enums (`FEnumType`) | An enum operand is an error in the converter; `MaterializeDebugInfo` warns and skips it |
| Instance choices inside an inlined module | Listed under the enclosing module (`firrtl.instance_choice` has no scope operand) |
| Instances in a layer block of an inlined module | Listed under the enclosing module: the scope stays outside the layer module, so LowerLayers drops the operand |
| Instance names inside an inlined module | The key is the Verilog-level name with the inliner's prefix (`child_leaf`), not the source name (`leaf`) |
| `instance_choice` alternatives | Each alternative is its own instance under its Verilog name, not one scope with options |
| ExtractInstances | An extracted instance appears under its new parent, not its source parent |
| InjectDUTHierarchy | The new DUT has no class and is hoisted; the source instance shows up as the wrapper's instance |
| Statement-level info | No connect enables, reset guards or breakpoint lines |
| Expressions | A variable bound to an expression is `$optimized_out` |

## Open questions

| Question | Today |
|---|---|
| Should `MaterializeDebugInfo` add `dbg.moduleinfo ""` to modules without one? | It does not, so without frontend intrinsics only top modules are scopes |
| How should the emitter pick the language-data key? | The frontend chooses the `x-<lang>` keys; the emitter copies them verbatim |
| Should the class be a body op or an inherent module attribute? | A body op on modules; the inherent `sourceName` on external modules, which have no body |
| Should Dedup treat only `name` or every Debug attribute as essential? | Only `name`; the two choices behave the same on today's Debug ops |
