#!/usr/bin/env python3
"""Real service scheduling with explicitly synthetic vectors; never a hardware/model benchmark."""
import argparse
import json
import os
from pathlib import Path
import platform
import queue
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="digup-search-") as directory:
        root = Path(directory)
        bundle = root / "bundle"
        bundle.mkdir()
        (bundle / "manifest.json").write_text("{}")
        requests = root / "requests.jsonl"
        env = os.environ.copy()
        env.update(DIGUP_ACCELERATOR="openvino-npu", DIGUP_OPENVINO_PYTHON=sys.executable,
                   DIGUP_OPENVINO_MODELS=str(bundle), DIGUP_APP_TEST_LOG=str(requests),
                   DIGUP_APP_TEST_DELAY="0.75",
                   DIGUP_OPENVINO_WORKER=str(Path(__file__).resolve().parents[1] / "tests/applications/synthetic-worker.py"))
        replies = queue.Queue()
        with (root / "stderr.log").open("w") as log:
            service = subprocess.Popen([str(args.helper.resolve()), "search-service", "--index", str(root / "index")],
                                       env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                       text=True, encoding="utf-8")
            def read():
                for line in service.stdout:
                    replies.put((time.perf_counter(), json.loads(line)))
            threading.Thread(target=read, daemon=True).start()
            def send(identifier, **request):
                service.stdin.write(json.dumps(dict(id=identifier, **request)) + "\n")
                service.stdin.flush()
            def wait(identifier, timeout=20):
                deadline = time.perf_counter() + timeout
                while time.perf_counter() < deadline:
                    at, reply = replies.get(timeout=max(.01, deadline - time.perf_counter()))
                    received[reply.get("id")] = (at, reply)
                    if identifier in received:
                        return received[identifier]
                raise AssertionError(f"No reply for {identifier}")
            received = {}
            try:
                send(1, op="prewarm")
                wait(1)
                send(2, op="embed_ahead", q="blocked query", session="panel", generation=1)
                deadline = time.perf_counter() + 10
                while not requests.exists() and time.perf_counter() < deadline:
                    time.sleep(.005)
                assert requests.exists(), "Synthetic encoder did not start"
                start = time.perf_counter()
                send(3, op="search", q="keyword", meaning=False, session="window", generation=1)
                for generation in range(2, 14):
                    send(10 + generation, op="embed_ahead", q=f"obsolete {generation}",
                         session="panel", generation=generation)
                at, lexical = wait(3)
                lexical_ms = (at - start) * 1000
                wait(23)
                while len([k for k in received if isinstance(k, int) and k >= 12]) < 12:
                    at, reply = replies.get(timeout=20)
                    received[reply.get("id")] = (at, reply)
                operations = [json.loads(line) for line in requests.read_text().splitlines()]
                report = dict(schemaVersion=1, synthetic=True, physicalAcceleratorValidated=False,
                              machine=platform.platform(), helper=str(args.helper.resolve()),
                              workload="750 ms synthetic encoder call, concurrent keyword search, 12 newer generations",
                              lexicalWhileEncodingMs=round(lexical_ms, 2), encoderCalls=len(operations),
                              superseded=sum(r.get("status") == "superseded" for _, r in received.values()),
                              keywordReply=lexical)
                print(json.dumps(report, indent=2))
                if args.output:
                    args.output.write_text(json.dumps(report, indent=2) + "\n")
                if not args.baseline:
                    assert lexical_ms < 250, "Keyword search waited for inference"
                    assert len(operations) <= 3, "Obsolete embedding requests accumulated"
                    assert report["superseded"] >= 10, "Superseded requests were not completed"
            finally:
                service.terminate()
                try:
                    service.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    service.kill()
                    service.wait()


if __name__ == "__main__":
    main()
