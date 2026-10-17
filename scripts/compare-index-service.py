#!/usr/bin/env python3
"""Compare retained actual-service fixtures. Synthetic vectors do not measure accelerator throughput."""
import json
import re
import statistics
import sys
from pathlib import Path

def read(path):
    text = Path(path).read_text(encoding="utf-8")
    rows = {}
    for line in text.splitlines():
        if "INDEX_SERVICE_BENCHMARK: " in line:
            row = json.loads(line.split("INDEX_SERVICE_BENCHMARK: ", 1)[1])
            rows[row["workload"]] = row
    if set(rows) != {"images", "documents", "mixed"}:
        raise ValueError("Missing actual-service workload measurements")
    memory = re.findall(r"(\d+)\s+maximum resident set size", text)
    return rows, int(memory[-1]) if memory else None

def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values)-1, int((len(values)-1)*fraction))]

before, before_memory = read(sys.argv[1])
after, after_memory = read(sys.argv[2])
report = {"schemaVersion": 1, "hardwareInference": False,
          "scope": "Actual IndexService with delayed synthetic vectors; same hosted runner and warm fixture files",
          "testProcessPeakRSSBytes": {"before": before_memory, "after": after_memory},
          "memoryScope": "time -l includes SwiftPM/test subprocesses; it is not isolated helper RSS or GPU memory.",
          "workloads": {}}
for name in before:
    left, right = before[name], after[name]
    if any(left[key] != right[key] for key in ["os", "logicalProcessors", "physicalMemoryBytes", "cache", "modelDelay"]):
        raise ValueError("Reference environment or workload changed")
    for key in ["vectors", "inputs"]:
        if {trial[key] for trial in left["trials"]} != {trial[key] for trial in right["trials"]}:
            raise ValueError("Before and after did different work")
    def metrics(row):
        trials = row["trials"]
        return {"trials": len(trials),
                "medianWallMs": statistics.median(t["wallMs"] for t in trials),
                "medianFilesPerSecond": statistics.median(t["filesPerSecond"] for t in trials),
                "p95CompletionGapMs": percentile([x for t in trials for x in t["completionGapsMs"]], .95),
                "inferenceCalls": [t["inferenceCalls"] for t in trials],
                "peakActiveCalls": [t["peakActiveCalls"] for t in trials]}
    old, new = metrics(left), metrics(right)
    report["workloads"][name] = {"before": old, "after": new,
        "medianWallChangePercent": (new["medianWallMs"]/old["medianWallMs"]-1)*100}
print(json.dumps(report, indent=2))
