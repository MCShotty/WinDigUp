#!/usr/bin/env python3
"""Collect local, strict-worker model retrieval measurements; never changes a production index."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import struct
import subprocess
import threading
import time

import model_evaluation as contract


class Worker:
    def __init__(self, helper, models, backend, device, output, timeout, text_only):
        self.timeout, self.counter = timeout, 0
        self.lines = queue.Queue(maxsize=64)
        self.closed = threading.Event()
        environment = dict(os.environ, DIGUP_ACCELERATOR=backend, DIGUP_GPU=device,
                           DIGUP_GPU_JOBS="1", DIGUP_INFERENCE_PRIORITY="foreground")
        environment["DIGUP_OPENVINO_MODELS" if backend == "openvino-npu" else "DIGUP_MODELS"] = str(models)
        command = [str(helper), "worker", "--index", str(output / "disposable-index"),
                   "--worker-log", str(output / ("query-native.log" if text_only else "full-native.log"))]
        if text_only:
            command.append("--text-only")
        self.log = (output / ("query-stderr.log" if text_only else "full-stderr.log")).open("w", encoding="utf-8")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                        text=True, encoding="utf-8", env=environment, bufsize=1)
        def read():
            try:
                for line in self.process.stdout:
                    if len(line) > 4 * 1024 * 1024:
                        self.put(ValueError("Worker reply exceeds the 4 MiB bound"))
                        break
                    self.put(line)
            except (OSError, ValueError):
                pass
            finally:
                self.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        began = time.perf_counter()
        try:
            first = self.line()
            if not first.get("ready"):
                raise RuntimeError(first.get("error", "Worker did not become ready"))
            self.info = first["info"]
            self.identity = contract.validate_receipt(self.info, backend, device)
            self.cold_ms = (time.perf_counter() - began) * 1000
        except BaseException:
            self.close()
            raise

    def put(self, value):
        while not self.closed.is_set():
            try:
                self.lines.put(value, timeout=.1)
                return
            except queue.Full:
                continue

    def line(self):
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Worker response deadline expired")
            try:
                value = self.lines.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError("Worker response deadline expired") from error
            if value is None:
                raise RuntimeError("Worker exited before completing a request")
            if isinstance(value, Exception):
                raise value
            response = json.loads(value, parse_constant=lambda x: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
            if response.get("event") == "inference_activity":
                continue
            return response

    def embed(self, operation, value, budget=None):
        self.counter += 1
        request = {"id": self.counter, "op": operation, "inputs": [value]}
        if budget is not None:
            request["budget"] = budget
        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        response = self.line()
        if response.get("id") != self.counter or response.get("ok") is not True:
            raise RuntimeError(response.get("error", "Unexpected worker response"))
        if response.get("errors") and any(response["errors"]):
            raise RuntimeError(str(response["errors"]))
        dimension = self.info["dim"]
        if response.get("dim") != dimension or response.get("count") != 1:
            raise ValueError("Worker vector shape changed")
        raw = base64.b64decode(response["vectors"], validate=True)
        if len(raw) != dimension * 4:
            raise ValueError("Truncated worker vector")
        return contract.validate_vector(list(struct.unpack("<" + "f" * dimension, raw)), dimension)

    def close(self):
        self.closed.set()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()
        if hasattr(self, "reader"):
            self.reader.join(timeout=2)


DEFAULT_PROMPTS = {"id": "embeddinggemma-2-v1", "document": "title: {title} | text: {text}",
                   "query": "task: search result | query: {text}", "codeQuery": "task: code retrieval | query: {text}"}


def validate_prompts(profile):
    if not isinstance(profile.get("id"), str) or not profile["id"]:
        raise ValueError("Prompt profile ID is required")
    for key in ("document", "query", "codeQuery"):
        value = profile.get(key)
        if not isinstance(value, str) or value.count("{text}") != 1 or len(value) > 4096:
            raise ValueError("Each prompt requires one {text} placeholder")
        rest = value.replace("{text}", "").replace("{title}", "")
        if "{" in rest or "}" in rest or key != "document" and "{title}" in value:
            raise ValueError("Only document {title} and {text} placeholders are supported")
    return profile


def prompt(template, text, title="none"):
    return template.replace("{title}", title).replace("{text}", text)


def frame_document(document, root, profile=None):
    if document["operation"] == "text":
        return prompt((profile or DEFAULT_PROMPTS)["document"], document["input"], document.get("title") or "none")
    original = root / document["input"]
    path = original.resolve()
    if original.is_symlink() or not path.is_file() or contract.file_digest(path) != document["sha256"]:
        raise ValueError("Media input is missing or changed: " + document["id"])
    return str(path)


def collect(args):
    corpus = contract.validate_corpus(contract.load_json(args.corpus))
    root = (args.corpus.parent / corpus.get("root", ".")).resolve()
    profile = validate_prompts(contract.load_json(args.prompt_profile) if args.prompt_profile else DEFAULT_PROMPTS)
    documents = corpus["documents"]
    prepared = {doc["id"]: frame_document(doc, root, profile) for doc in documents}
    args.output.mkdir(parents=True, exist_ok=False)
    model_files = {str(path.relative_to(args.models)): contract.file_digest(path)
                   for path in sorted(args.models.rglob("*")) if path.is_file() and not path.is_symlink()}
    if not model_files:
        raise ValueError("Model directory contains no model artifacts")
    report = {"schemaVersion": contract.SCHEMA, "kind": "model-retrieval-evaluation", "completed": False,
              "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "backend": args.backend, "deviceID": args.device,
              "machine": {"referenceID": args.machine_id, "os": platform.platform(), "processor": platform.processor()},
              "helperSHA256": contract.file_digest(args.helper), "modelFiles": model_files,
              "corpusSHA256": contract.digest(corpus), "corpusOrigin": corpus["origin"], "corpusSplit": corpus["split"],
              "scope": "Exact cosine model retrieval through strict worker IPC; excludes file boosts, lexical ranking, extraction, UI and full indexing",
              "policy": {"minimumCosine": args.minimum_cosine, "distanceFromBest": args.distance_from_best,
                         "textProfile": "full2048/query512", "jobs": 1},
              "promptProfile": profile, "promptProfileSHA256": contract.digest(profile),
              "documentTrials": [], "queries": [], "peakDedicatedGPUMemoryBytes": None,
              "notMeasured": ["GPU utilization", "dedicated GPU memory", "full indexing", "installed UI latency"],
              "acceptance": "No production adoption. Retained-reference and deployed-pipeline acceptance remain required."}
    output = args.output / "model-evaluation.json"
    try:
        vectors = {}
        worker = Worker(args.helper, args.models, args.backend, args.device, args.output, args.timeout, False)
        try:
            report["receipt"] = worker.info
            report["coldFullMs"] = worker.cold_ms
            for trial in range(args.trials):
                began = time.perf_counter()
                made = {doc["id"]: worker.embed(doc["operation"], prepared[doc["id"]], doc.get("budget"))
                        for doc in documents}
                elapsed = (time.perf_counter() - began) * 1000
                if vectors:
                    minimum = min(sum(a * b for a, b in zip(vector, vectors[key])) for key, vector in made.items())
                    if minimum < .999:
                        raise ValueError("Repeated vectors differ by more than the retained repeatability tolerance")
                vectors = made
                report["documentTrials"].append({"trial": trial, "documents": len(documents), "elapsedMs": elapsed})
        finally:
            worker.close()
        worker = Worker(args.helper, args.models, args.backend, args.device, args.output, args.timeout, True)
        try:
            if worker.identity != contract.validate_receipt(report["receipt"], args.backend, args.device):
                raise ValueError("Query and full-model identities differ")
            report["queryReceipt"] = worker.info
            report["coldQueryMs"] = worker.cold_ms
            for _ in range(3):
                worker.embed("text", prompt(profile["query"], "warm up"))
            for query in corpus["queries"]:
                began = time.perf_counter()
                template = profile["codeQuery" if query["modality"] == "code" else "query"]
                vector = worker.embed("text", prompt(template, query["q"]))
                elapsed = (time.perf_counter() - began) * 1000
                scores = sorted(((key, sum(a * b for a, b in zip(vector, values))) for key, values in vectors.items()),
                                key=lambda item: (-item[1], item[0]))
                best = scores[0][1]
                matches = [key for key, score in scores if score >= args.minimum_cosine
                           and score >= best - args.distance_from_best][:3]
                report["queries"].append({"id": query["id"], "modality": query["modality"],
                    "language": query["language"], "querySHA256": hashlib.sha256(query["q"].encode()).hexdigest(),
                    "expected": query["expected"], "ranked": [key for key, _ in scores[:10]], "matches": matches,
                    "topCosines": [score for _, score in scores[:10]], "milliseconds": elapsed})
        finally:
            worker.close()
        report["metrics"] = contract.metrics(report["queries"])
        report["warmLatency"] = contract.distribution([row["milliseconds"] for row in report["queries"]])
        report["completed"] = True
        contract.valid_report(report)
        return report
    except BaseException as error:
        report["error"] = str(error)
        raise
    finally:
        output.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n", encoding="utf-8")
        print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--backend", choices=contract.BACKENDS, required=True)
    parser.add_argument("--device", default="", help="Explicit stable device ID; NPU uses its verified NPU receipt")
    parser.add_argument("--machine-id", required=True, help="Recorded reference-machine label; keep the same label only on the same physical machine")
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New report directory; never an existing index")
    parser.add_argument("--prompt-profile", type=Path, help="Model-specific documented prompts; defaults to the deployed EmbeddingGemma 2 prompts")
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--minimum-cosine", type=float, default=.60)
    parser.add_argument("--distance-from-best", type=float, default=.08)
    args = parser.parse_args()
    for name in ("helper", "models", "corpus", "output"):
        setattr(args, name, getattr(args, name).resolve())
    if not args.helper.is_file() or not args.models.is_dir() or not args.corpus.is_file():
        parser.error("Helper, model directory and corpus must exist")
    if args.output.exists() or args.models == args.output or args.models in args.output.parents:
        parser.error("Use a new output directory outside the model directory")
    if args.trials < 5 or not math_is_finite_positive(args.timeout):
        parser.error("Use at least five trials and a positive finite timeout")
    if not args.machine_id.strip():
        parser.error("Provide a nonempty reference-machine label")
    if args.backend != "openvino-npu" and not args.device:
        parser.error("Select the explicit stable physical device ID")
    if not all(math_is_finite_positive(value, allow_zero=True) and value <= 1
               for value in (args.minimum_cosine, args.distance_from_best)):
        parser.error("Thresholds must be finite values from zero to one")
    collect(args)


def math_is_finite_positive(value, allow_zero=False):
    import math
    return math.isfinite(value) and (value >= 0 if allow_zero else value > 0)


if __name__ == "__main__":
    main()
