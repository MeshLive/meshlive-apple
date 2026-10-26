#!/usr/bin/env python3
"""Summarize one or two explicitly saved diagnostic exports; never infer acoustic/display latency."""
import json
import sys
from pathlib import Path
if len(sys.argv) not in (2, 3):
    raise SystemExit("Usage: python3 Scripts/diagnose-export.py iphone-a.json [iphone-b.json]")
runs = []
for file in sys.argv[1:]:
    d = json.loads(Path(file).read_text())
    required = {"build", "os", "model", "runID", "sessionID", "transport", "submittedBytes", "receivedBytes", "audio", "events"}
    missing = required - d.keys()
    if missing: raise SystemExit(f"{file}: missing fields {sorted(missing)}")
    runs.append(d)
    summary = {k: d[k] for k in ["build", "os", "model", "runID", "sessionID", "role", "transport", "profile", "disconnect", "submittedBytes", "receivedBytes", "applicationAcknowledgedBytes", "audioSent", "audioReceived"]}
    summary["audio"] = {k: d["audio"][k] for k in ["captureRate", "sessionRate", "ioDuration", "conversion", "route", "jitterMilliseconds", "underruns", "overflows"]}
    print(json.dumps(summary, indent=2))
if len(runs) == 2:
    a, b = runs
    if a["sessionID"] == "none" or a["sessionID"] != b["sessionID"]: raise SystemExit("Exports do not identify the same encrypted session")
    print(f"A → B: sent audio packets {a['audioSent']}; B received {b['audioReceived']}")
    print(f"B → A: sent audio packets {b['audioSent']}; A received {a['audioReceived']}")
print("Counters describe application/OS events. Listening, echo, physical latency and sustained video require the physical checks in docs/dev/testing.md.")
