#!/usr/bin/env python3
"""Exercise the real Swift service with explicitly synthetic unit vectors, without neural inference."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

class Service:
    def __init__(self, helper, root, env):
        self.log = (root / "service.log").open("w", encoding="utf-8")
        self.process = subprocess.Popen([str(helper), "search-service", "--index", str(root / "index")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, encoding="utf-8", env=env)
        self.counter = 0
    def request(self, op, **fields):
        self.counter += 1
        self.process.stdin.write(json.dumps({"op": op, "id": self.counter, **fields}) + "\n")
        self.process.stdin.flush()
        for line in self.process.stdout:
            reply = json.loads(line)
            if reply.get("id") == self.counter:
                if reply.get("ok") is False:
                    raise AssertionError(reply.get("error", reply))
                return reply
        self.log.flush()
        raise AssertionError((self.log.name, self.process.poll()))
    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="digup-app-protocol-") as folder:
        root = Path(folder)
        models = root / "synthetic-bundle"
        models.mkdir()
        (models / "manifest.json").write_text("{}", encoding="utf-8")
        worker_log = root / "worker-requests.jsonl"
        env = os.environ.copy()
        env.update(DIGUP_ACCELERATOR="openvino-npu", DIGUP_OPENVINO_PYTHON=sys.executable,
                   DIGUP_OPENVINO_MODELS=str(models), DIGUP_APP_TEST_LOG=str(worker_log),
                   DIGUP_OPENVINO_WORKER=str(Path(__file__).resolve().parents[1] / "tests/applications/synthetic-worker.py"))
        def document(identifier, text):
            return {"id": "app:" + identifier * 64, "name": text, "text": text, "hash": hashlib.sha256(text.encode()).hexdigest()}
        documents = [document("1", "Photo editor for portraits"), document("2", "Browser for websites")]
        service = Service(args.helper.resolve(), root, env)
        try:
            service.request("apps_catalog", revision="one", documents=documents)
            state = service.request("apps_index_step")
            assert state["embedded"] == 0 and not worker_log.exists(), "Background step woke the encoder"
            state = service.request("apps_search", q="retouch portrait", revision="one")
            assert state["embedded"] == 0 and not state["hits"], state
            assert service.request("apps_index_step")["embedded"] == 1
            assert service.request("apps_index_step")["embedded"] == 2
            first = service.request("apps_search", q="retouch portrait", revision="one")
            second = service.request("apps_search", q="retouch portrait", revision="one")
            assert first["hits"] == second["hits"] and first["hits"][0]["id"] == documents[0]["id"]
            requests = [json.loads(line) for line in worker_log.read_text().splitlines()]
            queries = [r for r in requests if r["inputs"][0].startswith("task: search result")]
            assert len(queries) == 1, "Application searches did not reuse the query cache"
            documents[0] = document("1", "Photo editor, portraits and color correction")
            state = service.request("apps_catalog", revision="two", documents=documents)
            assert state["embedded"] == 1
            assert service.request("apps_index_step")["embedded"] == 2
        finally:
            service.close()
        env["DIGUP_APP_TEST_RUNTIME"] = "synthetic-unit-v2"
        service = Service(args.helper.resolve(), root, env)
        try:
            state = service.request("apps_search", q="retouch portrait", revision="two")
            assert state["embedded"] == 0 and not state["hits"], "Changed runtime reused incompatible vectors"
        finally:
            service.close()
        env["DIGUP_APP_TEST_DEVICE"] = "CPU"
        service = Service(args.helper.resolve(), root, env)
        try:
            state = service.request("apps_search", q="retouch portrait", revision="two")
            assert state["state"] == "unavailable" and not state["hits"], "CPU worker proof was accepted"
        finally:
            service.close()
    print("PASS: real application-service protocol; bounded background preparation, vector persistence, query reuse, runtime isolation and CPU-proof rejection (synthetic unit vectors)")

if __name__ == "__main__":
    main()
