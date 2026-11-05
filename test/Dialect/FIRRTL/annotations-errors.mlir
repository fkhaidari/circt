// RUN: circt-opt --pass-pipeline='builtin.module(firrtl.circuit(firrtl-lower-annotations))' -split-input-file %s -verify-diagnostics

// An unknown annotation should error.
//
// expected-error @+1 {{Unhandled annotation}}
firrtl.circuit "Foo" attributes {
  rawAnnotations = [
    {
      class = "circt.unknown"
    }
  ]
} {
  firrtl.module @Foo() {}
}

// -----

// An incorrect circuit target should report an error.
//
// expected-error @+2 {{circuit name doesn't match annotation}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Fooo|Foo>bar"
    }
  ]
} {
  firrtl.module @Foo() {}
}

// -----

// An incorrect circuit name should report an error.
//
// expected-error @+2 {{circuit name doesn't match annotation}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Fooo"
    }
  ]
} {
  firrtl.module @Foo() {}
}

// -----

// An empty target string should be illegal.
//
// expected-error @+2 {{Cannot tokenize annotation path}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = ""
    }
  ]
} {
  firrtl.module @Foo() {}
}

// -----

// A target that does a subindex of an instance should be illegal.
//
// expected-error @+2 {{illegal target '~Foo|Foo>bar[0]' indexes into an instance}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Foo|Foo>bar[0]"
    }
  ]
} {
  firrtl.module @Bar() {}
  firrtl.module @Foo() {
    firrtl.instance bar @Bar()
  }
}

// -----

// A target that uses a string for an index should be illegal.
//
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Foo|Foo>bar[a].baz"
    }
  ]
} {
  firrtl.module @Foo() {
    // expected-error @+1 {{Cannot convert 'a' to an integer}}
    %bar = firrtl.wire : !firrtl.vector<bundle<baz: uint<1>, qux: uint<1>>, 2>
  }
}

// -----

// Invalid subindex or subfield targets are checked.
//
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Foo|Foo>bar[1][42]"
    },
    {
      class = "circt.test",
      target = "~Foo|Foo>bar[1].qnx"
    },
    {
      class = "circt.test",
      target = "~Foo|Foo>bar[1].baz[1337]"
    }
  ]
} {
  firrtl.module @Foo(in %clock: !firrtl.clock) {
    // expected-error @+3 {{index access '42' into non-vector type}}
    // expected-error @+2 {{cannot resolve field 'qnx' in subtype}}
    // expected-error @+1 {{index access '1337' into non-vector type}}
    %bar = firrtl.reg %clock : !firrtl.clock, !firrtl.vector<bundle<baz: uint<1>, qux: uint<1>>, 2>
  }
}

// -----

// A target on a non-existent module should error.
//
// expected-error @+2 {{module doesn't exist 'Bar'}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Foo|Bar"
    }
  ]
} {
  firrtl.module @Foo() {}
}

// -----

// A target on a non-existent component should error.
//
// expected-error @+2 {{cannot find name 'x' in Foo}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo"  attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Foo|Foo>x"
    }
  ]
} {
  firrtl.module @Foo() {}
}

// -----

// A non-local annotation on a non-existent instance should error.
//
// expected-error @+2 {{cannot find instance 'baz' in 'Foo'}}
// expected-error @+1 {{Unable to resolve target of annotation}}
firrtl.circuit "Foo" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Foo|Foo/baz:Bar"
    }
  ]
} {
  firrtl.module private @Bar() {}
  firrtl.module @Foo() {
    firrtl.instance bar interesting_name  @Bar()
  }
}

// -----

// expected-error @+1 {{Unable to apply annotation}}
firrtl.circuit "LocalOnlyAnnotation" attributes {
  rawAnnotations = [
    {
      class = "circt.testLocalOnly",
      target = "~LocalOnlyAnnotation|LocalOnlyAnnotation/foo:Foo>w"
    }
  ]
} {
  firrtl.module @Foo() {
    // expected-error @+2 {{targeted by a non-local annotation}}
    // expected-note @+1 {{see current annotation}}
    %w = firrtl.wire : !firrtl.uint<1>
  }
  firrtl.module @LocalOnlyAnnotation() {
    firrtl.instance foo @Foo()
  }
}

// -----

