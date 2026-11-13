import json
import sys

with open(sys.argv[1]) as stream:
  doc = json.load(stream)


def original(variable):
  return doc["original"][doc["types"][variable["type"]]["module"]]


def binding(original, generated, path=()):
  matches = [
      entry for entry in doc["bindings"]
      if entry["original"] == original and entry["generated"] == generated and
      entry.get("inline_path", []) == list(path)
  ]
  assert len(matches) == 1, matches
  return matches[0]


top = doc["original"]["Top"]["vars"]
assert set(original(top["leftSource"])["vars"]) == {"input", "outerValue"}
assert set(original(top["rightSource"])["vars"]) == {"input"}
assert "localChild" not in original(top["left_hw"])["vars"]
assert "localChild" not in original(top["right_hw"])["vars"]
assert "localChild" in original(top["other_hw"])["vars"]
top_binding = binding("Top", "Top")
for side in ("left", "right"):
  name = side + "Source"
  target = top_binding["vars"][name]
  assert target == {"$inline": [name]}, target
  module = doc["types"][top[name]["type"]]["module"]
  source = binding(module, "Top", target["$inline"])
  expected = {"input": side + "_hw.i"}
  if side == "left":
    expected["outerValue"] = "i"
  assert source["vars"] == expected, source

transparent_type = doc["types"][top["transparentSource"]["type"]]["module"]
transparent_target = top_binding["vars"]["transparentSource"]
transparent = binding(transparent_type, "Top", transparent_target["$inline"])
assert transparent["vars"] == {
    "input": "transparent_hw.i",
    "outerValue": "transparent_hw.i"
}, transparent
