//===- LocationUtils.cpp - Shared loc helpers for DI emitters ------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "LocationUtils.h"

#include "mlir/IR/BuiltinAttributes.h"
#include "llvm/Support/FileSystem.h"

using namespace mlir;

namespace circt {
namespace debuginfo {

void findLocations(Location loc, unsigned level,
                   SmallVectorImpl<FileLineColLoc> &locs) {
  if (auto n = dyn_cast<NameLoc>(loc)) {
    if (n.getName() == "emitted") {
      if (level == 0)
        return;
      --level;
    }
    findLocations(n.getChildLoc(), level, locs);
  } else if (auto f = dyn_cast<FusedLoc>(loc)) {
    auto meta = dyn_cast_or_null<StringAttr>(f.getMetadata());
    if (meta && meta.getValue() == "verilogLocations") {
      if (level == 0)
        return;
      --level;
    }
    for (auto inner : f.getLocations())
      findLocations(inner, level, locs);
  } else if (auto fileLoc = dyn_cast<FileLineColLoc>(loc)) {
    if (level == 0)
      locs.push_back(fileLoc);
  }
}

bool cachedExists(StringRef path, llvm::StringMap<bool> &cache) {
  auto [it, inserted] = cache.try_emplace(path, false);
  if (inserted)
    it->second = llvm::sys::fs::exists(path);
  return it->second;
}

FileLineColLoc bestLocation(Location loc, bool emitted, bool onlyExisting,
                            llvm::StringMap<bool> *existsCache) {
  SmallVector<FileLineColLoc> locs;
  findLocations(loc, emitted ? 1 : 0, locs);
  if (onlyExisting) {
    llvm::erase_if(locs, [&](FileLineColLoc l) {
      StringRef p = l.getFilename().getValue();
      return !(existsCache ? cachedExists(p, *existsCache)
                           : llvm::sys::fs::exists(p));
    });
  }
  for (auto l : locs)
    if (!l.getFilename().getValue().ends_with(".fir"))
      return l;
  for (auto l : locs)
    if (l.getFilename().getValue().ends_with(".fir"))
      return l;
  return {};
}

} // namespace debuginfo
} // namespace circt