// expected-error @+1 {{Unable to apply annotation}}
firrtl.circuit "DontTouchOnNonReferenceTarget" attributes {
  rawAnnotations = [
    {
      class = "firrtl.transforms.DontTouchAnnotation",
      target = "~DontTouchOnNonReferenceTarget|Submodule"
    },
    {
      class = "firrtl.transforms.DontTouchAnnotation",
      target = "~DontTouchOnNonReferenceTarget|DontTouchOnNonReferenceTarget>submodule"
    }
  ]
} {
  firrtl.module @Submodule() {}
  firrtl.module @DontTouchOnNonReferenceTarget() {
    firrtl.instance submodule @Submodule()
  }
}

// -----
// Check instance port target that doesn't exist.

// expected-error @below {{cannot find port 'a' in module Ext}}
// expected-error @below {{Unable to resolve target of annotation}}
firrtl.circuit "InstancePortNotFound" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~InstancePortNotFound|InstancePortNotFound>inst.a"
    }
  ]
} {
  firrtl.extmodule @Ext()
  firrtl.module @InstancePortNotFound() {
    firrtl.instance inst @Ext()
  }
}

// -----
// Check ref-type instance port is rejected.

// expected-error @below {{annotation cannot target reference-type port 'ref' in module Ext}}
// expected-error @below {{Unable to resolve target of annotation}}
firrtl.circuit "InstancePortRef" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~InstancePortRef|InstancePortRef>inst.ref"
    }
  ]
} {
  firrtl.extmodule @Ext(out ref : !firrtl.ref<uint<1>>)
  firrtl.module @InstancePortRef() {
    %ref = firrtl.instance inst @Ext(out ref : !firrtl.ref<uint<1>>)
  }
}

// -----
// Check indexing into ref-type instance port is rejected.

// expected-error @below {{annotation cannot target reference-type port 'ref' in module Ext}}
// expected-error @below {{Unable to resolve target of annotation}}
firrtl.circuit "InstancePortRefField" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~InstancePortRefField|InstancePortRefField>inst.ref.x"
    }
  ]
} {
  firrtl.extmodule @Ext(out ref : !firrtl.ref<bundle<x: uint<1>>>)
  firrtl.module @InstancePortRefField() {
    %ref = firrtl.instance inst @Ext(out ref : !firrtl.ref<bundle<x: uint<1>>>)
  }
}

// -----
// Reject annotations on references.

// expected-error @below {{cannot target reference-type 'out' in RefAnno}}
// expected-error @below {{Unable to resolve target of annotation}}
firrtl.circuit "RefAnno" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~RefAnno|RefAnno>out"
    }
  ]
} {
  firrtl.module @RefAnno(in %in : !firrtl.uint<1>, out %out : !firrtl.ref<uint<1>>) {
    %ref = firrtl.ref.send %in : !firrtl.uint<1>
    firrtl.ref.define %out, %ref : !firrtl.ref<uint<1>>
  }
}

// -----
// Reject annotations that index through references.

// expected-error @below {{cannot target reference-type 'out' in RefFieldAnno}}
// expected-error @below {{Unable to resolve target of annotation}}
firrtl.circuit "RefFieldAnno" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~RefFieldAnno|RefFieldAnno>out.x"
    }
  ]
} {
  firrtl.module @RefFieldAnno(in %in : !firrtl.bundle<x: uint<1>>, out %out : !firrtl.ref<bundle<x: uint<1>>>) {
    %ref = firrtl.ref.send %in : !firrtl.bundle<x: uint<1>>
    firrtl.ref.define %out, %ref : !firrtl.ref<bundle<x: uint<1>>>
  }
}

// -----
// Reject AttributeAnnotations on ports.



// expected-error @+1 {{Unable to apply annotation:}}
firrtl.circuit "Anno" attributes {
  rawAnnotations = [
    {
      class = "firrtl.AttributeAnnotation",
      target = "~Anno|Anno>in",
      description = "attr"
    }
  ]
} {
  // expected-error @+1 {{firrtl.AttributeAnnotation must target an operation. Currently ports are not supported}}
  firrtl.module @Anno(in %in : !firrtl.uint<1>) {}
}

// -----
// Reject AttributeAnnotations on external modules.

