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
  target = parent["vars"][name]
  return binding(original, parent["generated"], target["$inline"])


captured = binding("Captured", "Captured")
assert set(captured["vars"]) == {"child"}, captured
captured_child = child(captured, "child")
assert captured_child["vars"] == {"a": "a", "b": "layer_hw.b"}, captured_child
assert set(doc["original"][captured_child["original"]]["vars"]) == {"a", "b"}

repeated = binding("Repeated", "Repeated")
assert set(repeated["vars"]) == {"child", "child_1"}, repeated
left = child(repeated, "child")
right = child(repeated, "child_1")
assert left["inline_path"] == ["left_hw", "child"], left
assert right["inline_path"] == ["right_hw", "child"], right
assert left["vars"] == {"a": "left_hw.a"}, left
assert right["vars"] == {"a": "right_hw.a"}, right

flattened = binding("Flattened", "Flattened")
assert set(flattened["vars"]) == {"left", "right"}, flattened
for side in ("left", "right"):
  outer = child(flattened, side)
  assert set(outer["vars"]) == {"child"}, outer
  inner = child(outer, "child")
  assert inner["inline_path"] == [side, "child"], inner
  assert inner["vars"] == {"a": side + "Value"}, inner

live = binding("LiveCaptured", "LiveCaptured")
assert set(live["vars"]) == {"child"}, live
live_child = child(live, "child")
assert live_child["vars"] == {"a": "child_hw.a", "b": "layer_hw.b"}, live_child
