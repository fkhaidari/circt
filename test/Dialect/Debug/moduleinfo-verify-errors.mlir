// RUN: circt-opt %s --verify-diagnostics --split-input-file

// -----
// dbg.moduleinfo that is not a dictionary.

// expected-error @+1 {{'dbg.moduleinfo' must be a dictionary}}
hw.module @NotADictionary() attributes {dbg.moduleinfo = "Top"} {}

// -----
// dbg.moduleinfo with a non-string type name.

// expected-error @+1 {{'dbg.moduleinfo' type name must be a string}}
hw.module @TypeNameNotAString() attributes {dbg.moduleinfo = {typeName = 42}} {}

// -----
// dbg.moduleinfo with params that are not an array.

// expected-error @+1 {{'dbg.moduleinfo' params must be an array}}
hw.module @ParamsNotAnArray() attributes {
    dbg.moduleinfo = {typeName = "Top", params = "width"}} {}

// -----
// dbg.moduleinfo with a param that does not name itself.

// expected-error @+1 {{'dbg.moduleinfo' params must be dictionaries with a string name}}
hw.module @ParamWithoutName() attributes {
    dbg.moduleinfo = {typeName = "Top", params = [{value = "8"}]}} {}
