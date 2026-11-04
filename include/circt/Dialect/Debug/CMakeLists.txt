add_circt_dialect(Debug dbg)
add_circt_doc(DebugOps Dialects/DebugOps -gen-op-doc)
add_circt_doc(DebugTypes Dialects/DebugTypes -gen-typedef-doc -dialect dbg)

add_dependencies(circt-headers MLIRDebugIncGen)

set(LLVM_TARGET_DEFINITIONS Debug.td)
mlir_tablegen(DebugEnums.h.inc -gen-enum-decls)
mlir_tablegen(DebugEnums.cpp.inc -gen-enum-defs)
add_public_tablegen_target(CIRCTDebugEnumsIncGen)
add_dependencies(circt-headers CIRCTDebugEnumsIncGen)
