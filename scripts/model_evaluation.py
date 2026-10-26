"""Model-retrieval evidence contracts; no inference backend or production ranking is selected here."""
import hashlib
import json
import math
import statistics
from pathlib import Path

SCHEMA = 1
MODALITIES = ("text", "code", "image", "document", "audio", "video", "application", "windows-settings")
BACKENDS = ("amd-vulkan", "nvidia-cuda", "vulkan", "openvino-npu", "metal")
IDENTITY = ("model", "revision", "runtime", "dtype", "dim", "backend", "device_id",
            "precision_profile", "build_identity", "driver_version", "runtime_version")


def load_json(path):
    path = Path(path)
    if path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Evidence exceeds the 64 MiB report bound")
    def invalid(value):
        raise ValueError("Non-finite JSON number: " + value)
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), parse_constant=invalid, object_pairs_hook=pairs)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False, allow_nan=False).encode("utf-8")).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def number(value, name, *, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(name + " must be finite")
    if value < 0 or positive and value <= 0:
        raise ValueError(name + " must be " + ("positive" if positive else "nonnegative"))
    return value


def distribution(values):
    checked = [number(value, "duration", positive=True) for value in values]
    if not checked:
        raise ValueError("At least one duration is required")
    ordered = sorted(checked)
    return {"samples": len(checked), "medianMs": statistics.median(checked),
            "p95Ms": ordered[math.ceil(.95 * len(ordered)) - 1], "valuesMs": checked}


def validate_receipt(info, backend, device):
    if not isinstance(info, dict) or info.get("execution_policy") != "accelerator-only":
        raise ValueError("Missing accelerator-only worker receipt")
    if backend not in BACKENDS or info.get("backend") != backend:
        raise ValueError("Worker backend differs from the explicit backend")
    for key in ("model", "revision", "runtime", "dtype"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ValueError("Missing worker " + key)
    if not isinstance(info.get("dim"), int) or isinstance(info["dim"], bool) or not 1 <= info["dim"] <= 16384:
        raise ValueError("Invalid worker dimension")
    if backend == "openvino-npu":
        if not str(info.get("device", "")).startswith("NPU"):
            raise ValueError("Worker did not verify NPU execution")
    elif not device or info.get("device_id") != device:
        raise ValueError("Worker did not verify the selected physical device")
    if backend == "nvidia-cuda" and (info.get("precision_profile") != "cuda-fp32-v1" or not info.get("build_identity")):
        raise ValueError("CUDA precision/build proof is missing")
    return {key: info.get(key) for key in IDENTITY}


def validate_vector(values, dimension):
    if len(values) != dimension or not all(isinstance(x, (int, float)) and not isinstance(x, bool)
                                          and math.isfinite(x) for x in values):
        raise ValueError("Worker returned an invalid vector")
    if abs(sum(x * x for x in values) - 1) >= .005:
        raise ValueError("Worker returned an unnormalized vector")
    return values


def validate_corpus(corpus):
    if not isinstance(corpus, dict) or corpus.get("schemaVersion") != SCHEMA:
        raise ValueError("Unsupported corpus schema")
    if corpus.get("origin") not in ("synthetic", "human-judged") or corpus.get("split") not in ("test", "tuning", "held-out"):
        raise ValueError("Corpus origin and split must be explicit")
    docs, queries = corpus.get("documents"), corpus.get("queries")
    if not isinstance(docs, list) or not 1 <= len(docs) <= 20000 or not isinstance(queries, list) or not 1 <= len(queries) <= 10000:
        raise ValueError("Corpus requires bounded documents and queries")
    ids = set()
    for doc in docs:
        identifier = doc.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in ids:
            raise ValueError("Document IDs must be unique nonempty strings")
        ids.add(identifier)
        if doc.get("modality") not in MODALITIES or doc.get("operation") not in ("text", "image", "audio"):
            raise ValueError("Invalid document modality or worker operation")
        operations = {"text": {"text"}, "code": {"text"}, "application": {"text"}, "windows-settings": {"text"},
                      "image": {"image"}, "document": {"text", "image"}, "audio": {"audio"}, "video": {"image", "audio"}}
        if doc["operation"] not in operations[doc["modality"]]:
            raise ValueError("Document operation does not cover its declared modality")
        if not isinstance(doc.get("input"), str) or not doc["input"]:
            raise ValueError("Document input must be nonempty")
        if doc["operation"] != "text" and (not isinstance(doc.get("sha256"), str) or len(doc["sha256"]) != 64):
            raise ValueError("Media inputs require a SHA-256")
        if not isinstance(doc.get("language"), str) or not doc["language"]:
            raise ValueError("Document language is required")
    query_ids = set()
    for query in queries:
        identifier = query.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in query_ids:
            raise ValueError("Query IDs must be unique nonempty strings")
        query_ids.add(identifier)
        if query.get("modality") not in MODALITIES or not isinstance(query.get("language"), str) or not query["language"]:
            raise ValueError("Query modality and language are required")
        if not isinstance(query.get("q"), str) or not 1 <= len(query["q"]) <= 4096:
            raise ValueError("Query text must contain 1..4096 characters")
        expected = query.get("expected")
        if not isinstance(expected, list) or len(expected) != len(set(expected)) or any(x not in ids for x in expected):
            raise ValueError("Expected IDs must refer to unique corpus documents")
    return corpus


def query_metrics(rows):
    if not rows:
        return {"queries": 0, "positiveQueries": 0, "negativeQueries": 0,
                "hitAt3": None, "recallAt10": None, "mrr": None, "precisionAt3": None,
                "negativeFalsePositiveRate": None}
    positive = negative = hit = relevant = found = returned = correct = false_positive = 0
    reciprocal = 0
    for row in rows:
        expected = set(row["expected"])
        ranked = row["ranked"][:10]
        matches = row["matches"][:3]
        if len(ranked) != len(set(ranked)) or len(matches) != len(set(matches)):
            raise ValueError("Duplicate retrieved document IDs")
        returned += len(matches)
        correct += len(expected.intersection(matches))
        if expected:
            positive += 1
            relevant += len(expected)
            found += len(expected.intersection(ranked))
            hit += bool(expected.intersection(matches))
            reciprocal += next((1 / (index + 1) for index, identifier in enumerate(ranked) if identifier in expected), 0)
        else:
            negative += 1
            false_positive += bool(matches)
    return {"queries": len(rows), "positiveQueries": positive, "negativeQueries": negative,
            "hitAt3": hit / positive if positive else None,
            "recallAt10": found / relevant if relevant else None,
            "mrr": reciprocal / positive if positive else None,
            "precisionAt3": correct / returned if returned else None,
            "negativeFalsePositiveRate": false_positive / negative if negative else None}


def metrics(rows):
    return {"all": query_metrics(rows),
            "byModality": {key: query_metrics([row for row in rows if row["modality"] == key]) for key in MODALITIES},
            "byLanguage": {key: query_metrics([row for row in rows if row["language"] == key])
                           for key in sorted({row["language"] for row in rows})}}


def valid_report(report):
    if report.get("schemaVersion") != SCHEMA or report.get("kind") != "model-retrieval-evaluation" or not report.get("completed"):
        raise ValueError("A completed version-1 model-retrieval report is required")
    validate_receipt(report["receipt"], report["backend"], report["deviceID"])
    if not report.get("corpusSHA256") or not report.get("helperSHA256") or not report.get("modelFiles"):
        raise ValueError("Report provenance is missing")
    rows = report.get("queries", [])
    ids = [row["id"] for row in rows]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("Query rows must have unique IDs")
    for row in rows:
        if row["modality"] not in MODALITIES or not row["language"]:
            raise ValueError("Query coverage is invalid")
        number(row["milliseconds"], "query duration", positive=True)
        if not isinstance(row.get("querySHA256"), str) or len(row["querySHA256"]) != 64:
            raise ValueError("Query hash is missing")
        if not isinstance(row.get("expected"), list) or not isinstance(row.get("ranked"), list) or not isinstance(row.get("matches"), list):
            raise ValueError("Ranked/expected IDs are missing")
        if len(row["expected"]) != len(set(row["expected"])) or not set(row["matches"]).issubset(row["ranked"]):
            raise ValueError("Query evidence is inconsistent")
    trials = report.get("documentTrials", [])
    if not isinstance(trials, list) or not 1 <= len(trials) <= 100:
        raise ValueError("Bounded document trials are required")
    if [row.get("trial") for row in trials] != list(range(len(trials))):
        raise ValueError("Trial IDs must be sequential and unique")
    for value in trials:
        number(value["elapsedMs"], "document duration", positive=True)
        number(value["documents"], "document work", positive=True)
    query_receipt = validate_receipt(report["queryReceipt"], report["backend"], report["deviceID"])
    if query_receipt != validate_receipt(report["receipt"], report["backend"], report["deviceID"]):
        raise ValueError("Query and document model identities differ")
    number(report["coldFullMs"], "cold full duration", positive=True)
    number(report["coldQueryMs"], "cold query duration", positive=True)
    metrics(rows)
    return report


def compare(baseline, candidate):
    for report in (baseline, candidate):
        valid_report(report)
    if baseline["receipt"].get("driver_version") != candidate["receipt"].get("driver_version"):
        raise ValueError("Evidence is not comparable: driver version")
    for key in ("corpusSHA256", "backend", "deviceID", "machine", "scope", "policy"):
        if baseline.get(key) != candidate.get(key):
            raise ValueError("Evidence is not comparable: " + key)
    left_rows = {row["id"]: row for row in baseline["queries"]}
    right_rows = {row["id"]: row for row in candidate["queries"]}
    if set(left_rows) != set(right_rows):
        raise ValueError("Query sets differ")
    for identifier, left in left_rows.items():
        right = right_rows[identifier]
        if any(left[key] != right[key] for key in ("modality", "language", "querySHA256", "expected")):
            raise ValueError("Query judgments or input changed: " + identifier)
    left, right = metrics(baseline["queries"]), metrics(candidate["queries"])
    missing, failures = [], []
    if any(report.get("corpusOrigin") != "human-judged" or report.get("corpusSplit") != "held-out"
           for report in (baseline, candidate)):
        missing.append("A human-judged held-out corpus is required")
    if len({row["querySHA256"] for row in baseline["queries"]}) < 100:
        missing.append("At least 100 distinct warm queries are required")
    for key in MODALITIES:
        bucket = left["byModality"][key]
        if bucket["positiveQueries"] < 10 or bucket["negativeQueries"] < 5:
            missing.append("Insufficient held-out positive/negative coverage: " + key)
    languages = [key for key, row in left["byLanguage"].items() if key != "en" and row["positiveQueries"] >= 10]
    if len(languages) < 2:
        missing.append("Require at least two non-English language groups with 10 positive queries each")
    if candidate["receipt"]["model"] == baseline["receipt"]["model"] and all(
            candidate["receipt"].get(key) == baseline["receipt"].get(key)
            for key in ("revision", "runtime", "dtype", "dim", "precision_profile", "build_identity")):
        missing.append("The candidate has the same model/profile identity as the baseline")
    for group in ("byModality", "byLanguage"):
        for key, before in left[group].items():
            after = right[group].get(key, {})
            for measure in ("recallAt10", "mrr"):
                if before[measure] is not None and after.get(measure) is not None and after[measure] + .01 < before[measure]:
                    failures.append(group + "/" + key + " regressed in " + measure)
    a, b = left["all"]["recallAt10"], right["all"]["recallAt10"]
    if a is None or b is None or b < a + .01:
        failures.append("Recall@10 did not improve by at least one percentage point")
    for key in ("application", "windows-settings"):
        row = right["byModality"][key]
        if row["positiveQueries"] and (row["precisionAt3"] is None or row["precisionAt3"] < .95 or row["hitAt3"] < .8):
            failures.append(key + " purpose gate failed")
    for key, row in right["byModality"].items():
        if row["negativeFalsePositiveRate"] is not None and row["negativeFalsePositiveRate"] > .05:
            failures.append(key + " negative false positives exceed 5%")
    before_latency = distribution([row["milliseconds"] for row in baseline["queries"]])
    after_latency = distribution([row["milliseconds"] for row in candidate["queries"]])
    if after_latency["p95Ms"] >= before_latency["p95Ms"]:
        failures.append("Warm query p95 is not faster")
    before_trials, after_trials = baseline["documentTrials"], candidate["documentTrials"]
    if len(before_trials) < 5 or len(before_trials) != len(after_trials):
        missing.append("At least five equal-work document trials are required")
    elif [row["documents"] for row in before_trials] != [row["documents"] for row in after_trials]:
        raise ValueError("Document trials performed different work")
    elif statistics.median(row["elapsedMs"] for row in after_trials) >= statistics.median(row["elapsedMs"] for row in before_trials):
        failures.append("Document encoding throughput is not faster")
    # Worker measurements cannot establish deployed indexing, reference agreement or UI behavior.
    missing.extend(["Retained-reference numerical acceptance for each model/backend",
                    "Five alternating paired full-indexing trials with equal completed work",
                    "Installed-application relevance, latency and regression acceptance"])
    return {"schemaVersion": SCHEMA, "status": "rejected" if failures else "incomplete",
            "recommendation": "keep-baseline", "productionModelChanged": False,
            "failures": failures, "missingGates": missing,
            "baselineMetrics": left, "candidateMetrics": right,
            "baselineWarmLatency": before_latency, "candidateWarmLatency": after_latency,
            "scope": baseline["scope"],
            "note": "Worker receipts are checked assertions, not independent proof of physical-device execution. No model is adopted by this tool."}
