#!/usr/bin/env python3
"""Check first-line alignment in a Maestro hierarchy captured after layout."""
import json
import re
import sys

hierarchy = json.load(open(sys.argv[1]))
block_id = sys.argv[2]

def nodes(node):
    yield node
    for child in node.get("children", []):
        yield from nodes(child)

row = next(n for n in nodes(hierarchy) if n.get("attributes", {}).get("resource-id") == "outliner.block." + block_id)
children = list(nodes(row))
bullet = next(n for n in children if n.get("attributes", {}).get("resource-id") == "button.outliner.zoom." + block_id)
text = next(n for n in children if n.get("attributes", {}).get("resource-id") == "block.rich.inline.0")
def top(node):
    return int(re.findall(r"-?\d+", node["attributes"]["bounds"])[1])

difference = abs(top(text) - top(bullet))
assert difference <= 2, f"First line starts {difference}pt away from its bullet line"
print("PASS: multiline text starts on the bullet line")
