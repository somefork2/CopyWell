#!/usr/bin/env python3
"""Turns docs/store/shots/<lang>.json into strings/<lang>.js for shots.html.

A page opened from file:// may load a script but not fetch a JSON file, so the
tables are wrapped as `window.S = {...}`.
"""
import glob, json, os

here = os.path.dirname(os.path.abspath(__file__))
source = os.path.join(here, "..", "..", "docs", "store", "shots")
target = os.path.join(here, "strings")
os.makedirs(target, exist_ok=True)
for path in sorted(glob.glob(os.path.join(source, "*.json"))):
    code = os.path.basename(path)[:-5]
    with open(path, encoding="utf-8") as f:
        table = json.load(f)
    with open(os.path.join(target, f"{code}.js"), "w", encoding="utf-8") as f:
        f.write("window.S = " + json.dumps(table, ensure_ascii=False) + ";\n")
    print(code, len(table))
