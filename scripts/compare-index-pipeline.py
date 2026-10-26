#!/usr/bin/env python3
"""Summarize the same actual-Indexer fixture on the base and proposed revisions."""
import json
import math
from pathlib import Path
import statistics
import sys


def load(path):
    prefix = "INDEX_PIPELINE_BENCHMARK: "
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    reports = [json.loads(line.split(prefix, 1)[1]) for line in lines if prefix in line]
    if len(reports) != 1 or len(reports[0]["trials"]) != 5:
        raise ValueError(f"Missing five-trial benchmark in {path}")
    return reports[0]


def summarize(report):
    trials = report["trials"]
    gaps = sorted(value for row in trials for value in row["completionGapsMs"])
    return {
        "wallMedianMs": statistics.median(row["wallMs"] for row in trials),
        "throughputMedianFilesPerSecond": statistics.median(row["filesPerSecond"] for row in trials),
        "completionGapP95Ms": gaps[math.ceil(len(gaps) * .95) - 1],
        "inferenceCallsPerTrial": [row["inferenceCalls"] for row in trials],
        "peakActiveCallsPerTrial": [row["peakActiveCalls"] for row in trials],
    }


before, after = map(load, sys.argv[1:3])
for key in ("workload", "cache", "inferenceDelay", "physicalMemoryBytes", "logicalProcessors", "os"):
    if before[key] != after[key]:
        raise ValueError(f"Incomparable {key}")
result = {
    "schemaVersion": 1,
    "scope": "Actual file extraction, scheduling and SQLite writes with delayed synthetic embeddings; not GPU performance",
    "machine": {key: before[key] for key in ("os", "logicalProcessors", "physicalMemoryBytes")},
    "workload": before["workload"], "cache": before["cache"],
    "before": summarize(before), "after": summarize(after),
}
result["medianElapsedReduction"] = 1 - result["after"]["wallMedianMs"] / result["before"]["wallMedianMs"]
print(json.dumps(result, indent=2))
