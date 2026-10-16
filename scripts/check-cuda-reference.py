#!/usr/bin/env python3
"""Physical CUDA acceptance against the retained model corpus. Requires installed helper and real model weights."""
import argparse
import base64
import json
import hashlib
import math
import os
from pathlib import Path
import queue
import statistics
import struct
import subprocess
import threading
import time

REVISION = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"
AGREEMENT = 0.999
MINIMUM_APP_COSINE = 0.60  # ApplicationStore ranking version 1; never calibrated by this script.


def checked_vector(values):
    if len(values) != 768 or not all(math.isfinite(x) for x in values):
        raise ValueError("Expected 768 finite accelerator values")
    if abs(sum(x*x for x in values)-1) >= 0.005:
        raise ValueError("Accelerator output is not normalized")
    return values


def cosine(a, b):
    if len(a) != len(b) or not a or not all(math.isfinite(x) for x in a+b):
        raise ValueError("Invalid reference comparison")
    denominator = math.sqrt(sum(x*x for x in a) * sum(x*x for x in b))
    if not denominator:
        raise ValueError("Zero reference vector")
    return sum(x*y for x, y in zip(a, b)) / denominator


def receipt(info):
    if (info.get("backend") != "nvidia-cuda" or info.get("execution_policy") != "accelerator-only"
        or info.get("precision_profile") != "cuda-fp32-v1" or not info.get("build_identity")
        or not info.get("device_id") or info.get("revision") != REVISION):
        raise ValueError("The worker did not report the required real CUDA runtime/model identity")
    return info


class Worker:
    def __init__(self, args, text_only, log):
        env = dict(os.environ, DIGUP_ACCELERATOR="nvidia-cuda", DIGUP_MODELS=str(args.models.resolve()))
        command = [str(args.helper.resolve()), "worker", "--index", str(args.output.resolve() / "worker-index")]
        if text_only:
            command += ["--text-only"]
        self.log = log.open("w", encoding="utf-8")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                        text=True, encoding="utf-8", env=env)
        self.lines = queue.Queue()
        self.counter = 0
        self.timeout = args.timeout
        threading.Thread(target=self.read, daemon=True).start()
        started = time.monotonic()
        try:
            first = self.line()
            if not first.get("ready"):
                raise RuntimeError(first.get("error", "CUDA worker did not become ready"))
            self.info = receipt(first["info"])
            self.cold_seconds = time.monotonic()-started
        except BaseException:
            self.close()
            raise

    def read(self):
        try:
            for line in self.process.stdout:
                self.lines.put(line)
        finally:
            self.lines.put(None)

    def line(self):
        line = self.lines.get(timeout=self.timeout)
        if line is None:
            raise RuntimeError("CUDA worker exited; inspect its log")
        return json.loads(line)

    def embed(self, operation, inputs, **extra):
        self.counter += 1
        request = dict(id=self.counter, op=operation, inputs=inputs, **extra)
        self.process.stdin.write(json.dumps(request, ensure_ascii=False)+"\n")
        self.process.stdin.flush()
        response = self.line()
        if response.get("id") != self.counter or not response.get("ok"):
            raise RuntimeError(response.get("error", "Unexpected CUDA response"))
        if any(response.get("errors", [])):
            raise RuntimeError(str(response["errors"]))
        if response.get("dim") != 768 or response.get("count") != len(inputs):
            raise ValueError("Unexpected vector shape")
        raw = base64.b64decode(response["vectors"], validate=True)
        if len(raw) != len(inputs)*768*4:
            raise ValueError("Truncated vector payload")
        values = struct.unpack("<"+"f"*(len(inputs)*768), raw)
        return [checked_vector(list(values[i*768:(i+1)*768])) for i in range(len(inputs))]

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        self.process.stdout.close(); self.process.stdin.close(); self.log.close()


def query(text):
    return "task: search result | query: "+text


