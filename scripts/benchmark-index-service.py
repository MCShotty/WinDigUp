#!/usr/bin/env python3
"""Paired full-service indexing measurements on a real selected accelerator."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import queue
import statistics
import subprocess
import threading
import time
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("digup_reference", Path(__file__).with_name("check-cuda-reference.py"))
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)
try:
    import psutil
except ImportError:
    psutil = None


def distribution(values):
    ordered = sorted(values)
    return None if not ordered else {
        "samples": len(values), "median": statistics.median(ordered),
        "p95": ordered[math.ceil(len(ordered) * .95) - 1], "values": values}


def identity(info):
    return {key: info.get(key) for key in (
        "backend", "device_id", "revision", "runtime", "dtype", "precision_profile", "build_identity", "dim")}


def validate_receipt(info, backend, gpu):
    if info.get("backend") != backend or info.get("execution_policy") != "accelerator-only":
        raise ValueError("The selected accelerator-only backend was not verified.")
    if backend == "openvino-npu":
        if not str(info.get("device", "")).startswith("NPU"):
            raise ValueError("The worker did not verify Intel NPU execution.")
    elif not gpu or info.get("device_id") != gpu:
        raise ValueError("The worker selected another physical GPU.")
    if info.get("dim") != 768 or not info.get("revision"):
        raise ValueError("The worker omitted the model revision or vector dimension.")
    if backend == "nvidia-cuda":
        protocol.receipt(info)
    return info


def workload_manifest(roots):
    # This deliberately warms file data before each run; cold-cache results need a separate protocol.
    digest = hashlib.sha256()
    count = size = 0
    for scope, root in enumerate(roots):
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(root).as_posix()
            content = hashlib.sha256()
            with path.open("rb") as stream:
                while block := stream.read(1024 * 1024):
                    content.update(block)
            stat = path.stat()
            digest.update(json.dumps([scope, relative, stat.st_size, content.hexdigest()],
                                     ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
            count += 1
            size += stat.st_size
    return {"sha256": digest.hexdigest(), "files": count, "bytes": size}


def completed_work(counts):
    keys = ("files", "searchable", "pending", "vectors", "unfinished",
            "code_files", "code_searchable", "code_pending", "code_vectors")
    return {key: counts.get(key, 0) for key in keys}


def trial(helper, folder, args, environment):
    folder.mkdir()
    command = [str(helper), "index-service", "--index", str(folder / "index"),
               "--backfill", "--linger", "0", "--include-datasets"]
    for root in args.folder:
        command.append(str(root))
    for root in args.code_root:
        command.extend(["--code-root", str(root)])
    command.extend(["--worker-log", str(folder / "worker.log")])
    started = time.perf_counter()
    times, snapshots, counts, verified = [], {}, {}, []
    events = queue.Queue(maxsize=1024)
    memory = {"peakProcessTreeRSSBytes": None, "samples": 0,
              "note": "psutil process-tree RSS samples include workers; shared pages may be counted more than once. Dedicated GPU memory is not measured."}
    peak = None
    next_memory_sample = 0.0
    with (folder / "stderr.log").open("w", encoding="utf-8") as errors:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                   text=True, encoding="utf-8", env=environment, bufsize=1)

        def read():
            try:
                with (folder / "events.jsonl").open("w", encoding="utf-8") as output:
                    for line in process.stdout:
                        output.write(line)
                        events.put((time.perf_counter(), line))
            finally:
                events.put(None)

        thread = threading.Thread(target=read, daemon=True)
        thread.start()
        try:
            while True:
                if time.perf_counter() - started > args.timeout:
                    raise TimeoutError("Index service timed out; no automatic retry was attempted.")
                try:
                    event = events.get(timeout=.1)
                except queue.Empty:
                    event = ()
                if psutil is not None and time.perf_counter() >= next_memory_sample:
                    next_memory_sample = time.perf_counter() + .1
                    try:
                        owner = psutil.Process(process.pid)
                        resident = sum(p.memory_info().rss for p in [owner] + owner.children(recursive=True))
                        peak = max(peak or 0, resident)
                        memory["samples"] += 1
                    except (psutil.Error, OSError):
                        pass
                if event is None:
                    break
                if not event:
                    continue
                timestamp, line = event
                value = json.loads(line)
                kind = value.get("event")
                if kind == "error":
                    raise RuntimeError(value.get("message", value.get("error", "Index service error")))
                if kind == "file" and value.get("state") in ("done", "partial"):
                    times.append((timestamp - started) * 1000)
                if kind == "index_pipeline":
                    snapshots[str(bool(value.get("code")))] = value["pipeline"]
                if kind == "inference_verified":
                    validate_receipt(value, args.backend, args.gpu)
                    verified.append(value)
                if kind == "idle":
                    counts = completed_work(value)
            process.wait(timeout=10)
            if process.returncode:
                raise RuntimeError(f"Index service exited with {process.returncode}; inspect stderr.log")
            if not counts or counts["pending"] or counts["code_pending"] or counts["unfinished"]:
                raise ValueError("The service did not complete all pending and long-file work.")
            if counts["vectors"] + counts["code_vectors"] == 0:
                raise ValueError("No neural vectors were indexed; this is not a throughput run.")
        finally:
            process.stdin.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process.stdout.close()
    memory["peakProcessTreeRSSBytes"] = peak
    elapsed = time.perf_counter() - started
    gaps = [b - a for a, b in zip(times, times[1:])]
    row = {"elapsedMs": elapsed * 1000, "searchableFilesPerSecond": len(times) / elapsed,
           "firstFileMs": times[0] if times else None, "completionGapsMs": distribution(gaps),
           "completedWork": counts, "pipeline": snapshots, "verifiedServiceReceipts": verified,
           "memory": memory, "peakDedicatedGPUMemoryBytes": None}
    (folder / "measurement.json").write_text(json.dumps(row, indent=2) + "\n", encoding="utf-8")
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--before-helper", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--backend", choices=["amd-vulkan", "nvidia-cuda", "vulkan", "openvino-npu"], required=True)
    parser.add_argument("--gpu", default="", help="Explicit stable ID from accelerator --list --json")
    parser.add_argument("--folder", type=Path, action="append", default=[])
    parser.add_argument("--code-root", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True, help="New disposable directory outside the input folders")
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--jobs", type=int, choices=[1, 2, 3], default=3)
    parser.add_argument("--timeout", type=int, default=3600)
    args = parser.parse_args()
    if args.trials < 5 or args.timeout <= 0 or not args.folder + args.code_root:
        parser.error("Use at least five paired trials, a positive timeout, and an input folder.")
    if args.backend == "openvino-npu" and args.jobs != 1:
        parser.error("Intel NPU must use --jobs 1.")
    if args.backend != "openvino-npu" and not args.gpu:
        parser.error("Select an explicit stable GPU ID.")
    args.folder = [root.resolve() for root in args.folder]
    args.code_root = [root.resolve() for root in args.code_root]
    roots = args.folder + args.code_root
    args.output = args.output.resolve()
    if args.output.exists() or any(args.output == root or root in args.output.parents for root in roots):
        parser.error("The output must be new and outside all input roots.")
    if not all(root.is_dir() for root in roots):
        parser.error("Every input root must be an existing directory.")
    helpers = {"before": args.before_helper.resolve(), "after": args.helper.resolve()}
    if not all(path.is_file() for path in helpers.values()) or not args.models.is_dir():
        parser.error("Both installed helpers and the model directory must exist.")
    args.output.mkdir(parents=True)
    environment = dict(os.environ, DIGUP_ACCELERATOR=args.backend, DIGUP_MODELS=str(args.models.resolve()),
                       DIGUP_GPU=args.gpu, DIGUP_GPU_JOBS=str(args.jobs), DIGUP_INFERENCE_PRIORITY="background")
    report = {"schemaVersion": 1, "passed": False, "machine": platform.platform(),
              "processor": platform.processor(), "backend": args.backend, "deviceID": args.gpu,
              "jobs": args.jobs, "trials": args.trials, "cacheState": "Fresh disposable index; source data explicitly warmed; cold model process each trial.",
              "scope": "Actual IndexService: discovery, metadata, preparation, inference, publication, cleanup and shutdown.",
              "notMeasured": ["GPU utilization", "dedicated GPU memory", "foreground search latency"],
              "configurations": {name: {"helperSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "runs": []}
                                 for name, path in helpers.items()}}
    keys = ["DIGUP_GPU", "DIGUP_GPU_JOBS", "DIGUP_INFERENCE_PRIORITY"]
    saved = {key: os.environ.get(key) for key in keys}
    try:
        os.environ.update({key: environment[key] for key in keys})
        receipts = []
        for name, helper in helpers.items():
            probe = args.output / (name + "-probe")
            probe.mkdir()
            options = SimpleNamespace(helper=helper, models=args.models, output=probe, timeout=min(args.timeout, 300))
            worker = protocol.Worker(options, False, probe / "worker.log", backend=args.backend,
                                     validate=lambda info: validate_receipt(info, args.backend, args.gpu))
            try:
                worker.embed("text", [protocol.document("Benchmark verification", "A train itinerary for Tokyo.")])
                report["configurations"][name]["receipt"] = worker.info
                receipts.append(identity(worker.info))
            finally:
                worker.close()
        if receipts[0] != receipts[1]:
            raise ValueError("Model/runtime/device identity differs; isolate the scheduling change before comparing.")
        for number in range(args.trials):
            for name in (["before", "after"] if number % 2 == 0 else ["after", "before"]):
                manifest = workload_manifest(roots)
                if "workload" in report and report["workload"] != manifest:
                    raise ValueError("The input files changed during the paired measurements.")
                report["workload"] = manifest
                row = trial(helpers[name], args.output / f"{name}-{number + 1}", args, environment)
                report["configurations"][name]["runs"].append(row)
        before = report["configurations"]["before"]["runs"]
        after = report["configurations"]["after"]["runs"]
        expected = before[0]["completedWork"]
        if any(row["completedWork"] != expected for row in before + after):
            raise ValueError("Trials indexed different amounts of work; no speedup can be reported.")
        report["elapsedMs"] = {name: distribution([row["elapsedMs"] for row in item["runs"]])
                               for name, item in report["configurations"].items()}
        report["passed"] = True
    except BaseException as error:
        report["error"] = str(error)
        raise
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        destination = args.output / "index-service-comparison.json"
        destination.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(destination)


if __name__ == "__main__":
    main()
