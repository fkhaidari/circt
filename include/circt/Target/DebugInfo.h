//===- DebugInfo.h - Debug info emission ------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file declares entry points to emit debug information.
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_TARGET_DEBUGINFO_H
#define CIRCT_TARGET_DEBUGINFO_H

#include "circt/Support/LLVM.h"
#include "llvm/Support/raw_ostream.h"

namespace circt {
namespace debug {

/// Register all debug information emission flavors as from-MLIR translations.
void registerTranslations();

/// Dump the debug information in the given `module` in a human-readable format.
LogicalResult dumpDebugInfo(Operation *module, llvm::raw_ostream &os);

/// Options for HGLDD emission.
struct EmitHGLDDOptions {
  /// A prefix prepended to all source file locations. This is useful if the
  /// tool ingesting the HGLDD file is run from a different directory and
  /// requires help finding the source files.
  StringRef sourceFilePrefix = "";
  /// A prefix prepended to all output file locations. This is useful if the
  /// tool ingesting the HGLDD file expects generated output files to be
  /// reported relative to a different directory.
  StringRef outputFilePrefix = "";
  /// The directory in which to place HGLDD output files.
  StringRef outputDirectory = "";
  /// Only consider location information for files that actually exist on disk.
  /// This can help strip out placeholder names such as `<stdin>` or
  /// `<unknown>`, and force the HGLDD file to only refer to files that actually
  /// exist.
  bool onlyExistingFileLocs = false;
};

/// Serialize the debug information in the given `module` into the HGLDD format
/// and writes it to `output`.
LogicalResult emitHGLDD(Operation *module, llvm::raw_ostream &os,
                        const EmitHGLDDOptions &options = {});

/// Serialize the debug information in the given `module` into the HGLDD format
/// and emit one companion HGLDD file per emitted HDL file. This requires that
/// a prior emission pass such as `ExportVerilog` has annotated emission
/// locations on the operations in `module`.
LogicalResult emitSplitHGLDD(Operation *module,
                             const EmitHGLDDOptions &options = {});

/// Options for UHDI emission.
struct EmitUHDIOptions {
  /// Prefix prepended to source-file locations surfaced in
  /// representations.chisel.files.
  StringRef sourceFilePrefix = "";
  /// Prefix prepended to HDL-file locations in representations.verilog.files.
  StringRef outputFilePrefix = "";
  /// Only emit locations whose files actually exist on disk.
  bool onlyExistingFileLocs = false;
};

/// Serialize the debug information in the given `module` into the pool-based
/// UHDI JSON format and write it to `output`.
LogicalResult emitUHDI(Operation *module, llvm::raw_ostream &os,
                       const EmitUHDIOptions &options = {});

} // namespace debug
} // namespace circt

#endif // CIRCT_TARGET_DEBUGINFO_H
