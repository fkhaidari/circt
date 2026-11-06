# Intrinsics

Intrinsics provide an implementation-specific way to extend the FIRRTL language
with new operations.

[TOC]

## Motivation

Intrinsics provide a way to add functionality to FIRRTL without having to extend
the FIRRTL language. This allows a fast path for prototyping new operations to 
rapidly respond to output requirements.  Intrinsics maintain strict definitions
and type checking.

## Supported Intrinsics

[include "Dialects/FIRRTLIntrinsics.md.inc"]

## Debug Intrinsics

The `circt_debug_*` intrinsics describe source-language variables for debug
info. `LowerIntrinsics` converts them 1:1 into Debug dialect ops when its
`emit-debug-info` option is set (firtool `-g`). Without it, it erases every
intrinsic whose name starts with `circt_debug_`, together with its alias
nodes.

Each intrinsic except `circt_debug_var` and `circt_debug_moduleinfo` returns
a `UInt<0>` *handle*. A parent takes its children's handles as operands, so
children come first.

| Intrinsic | Operands | Parameters | Result | Becomes |
|---|---|---|---|---|
| `circt_debug_moduleinfo` | none | `typeName`, `params?` | none | `dbg.moduleinfo` |
| `circt_debug_var` | handle or ground hardware value | `name` | none | `dbg.variable` |
| `circt_debug_value` | handle or ground hardware value | `typeName?`, `params?`, `name?`, `flip?` | handle | `dbg.value` |
| `circt_debug_struct` | handles | `name?`, `flip?` | handle | `dbg.struct` |
| `circt_debug_array` | handles | `name?`, `flip?` | handle | `dbg.array` |
| `circt_debug_enum` | ground `UInt` value | `typeName`, `fqn?`, `variant_<Name>`..., `name?`, `flip?` | handle | `dbg.enum` |

```firrtl
node io_a = intrinsic(circt_debug_value<name = "a", typeName = "UInt<8>"> : UInt<0>, io.a)
node io_b = intrinsic(circt_debug_value<name = "b", flip = 1, typeName = "UInt<8>"> : UInt<0>, io.b)
node io_s = intrinsic(circt_debug_struct : UInt<0>, io_a, io_b)
node io_h = intrinsic(circt_debug_value<typeName = "MyBundle"> : UInt<0>, io_s)
intrinsic(circt_debug_var<name = "io">, io_h)
```

- **Handles.** A handle is the result of a `circt_debug_*` intrinsic, or a
  `firrtl.node` whose input is a handle (`node h = intrinsic(...)` parses that
  way). Its type does not matter: a real `UInt<0>` wire is a hardware value.
  Each handle is used exactly once, and only by debug intrinsics. Alias nodes
  must not carry annotations, a symbol or a probe.
- **Hardware operands** are ground: an aggregate is described with handles.
  FIRRTL enum operands are not supported. Probe, property and class data get
  no leaf.
- **`name` and `flip`** give a node's field name in its parent struct and
  whether the field is flipped (`flip` is 0 or 1). A struct reads them from
  its children, and every struct field needs a `name`. Array elements,
  variable roots and the operand of a `circt_debug_value` carry neither.
- **Flip check.** For each leaf, the parity of the `flip` parameters on the
  path from the variable down to the leaf must equal the parity of the flips
  in the leaf's FIRRTL type on the path from its declaration. A mismatch is an
  error; no flip is derived silently.
- **`kind`** of `dbg.variable` is derived, never sent. All leaves of a
  variable must share one declaration, found by walking up subfield, subindex
  and cast ops. A port gives `input`, `output` or, if any leaf is Analog,
  `inout`; a wire `wire`; a register `reg`; a node `node`. Anything else, such
  as a dynamic index or an empty aggregate, leaves it unset. The walk stops at
  a `node`, so a frontend passes references to the declaration itself.
- **`circt_debug_value`** without `typeName` and `params` lowers to its
  operand. It must not wrap another `circt_debug_value` that has them.
  `params` is the frontend's JSON string and becomes a one-element array. The
  string is an object whose top-level keys start with `x-`, for example
  `{"x-chisel":{...}}`.
- **`circt_debug_enum`** tags (`variant_<Name> = <int>`) become signless `i64`
  values, independent of the operand width, which may still be unknown. A
  negative tag, or one that does not fit in `i64`, is an error.
- **`circt_debug_moduleinfo`** sits directly in the module body, at most once
  per module.
- A `circt_debug_var` with no operand (a memory) is dropped with a warning.
  Debug intrinsics in a `firrtl.class` body are dropped (with a warning under
  `emit-debug-info`). Other `circt_debug_*` names and parameters, such as
  those of the older Chisel protocol, are errors under `emit-debug-info`.
