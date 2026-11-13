import json
import sys

with open(sys.argv[1]) as stream:
  doc = json.load(stream)
top = doc["original"]["Top"]["vars"]


def module_of(variable):
  return doc["types"][variable["type"]]["module"]


selected = doc["original"][module_of(top["wrapper_hw"])]["vars"]
other = doc["original"][module_of(top["other_wrapper_hw"])]["vars"]
assert "inner_hw" not in selected, selected
assert "inner_hw" in other, other
assert "nestedSource" in top, top
assert "leftSource" in top and "rightSource" in top, top
assert "left_hw" not in top and "right_hw" not in top, top

external = doc["original"][module_of(top["externalSource"])]
assert external["name"] == "example.External", external
assert external["x-chisel"]["params"]["width"] == 8, external
for name in ("leftSource", "rightSource", "nestedSource"):
  child = doc["original"][module_of(top[name])]
  assert child["name"] == "example.Child", child
  assert child["x-chisel"]["params"]["width"] == 8, child

assert "transparentChild" in top, top
assert "transparent_child_hw" not in top, top

binding_keys = [(entry["original"], entry["generated"],
                 tuple(entry.get("inline_path", [])))
                for entry in doc["bindings"]]
assert len(binding_keys) == len(set(binding_keys)), binding_keys
