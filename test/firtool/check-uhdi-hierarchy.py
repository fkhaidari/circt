import json
import sys

with open(sys.argv[2]) as stream:
  doc = json.load(stream)


def binding(original, generated, path=()):
  matches = [
      b for b in doc['bindings'] if b['original'] == original and
      b['generated'] == generated and b.get('inline_path', []) == list(path)
  ]
  assert len(matches) == 1, matches
  return matches[0]


def variables(scope):
  return doc['original'][scope['original']]['vars']


def child(scope, name):
  original = doc['types'][variables(scope)[name]['type']]['module']
  value = scope['vars'][name]
  if '$inline' in value:
    return binding(original, scope['generated'], value['$inline'])
  return binding(original, value['module'])


top = binding('Top', 'Top')
mode = sys.argv[1]
if mode == 'inline':
  assert set(variables(top)) == {'a', 'b', 'child'}, top
  nested = child(top, 'child')
  assert set(variables(nested)) == {'a', 'b', 'leaf'}, nested
  assert nested['generated'] == 'Top' and nested['inline_path'] == ['child']
  assert nested['vars']['leaf'] == {'$inst': 'child_leaf', 'module': 'Leaf'}
elif mode == 'extract':
  assert set(variables(top)) == {'a', 'b', 'dut'}, top
  dut = child(top, 'dut')
  assert set(variables(dut)) == {'a', 'b', 'child'}, dut
  nested = child(dut, 'child')
  assert set(variables(nested)) == {'a', 'b', 'bb'}, nested
  assert nested['vars']['a'] == 'dut.child.a', nested
  assert nested['vars']['b'] == 'dut.child.bb_0_out', nested
  bbox = child(nested, 'bb')
  assert set(variables(bbox)) == {'in', 'out'}, bbox
  assert bbox['generated'] == 'Top', bbox
  assert bbox['vars'] == {'in': 'bb.in', 'out': 'bb.out'}, bbox
elif mode == 'inject':
  assert set(variables(top)) == {'a', 'b', 'dut'}, top
  dut = child(top, 'dut')
  assert doc['original'][dut['original']]['name'] == 'DUT', dut
  assert set(variables(dut)) == {'a', 'b'}, dut
  assert top['vars']['dut'] == {
      '$inst': 'dut.Wrapper',
      'module': 'Wrapper'
  }, top
else:
  raise AssertionError(mode)
