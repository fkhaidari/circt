add_circt_dialect_library(CIRCTDebug
  DebugAttributes.cpp
  DebugDialect.cpp
  DebugOps.cpp
  DebugTypes.cpp

  ADDITIONAL_HEADER_DIRS
  ${CIRCT_MAIN_INCLUDE_DIR}/circt/Dialect/Debug

  DEPENDS
  MLIRDebugAttributesIncGen
  MLIRDebugIncGen

  LINK_COMPONENTS
  Support

  LINK_LIBS PUBLIC
  MLIRIR
  MLIRInferTypeOpInterface
  MLIRSideEffectInterfaces
)
