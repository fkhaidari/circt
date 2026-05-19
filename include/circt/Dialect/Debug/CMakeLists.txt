add_circt_dialect(Debug dbg)
add_circt_doc(DebugOps Dialects/DebugOps -gen-op-doc)
add_circt_doc(DebugTypes Dialects/DebugTypes -gen-typedef-doc -dialect dbg)

set(LLVM_TARGET_DEFINITIONS Debug.td)
mlir_tablegen(DebugAttributes.h.inc -gen-attrdef-decls --attrdefs-dialect=dbg)
mlir_tablegen(DebugAttributes.cpp.inc -gen-attrdef-defs --attrdefs-dialect=dbg)
add_public_tablegen_target(MLIRDebugAttributesIncGen)
add_dependencies(circt-headers MLIRDebugAttributesIncGen)

add_dependencies(circt-headers MLIRDebugIncGen)
