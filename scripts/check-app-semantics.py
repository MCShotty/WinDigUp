#!/usr/bin/env python3
"""Evaluate the real installed model through its strict helper. Requires actual GPU/NPU hardware.

This never creates a CPU inference session. Test data is synthetic app metadata, not the user's application inventory.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

def metrics(rows, minimum):
    correct = returned = positives = found = negative = false_positive = 0
    for row in rows:
        expected = set(row["expected"])
        matches = [h["name"] for h in row["hits"] if h["cosine"] >= minimum][:3]
        returned += len(matches)
        correct += sum(name in expected for name in matches)
        if expected:
            positives += 1
            found += bool(expected.intersection(matches))
        else:
            negative += 1
            false_positive += bool(matches)
    return {"minimumCosine": round(minimum, 2), "precision": correct / returned if returned else 0,
            "recallAt3": found / positives if positives else 0,
            "negativeFalsePositiveRate": false_positive / negative if negative else 0}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--fixtures", type=Path, default=Path(__file__).resolve().parents[1] / "tests/applications/relevance.json")
    args = parser.parse_args()
    fixtures = json.loads(args.fixtures.read_text(encoding="utf-8"))
    names = {}
    documents = []
    for app in fixtures["applications"]:
        text = f'Application: {app["name"]}\nPurpose: {app["purpose"]}\nAliases: \nPublisher: \nKeywords: '
        identifier = "app:" + hashlib.sha256(app["name"].encode()).hexdigest()
        names[identifier] = app["name"]
        documents.append({"id": identifier, "name": app["name"], "text": text, "hash": hashlib.sha256(text.encode()).hexdigest()})
    revision = hashlib.sha256(json.dumps(documents, sort_keys=True).encode()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="digup-app-relevance-") as work:
        with open(Path(work) / "helper.log", "w", encoding="utf-8") as log:
            process = subprocess.Popen([str(args.helper.resolve()), "search-service", "--index", work],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, encoding="utf-8")
            counter = 0
            def request(op, **fields):
                nonlocal counter
                counter += 1
                process.stdin.write(json.dumps({"op": op, "id": counter, **fields}) + "\n")
                process.stdin.flush()
                for line in process.stdout:
                    reply = json.loads(line)
                    if reply.get("id") != counter:
                        continue
                    if reply.get("ok") is False:
                        raise RuntimeError(reply.get("error", "Helper rejected request"))
                    return reply
                raise RuntimeError(f"Helper ended unexpectedly: {process.poll()}")
            try:
                ready = request("prewarm")
                if ready.get("encoder") != "ready":
                    raise RuntimeError("Selected GPU/NPU encoder unavailable; no CPU fallback or relevance result was produced")
                request("apps_catalog", revision=revision, documents=documents)
                for _ in range(len(documents) + 1):
                    state = request("apps_index_step")
                    if state.get("execution_policy") != "accelerator-only":
                        raise RuntimeError("Missing accelerator-only execution proof")
                    if state["embedded"] == state["total"]:
                        break
                else:
                    raise RuntimeError("Application embeddings did not finish")
                rows = []
                for query in fixtures["queries"]:
                    reply = request("apps_search", q=query["q"], revision=revision, minimum_cosine=0.0)
                    rows.append({**query, "hits": [{"name": names[h["id"]], "cosine": h["cosine"]} for h in reply["hits"]]})
                candidates = [metrics(rows, i / 100) for i in range(30, 86)]
                passing = [m for m in candidates if m["precision"] >= .95 and m["recallAt3"] >= .8 and m["negativeFalsePositiveRate"] <= .05]
                report = {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(), "platform": platform.platform(),
                          "fixtureVersion": fixtures["version"], "execution": state, "queries": rows,
                          "currentGate": metrics(rows, .60), "passingThresholds": passing,
                          "recommendedGate": max(passing, key=lambda m: (m["recallAt3"], m["precision"], m["minimumCosine"])) if passing else None}
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
                print(json.dumps({"currentGate": report["currentGate"], "recommendedGate": report["recommendedGate"]}, indent=2))
                current = report["currentGate"]
                return 0 if current["precision"] >= .95 and current["recallAt3"] >= .8 and current["negativeFalsePositiveRate"] <= .05 else 1
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

if __name__ == "__main__":
    raise SystemExit(main())