def document(title, text):
    return f"title: {title or 'none'} | text: {text}"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--helper", type=Path, required=True)
    p.add_argument("--models", type=Path, required=True)
    p.add_argument("--reference", type=Path, default=Path(__file__).resolve().parents[1]/"Tests/LlamaRuntimeTests/Reference")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--timeout", type=int, default=180)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "physicalCUDA": False, "referenceCosines": {}, "imageBudgets": [],
              "rankingVersion": 1, "minimumAppCosine": MINIMUM_APP_COSINE,
              "peakGPUMemory": None, "memoryNote": "Capture peak dedicated GPU memory separately; unsupported counters must remain unknown."}
    output = args.output/"cuda-reference.json"
    try:
        expected = {
            "embeddinggemma-2-Q8_0.gguf":"2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
            "mmproj-embeddinggemma-2-Q8_0.gguf":"c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"}
        report["modelHashes"] = {}
        for name, checksum in expected.items():
            with (args.models/name).open("rb") as stream:
                actual = hashlib.file_digest(stream,"sha256").hexdigest()
            report["modelHashes"][name] = actual
            if actual != checksum: raise ValueError("Model checksum mismatch: "+name)
        report["referenceSHA256"] = hashlib.sha256((args.reference/"vectors.json").read_bytes()).hexdigest()
        reference = json.loads((args.reference/"vectors.json").read_text())["vectors"]
        long_text = " ".join(f"Note {i}: the review moved to room {i%7+2} because the projector in the main hall failed again, "
                             "and the team agreed to send the slides the night before." for i in range(1,61))
        texts = {"query": query("payment declined error"), "query-bn": query("ইলিশ মাছ রান্না"), "query-ar": query("متى تغلق المكتبة"),
                 "document": document("Tokyo itinerary", "Flight to Tokyo Haneda on November 3. Then the train to Kamakura to see the Great Buddha, and back for dinner in Shibuya."),
                 "document-long": document(None,long_text)}
        worker = Worker(args, False, args.output/"full-worker.log")
        try:
            report.update(physicalCUDA=True, runtime=worker.info, coldFullSeconds=worker.cold_seconds)
            made = {name: worker.embed("text", [text])[0] for name,text in texts.items()}
            for name, file, budget in [("screen-280","screen.png",280),("photo-140","photo.jpg",140),("frame-70","photo.jpg",70)]:
                made[name] = worker.embed("image", [str((args.reference/file).resolve())], budget=budget)[0]
            made["speech"] = worker.embed("audio", [str((args.reference/"speech.wav").resolve())])[0]
            if set(made) != set(reference):
                raise ValueError("Reference corpus keys differ")
            report["referenceCosines"] = {name: cosine(vector,reference[name]) for name,vector in made.items()}
            if min(report["referenceCosines"].values()) < AGREEMENT:
                raise ValueError("CUDA reference agreement fell below 0.999")
            for budget in [70,140,280,560,1120]:
                worker.embed("image", [str((args.reference/"photo.jpg").resolve())], budget=budget)
                report["imageBudgets"].append(budget)
        finally:
            worker.close()
        worker = Worker(args, True, args.output/"query-worker.log")
        try:
            receipt(worker.info)
            report["queryRuntime"] = worker.info
            report["queryReferenceCosines"] = {name: cosine(worker.embed("text",[texts[name]])[0],reference[name])
                                               for name in ["query","query-bn","query-ar"]}
            if min(report["queryReferenceCosines"].values()) < AGREEMENT:
                raise ValueError("512-token query reference agreement fell below 0.999")
            for _ in range(3): worker.embed("text", [texts["query"]])
            latencies = []
            for i in range(30):
                started = time.perf_counter()
                worker.embed("text", [query(f"payment declined error {i}")])
                latencies.append((time.perf_counter()-started)*1000)
            report["queryLatency"] = {"scope":"IPC plus real encoding, excludes UI rendering", "samples":len(latencies),
                "milliseconds":latencies, "median":statistics.median(latencies),"p95":sorted(latencies)[math.ceil(.95*len(latencies))-1]}
            catalog = {
                "photoshop":("Adobe Photoshop","Edit photos, retouch portraits and create digital artwork."),
                "vscode":("Visual Studio Code","Write and debug software and Python source code."),
                "vlc":("VLC media player","Play videos, movies, music and audio recordings."),
                "calc":("LibreOffice Calc","Edit spreadsheets, budgets, tables and formulas."),
                "7zip":("7-Zip","Compress files and extract ZIP and 7z archives."),
                "audacity":("Audacity","Record and edit audio, trim sound and remove noise."),
            }
            app_vectors = {key:worker.embed("text",[document(name,description)])[0] for key,(name,description) in catalog.items()}
            purposes=[("edit photos and retouch portraits","photoshop"),("write and debug Python code","vscode"),
                      ("watch a movie","vlc"),("work on a budget spreadsheet","calc"),("extract a ZIP archive","7zip"),
                      ("remove noise from an audio recording","audacity"),
                      ("historical rainfall measurements on Mars",None),("the cause of an ancient treaty collapse",None)]
            rows=[]
            for text,expected in purposes:
                vector=worker.embed("text",[query(text)])[0]
                scores=sorted(((key,cosine(vector,value)) for key,value in app_vectors.items()),key=lambda x:x[1],reverse=True)
                matches=[key for key,score in scores if score>=MINIMUM_APP_COSINE]
                passed=expected in matches[:3] if expected else not matches
                rows.append({"query":text,"expected":expected,"scores":scores,"passed":passed})
            report["purposeQueries"] = rows
            if not all(row["passed"] for row in rows):
                raise ValueError("Purpose relevance gate failed; retain the measurements and investigate")
        finally:
            worker.close()
        report["passed"] = True
    except BaseException as error:
        report["error"] = str(error)
        raise
    finally:
        output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
        print(output)


if __name__ == "__main__":
    main()
