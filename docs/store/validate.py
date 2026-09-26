#!/usr/bin/env python3
"""Check a store translation: python3 docs/store/validate.py <lang>

Reads docs/store/metadata/<lang>.json and docs/store/shots/<lang>.json against
the English sources and App Store Connect's limits. Exit code 0 when clean.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
lang = sys.argv[1]
LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "keywords": 100, "description": 4000, "whatsNew": 4000}
SYMBOLS = ["⌥⌘V", "⇧⌘9", "⇧⌘0", "⏎", "⌘1–9", "⌘Y"]

def load(kind, code):
    with open(os.path.join(HERE, kind, f"{code}.json"), encoding="utf-8") as f:
        return json.load(f)

problems = []
try:
    meta, en_meta = load("metadata", lang), load("metadata", "en")
    shots, en_shots = load("shots", lang), load("shots", "en")
except Exception as error:
    print(f"cannot read files for {lang}: {error}")
    sys.exit(1)

for key, limit in LIMITS.items():
    value = meta.get(key)
    if not isinstance(value, str) or not value.strip():
        problems.append(f"metadata: {key} missing")
        continue
    if len(value) > limit:
        problems.append(f"metadata: {key} is {len(value)} characters, limit {limit}")
if meta.get("name") != "CopyWell":
    problems.append("metadata: name must stay exactly 'CopyWell'")
keywords = meta.get("keywords", "")
if ", " in keywords:
    problems.append("metadata: keywords must be separated by commas without spaces")
for url in re.findall(r"https?://\S+", en_meta["description"]):
    if url not in meta.get("description", ""):
        problems.append(f"metadata: description lost the link {url}")
for symbol in ["⌥⌘V", "⇧⌘9", "⇧⌘0"]:
    if symbol in en_meta["description"] and symbol not in meta.get("description", ""):
        problems.append(f"metadata: description lost {symbol}")

for key, english in en_shots.items():
    value = shots.get(key)
    if not isinstance(value, str) or not value.strip():
        problems.append(f"shots: {key} missing")
        continue
    for symbol in SYMBOLS:
        if english.count(symbol) != value.count(symbol):
            problems.append(f"shots: {key} must keep {symbol}")
    if len(value) > max(len(english) * 2.2, len(english) + 24):
        problems.append(f"shots: {key} is much longer than the English ({len(value)} vs {len(english)}); shorten it")
extra = set(shots) - set(en_shots)
if extra:
    problems.append(f"shots: unexpected keys {sorted(extra)[:4]}")

query = shots.get("search.query", "").casefold()
for key in ["clip.invoiceTitle", "search.r2", "search.r4"]:
    if query and query not in shots.get(key, "").casefold():
        problems.append(f"shots: {key} must contain the search word '{shots.get('search.query')}' so the search result makes sense")

for problem in problems[:60]:
    print(problem)
print(f"{lang}: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
