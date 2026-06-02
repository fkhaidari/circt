add_circt_dialect_library(CIRCTHWTransforms
  HWAggregateToComb.cpp
  HWConvertBitcasts.cpp
  HWBypassInnerSymbols.cpp
  HWIMDeadCodeElim.cpp
  HWParameterizeConstantPorts.cpp
  HWPrintInstanceGraph.cpp
  HWSpecialize.cpp
  PrintHWModuleGraph.cpp
  FlattenIO.cpp
  UhdiVerilogSnapshot.cpp
  VerifyInnerRefNamespace.cpp
  FlattenModules.cpp
  FooWires.cpp
  HWVectorization.cpp

  DEPENDS
  CIRCTHWTransformsIncGen

  LINK_LIBS PUBLIC
  CIRCTDebug
  CIRCTHW
  CIRCTSV
  CIRCTSeq
  CIRCTComb
  CIRCTSupport
  MLIRIR
  MLIRPass
  MLIRTransformUtils
)
