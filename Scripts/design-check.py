#!/usr/bin/env python3
"""Design rule check (functional minimal dark): red is reserved for live. Fails on any other red use in App/UI.

Allowed red tokens (liveRed, recordRed, liveEnd) only in the files that draw live state: the LIVE tag, the Go live
row and the end-of-broadcast control. Palette.red, Palette.mismatch and system reds are never allowed.
"""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
allowed = {"liveRed": {"Components.swift", "Theme.swift"}, "recordRed": {"HomeView.swift", "Theme.swift"},
           "liveEnd": {"StreamViews.swift", "Theme.swift"}}
banned = re.compile(r"Palette\.(red|mismatch)\b|Color\.red\b|UIColor\.(systemRed|red)\b|\.foregroundStyle\(\.red\)|\.tint\(\.red\)")
problems = []
for path in sorted((root / "App").rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    for n, line in enumerate(text.splitlines(), 1):
        if banned.search(line):
            problems.append(f"{path.relative_to(root)}:{n}: red outside live: {line.strip()}")
        for token, files in allowed.items():
            if f"Palette.{token}" in line and path.name not in files:
                problems.append(f"{path.relative_to(root)}:{n}: {token} outside its live use: {line.strip()}")
for p in problems: print(p)
print("design-check:", "FAIL" if problems else "PASS", f"({len(problems)} problems)")
sys.exit(1 if problems else 0)