// expected-error @+1 {{Unable to apply annotation:}}
firrtl.circuit "Anno" attributes {
  rawAnnotations = [
    {
      class = "firrtl.AttributeAnnotation",
      target = "~Anno|Ext",
      description = "ext"
    }
  ]
} {
  // expected-error @+1 {{firrtl.AttributeAnnotation unhandled operation. The target must be a module, wire, node or register}}
  firrtl.extmodule @Ext()
  firrtl.module @Anno(in %in : !firrtl.uint<1>) {}
}

// -----
// Reject annotation on a class.

// expected-error @+1 {{Unable to resolve target of annotation: {class = "circt.test", target = "~Component|Class"}}}
firrtl.circuit "Component" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Component|Class"
    }
  ]
} {
  firrtl.module @Component() {}
  // expected-error @+1 {{annotations cannot target classes}}
  firrtl.class @Class() {}
}

// -----
// Reject annotation on a class's port.

// expected-error @+1 {{Unable to resolve target of annotation: {class = "circt.test", target = "~Component|Class>port"}}}
firrtl.circuit "Component" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Component|Class>port"
    }
  ]
} {
  firrtl.module @Component() {}
  // expected-error @+1 {{annotations cannot target classes}}
  firrtl.class @Class(in %port: !firrtl.string) {}
}

// -----
// Don't crash trying to annotate-subindex through targets that don't name a result.

// expected-error @below {{Unable to resolve target of annotation: {class = "circt.test", target = "~Issue5947|Issue5947>mem[0]"}}}
firrtl.circuit "Issue5947" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Issue5947|Issue5947>mem[0]"
    }
  ]
} {
  firrtl.module @Issue5947() {
    // expected-error @below {{index access in annotation not supported for this operation}}
    %mem = chirrtl.combmem : !chirrtl.cmemory<uint<1>, 2>
  }
}

// -----
// Don't crash trying to annotate-subfield through targets that don't name a result.

// expected-error @below {{Unable to resolve target of annotation: {class = "circt.test", target = "~Issue5947|Issue5947>mem.a"}}}
firrtl.circuit "Issue5947" attributes {
  rawAnnotations = [
    {
      class = "circt.test",
      target = "~Issue5947|Issue5947>mem.a"
    }
  ]
} {
  firrtl.module @Issue5947() {
    // expected-error @below {{field access in annotation not supported for this operation}}
    %mem = chirrtl.combmem : !chirrtl.cmemory<uint<1>, 2>
  }
}

// -----
// An empty directory on an OutputDirAnnotation should fail.

// expected-error @below {{Unable to apply annotation: {class = "circt.OutputDirAnnotation", dirname = "", target = "~Top|Top"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.OutputDirAnnotation",
      dirname = "",
      target = "~Top|Top"
    }
  ]
} {
  // expected-error @below {{circt.OutputDirAnnotation dirname must not be empty}}
  firrtl.module @Top() {}
}

// -----
// OutputDirAnnotation targeting a non-public module should fail.

// expected-error @below {{Unable to apply annotation: {class = "circt.OutputDirAnnotation", dirname = "foo", target = "~Top|NotTop"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.OutputDirAnnotation",
      dirname = "foo",
      target = "~Top|NotTop"
    }
  ]
} {
  firrtl.module @Top() {}
  // expected-error @below {{circt.OutputDirAnnotation must target a public module}}
  firrtl.module private @NotTop() {}
}

// -----
// An OutputDirAnnotation targeting an ExtModule should fail.

// expected-error @below {{Unable to apply annotation: {class = "circt.OutputDirAnnotation", dirname = "foo", target = "~Top|Target"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.OutputDirAnnotation",
      dirname = "foo",
      target = "~Top|Target"
    }
  ]
} {
  firrtl.module @Top() {}
  // expected-error @below {{circt.OutputDirAnnotation must target a module}}
  firrtl.extmodule @Target()
}

// -----
// An OutputDirAnnotation targeting a module which already has an output directory, should fail.

