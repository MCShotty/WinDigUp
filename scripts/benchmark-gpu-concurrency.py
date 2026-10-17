#!/usr/bin/env python3
"""Compare real CUDA/Vulkan worker throughput. Never substitutes for retained-reference acceptance."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import statistics
import threading
import time

protocol_path = Path(__file__).with_name("check-cuda-reference.py")
spec = importlib.util.spec_from_file_location("digup_reference", protocol_path)
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)


def distribution(values):
    ordered = sorted(values)
    return {"samples": len(values), "medianMs": statistics.median(values),
            "p95Ms": ordered[math.ceil(len(values) * .95) - 1], "milliseconds": values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--gpu", required=True, help="Explicit stable device ID from accelerator --list --json")
    parser.add_argument("--backend", required=True, choices=["amd-vulkan", "nvidia-cuda", "vulkan"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=["query512", "full2048"], default="full2048")
    parser.add_argument("--inputs", type=Path, help="JSON array of already-prompted text inputs, kept locally")
    parser.add_argument("--samples", type=int, default=120)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if not 100 <= args.samples <= 10000 or not args.gpu.strip() or args.timeout <= 0:
        parser.error("Use 100..10000 samples, a stable device ID, and a positive timeout.")
    if args.inputs:
        inputs = json.loads(args.inputs.read_text(encoding="utf-8"))
        if not isinstance(inputs, list) or len(inputs) < 100 or not all(isinstance(x, str) and x for x in inputs):
            parser.error("The input file must contain at least 100 nonempty text strings.")
        inputs = inputs[:10000]
    else:
        prompts = ["find the train itinerary to Tokyo", "edit and crop a family photograph",
                   "متى تغلق المكتبة", "ইলিশ মাছ রান্না", "查找上个月的预算", "réparer le document"]
        inputs = [protocol.query(prompts[index % len(prompts)] + " " + str(index)) for index in range(args.samples)]
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "passed": False, "scope": "Real worker IPC and text encoding; excludes UI, disk extraction and commits.",
              "profile": args.profile, "backend": args.backend, "deviceID": args.gpu,
              "machine": platform.platform(), "processor": platform.processor(),
              "inputCount": len(inputs), "inputSHA256": hashlib.sha256(json.dumps(inputs, ensure_ascii=False).encode()).hexdigest(),
              "peakDedicatedGPUMemoryBytes": None, "configurations": [],
              "acceptanceNote": "Cosines compare with the first single-worker run, not the retained reference corpus. Run physical reference/media acceptance separately.",
              "memoryNote": "Capture dedicated GPU memory with a supported vendor tool; this harness does not infer it."}
    reference = {}
    identities = []
    saved = {key: os.environ.get(key) for key in ["DIGUP_GPU", "DIGUP_GPU_JOBS", "DIGUP_INFERENCE_PRIORITY"]}
    os.environ["DIGUP_GPU"] = args.gpu
    os.environ["DIGUP_INFERENCE_PRIORITY"] = "background"

    def validate(info):
        if info.get("backend") != args.backend or info.get("execution_policy") != "accelerator-only" or not info.get("device_id"):
            raise ValueError("The worker did not verify the selected accelerator-only device.")
        if info["device_id"] != args.gpu:
            raise ValueError("The worker selected a different physical GPU.")
        if info.get("dim") != 768 or not info.get("revision"):
            raise ValueError("Missing model revision or vector dimension.")
        if args.backend == "nvidia-cuda":
            protocol.receipt(info)
        identity = tuple(info.get(key) for key in ["backend", "device_id", "revision", "runtime", "dtype", "precision_profile", "build_identity"])
        if identities and identity != identities[0]:
            raise ValueError("Worker runtime or physical device changed during the benchmark.")
        identities.append(identity)
        return info

    try:
        for count in [1, 2, 3]:
            for batch_size in [1, 8]:
                os.environ["DIGUP_GPU_JOBS"] = str(count)
                workers = []
                row = {"workers": count, "batchSize": batch_size, "passed": False}
                report["configurations"].append(row)
                try:
                    for index in range(count):
                        workers.append(protocol.Worker(args, args.profile == "query512",
                            args.output / f"workers-{count}-batch-{batch_size}-{index}.log",
                            backend=args.backend, validate=validate))
                    row["receipts"] = [worker.info for worker in workers]
                    row["coldWorkerSeconds"] = [worker.cold_seconds for worker in workers]
                    for worker in workers:
                        worker.embed("text", [inputs[0]])
                    chunks = [list(range(start, min(len(inputs), start + batch_size))) for start in range(0, len(inputs), batch_size)]
                    barrier = threading.Barrier(count)

                    def lane(index):
                        latencies, made = [], {}
                        barrier.wait(timeout=args.timeout)
                        for indices in chunks[index::count]:
                            began = time.perf_counter()
                            vectors = workers[index].embed("text", [inputs[item] for item in indices])
                            latencies.append((time.perf_counter() - began) * 1000)
                            made.update(zip(indices, vectors))
                        return latencies, made

                    began = time.perf_counter()
                    with ThreadPoolExecutor(max_workers=count) as pool:
                        futures = [pool.submit(lane, index) for index in range(count)]
                        lanes = [future.result() for future in futures]
                    elapsed = time.perf_counter() - began
                    latencies = [latency for values, _ in lanes for latency in values]
                    vectors = {index: vector for _, values in lanes for index, vector in values.items()}
                    if len(vectors) != len(inputs):
                        raise ValueError("Not every submitted input returned a validated vector.")
                    if not reference:
                        reference = vectors
                    agreement = min(protocol.cosine(vector, reference[index]) for index, vector in vectors.items())
                    row.update(elapsedSeconds=elapsed, inputsPerSecond=len(inputs) / elapsed,
                               latency=distribution(latencies), minimumBaselineCosine=agreement)
                    if agreement < .999:
                        raise ValueError("Concurrent output agreement fell below 0.999; retain this report and investigate.")
                    row["passed"] = True
                finally:
                    for worker in workers:
                        worker.close()
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
        path = args.output / "gpu-concurrency.json"
        path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(path)


if __name__ == "__main__":
    main()
