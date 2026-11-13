import json
import sys

with open(sys.argv[1]) as stream:
  doc = json.load(stream)


def binding(original, generated, path=()):
  matches = [
      entry for entry in doc["bindings"]
      if entry["original"] == original and entry["generated"] == generated and
      entry.get("inline_path", []) == list(path)
  ]
  assert len(matches) == 1, matches
  return matches[0]


def child(parent, name):
  variable = doc["original"][parent["original"]]["vars"][name]
  original = doc["types"][variable["type"]]["module"]
  return binding(original, parent["generated"], parent["vars"][name]["$inline"])


top = binding("Top", "Top")
assert set(top["vars"]) == {"left", "right"}, top
for side in ("left", "right"):
  sub = child(top, side)
  assert set(sub["vars"]) == {"c"}, sub
  c = child(sub, "c")
  assert set(c["vars"]) == {"a", "bbox"}, c
  assert c["vars"]["a"] == side + "_hw.a", c
  bbox = child(c, "bbox")
  assert bbox["vars"] == {"i": side + "_box_hw.i"}, bbox