// expected-error @below {{Unable to apply annotation: {class = "circt.OutputDirAnnotation", dirname = "bar", target = "~Top|Top"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.OutputDirAnnotation",
      dirname = "bar",
      target = "~Top|Top"
    }
  ]
} {
  // expected-error @below {{circt.OutputDirAnnotation target already has an output file}}
  firrtl.module @Top() attributes {output_file = #hw.output_file<"foo">} {}
}

// -----
// Multiple OutputDirAnnotation targeting the same module should fail.

// expected-error @below {{Unable to apply annotation: {class = "circt.OutputDirAnnotation", dirname = "foo", target = "~Top|Top"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.OutputDirAnnotation",
      dirname = "foo",
      target = "~Top|Top"
    },
        {
      class = "circt.OutputDirAnnotation",
      dirname = "foo",
      target = "~Top|Top"
    }
  ]
} {
  // expected-error @below {{circt.OutputDirAnnotation target already has an output file}}
  firrtl.module @Top() {}
}

// -----
// A DebugSourceNameAnnotation must target an extmodule.

// expected-error @below {{Unable to apply annotation: {class = "circt.DebugSourceNameAnnotation", name = "Foo", target = "~Top|Top"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.DebugSourceNameAnnotation",
      name = "Foo",
      target = "~Top|Top"
    }
  ]
} {
  // expected-error @below {{circt.DebugSourceNameAnnotation must target an extmodule}}
  firrtl.module @Top() {}
}

// -----
// A DebugSourceNameAnnotation must have a non-empty name.

// expected-error @below {{Unable to apply annotation: {class = "circt.DebugSourceNameAnnotation", name = "", target = "~Top|Ext"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.DebugSourceNameAnnotation",
      name = "",
      target = "~Top|Ext"
    }
  ]
} {
  // expected-error @below {{circt.DebugSourceNameAnnotation name must not be empty}}
  firrtl.extmodule @Ext()
  firrtl.module @Top() {
    firrtl.instance ext @Ext()
  }
}

// -----
// A DebugSourceNameAnnotation must be local.

// expected-error @below {{Unable to apply annotation: {class = "circt.DebugSourceNameAnnotation", name = "Foo", target = "~Top|Top/ext:Ext"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.DebugSourceNameAnnotation",
      name = "Foo",
      target = "~Top|Top/ext:Ext"
    }
  ]
} {
  // expected-error @below {{circt.DebugSourceNameAnnotation must be local}}
  firrtl.extmodule @Ext()
  firrtl.module @Top() {
    firrtl.instance ext @Ext()
  }
}

// -----
// A DebugSourceNameAnnotation name must be a string.

// expected-error @below {{Unable to apply annotation: {class = "circt.DebugSourceNameAnnotation", name = 1 : i64, target = "~Top|Ext"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.DebugSourceNameAnnotation",
      name = 1 : i64,
      target = "~Top|Ext"
    }
  ]
} {
  // expected-error @below {{did not contain the correct type for key 'name'}}
  // expected-note @below {{The full Annotation is reproduced here}}
  firrtl.extmodule @Ext()
  firrtl.module @Top() {
    firrtl.instance ext @Ext()
  }
}

// -----
// A DebugSourceNameAnnotation must not target a port.

// expected-error @below {{Unable to apply annotation: {class = "circt.DebugSourceNameAnnotation", name = "Foo", target = "~Top|Ext>in"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.DebugSourceNameAnnotation",
      name = "Foo",
      target = "~Top|Ext>in"
    }
  ]
} {
  // expected-error @below {{circt.DebugSourceNameAnnotation must target an extmodule}}
  firrtl.extmodule @Ext(in in: !firrtl.uint<1>)
  firrtl.module @Top() {
    %i = firrtl.instance ext @Ext(in in: !firrtl.uint<1>)
  }
}

// -----
// Two different DebugSourceNameAnnotations on one extmodule conflict.

// expected-error @below {{Unable to apply annotation: {class = "circt.DebugSourceNameAnnotation", name = "B", target = "~Top|Ext"}}}
firrtl.circuit "Top" attributes {
  rawAnnotations = [
    {
      class = "circt.DebugSourceNameAnnotation",
      name = "A",
      target = "~Top|Ext"
    },
    {
      class = "circt.DebugSourceNameAnnotation",
      name = "B",
      target = "~Top|Ext"
    }
  ]
} {
  // expected-error @below {{circt.DebugSourceNameAnnotation extmodule already has a source name}}
  firrtl.extmodule @Ext()
  firrtl.module @Top() {
    firrtl.instance ext @Ext()
  }
}
