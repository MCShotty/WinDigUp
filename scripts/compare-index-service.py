#!/usr/bin/env python3
"""Compare paired actual-service fixtures; synthetic vectors do not measure accelerator throughput."""
import json
import re
import statistics
import sys
from pathlib import Path

ENVIRONMENT = ("os", "logicalProcessors", "physicalMemoryBytes", "cache", "modelDelay", "scope")


def read(path):
    text = Path(path).read_text(encoding="utf-8")
    rows = {}
    for line in text.splitlines():
        if "INDEX_SERVICE_BENCHMARK: " not in line:
            continue
        row = json.loads(line.split("INDEX_SERVICE_BENCHMARK: ", 1)[1])
        if row.get("hardwareInference") is not False:
            raise ValueError("These fixtures must identify synthetic inference")
        name = row["workload"]
        if name in rows:
            if any(rows[name][key] != row[key] for key in ENVIRONMENT):
                raise ValueError("Environment changed between paired trials")
            rows[name]["trials"].extend(row["trials"])
        else:
            rows[name] = row
    if set(rows) != {"images", "documents", "mixed"}:
        raise ValueError("Missing actual-service workload measurements")
    memory = [int(value) for value in re.findall(r"(\d+)\s+maximum resident set size", text)]
    return rows, memory


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))]


def compare(left_rows, right_rows):
    report = {"schemaVersion": 2, "hardwareInference": False,
              "scope": "Paired actual IndexService trials with input-bound synthetic delays; same runner and warm files",
              "workloads": {}}
    for name, left in left_rows.items():
        right = right_rows[name]
        if any(left[key] != right[key] for key in ENVIRONMENT):
            raise ValueError("Reference environment or workload changed")
        pairs = []
        for row in [left, right]:
            trials = {trial["trial"]: trial for trial in row["trials"]}
            if len(row["trials"]) != 5 or set(trials) != set(range(5)):
                raise ValueError("Require five uniquely identified paired trials")
            pairs.append(trials)
        for number in range(5):
            for key in ("vectors", "inputs", "inferenceCalls", "syntheticDelayMs"):
                if pairs[0][number][key] != pairs[1][number][key]:
                    raise ValueError("Before and after performed different work: " + key)

        def metrics(row):
            trials = row["trials"]
            return {"trials": len(trials),
                    "medianWallMs": statistics.median(t["wallMs"] for t in trials),
                    "medianFilesPerSecond": statistics.median(t["filesPerSecond"] for t in trials),
                    "p95CompletionGapMs": percentile([x for t in trials for x in t["completionGapsMs"]], .95),
                    "inferenceCalls": [t["inferenceCalls"] for t in trials],
                    "syntheticDelayMs": [t["syntheticDelayMs"] for t in trials],
                    "peakActiveCalls": [t["peakActiveCalls"] for t in trials]}
        before, after = metrics(left), metrics(right)
        report["workloads"][name] = {
            "before": before, "after": after,
            "pairedWallChangePercent": [(pairs[1][n]["wallMs"] / pairs[0][n]["wallMs"] - 1) * 100 for n in range(5)],
            "medianWallChangePercent": (after["medianWallMs"] / before["medianWallMs"] - 1) * 100}
    return report


def main():
    before, before_memory = read(sys.argv[1])
    after, after_memory = read(sys.argv[2])
    report = compare(before, after)
    report["testProcessPeakRSSBytes"] = {
        "before": max(before_memory, default=None), "after": max(after_memory, default=None)}
    report["testProcessRSSSamplesBytes"] = {"before": before_memory, "after": after_memory}
    report["memoryScope"] = "Prebuilt --skip-build runs include SwiftPM/test subprocesses, not isolated helper RSS or GPU memory."
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
