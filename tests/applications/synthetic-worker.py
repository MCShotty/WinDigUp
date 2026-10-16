"""Synthetic unit vectors for protocol tests. No neural model or OpenVINO session is loaded."""
import base64
import json
import os
from pathlib import Path
import struct
import sys
import time

for stream in (sys.stdin, sys.stdout, sys.stderr):
    stream.reconfigure(encoding="utf-8")

def reply(value):
    print(json.dumps(value), flush=True)

reply({"ready": True, "info": {"model": "unit-test/synthetic-vectors", "revision": "123456789abcdef0123456789abcdef0123456789",
      "runtime": os.environ.get("DIGUP_APP_TEST_RUNTIME", "synthetic-unit-v1"), "dtype": "synthetic-f32", "dim": 768,
      "text_only": True, "device": os.environ.get("DIGUP_APP_TEST_DEVICE", "NPU"), "execution_policy": "accelerator-only"}})
for line in sys.stdin:
    request = json.loads(line)
    if request["op"] == "quit":
        break
    with Path(os.environ["DIGUP_APP_TEST_LOG"]).open("a", encoding="utf-8") as log:
        log.write(json.dumps(request) + "\n")
    time.sleep(float(os.environ.get("DIGUP_APP_TEST_DELAY", "0")))
    crash_on=os.environ.get("DIGUP_APP_TEST_CRASH_ON")
    if crash_on and any(crash_on in text for text in request.get("inputs",[])):
        sys.exit(43)
    if os.environ.get("DIGUP_APP_TEST_FAILURE") == "1":
        reply({"id": request["id"], "ok": False, "error": "synthetic inference failure"})
        continue
    vectors = []
    for text in request["inputs"]:
        axis = 0 if "photo" in text.lower() or "portrait" in text.lower() else 1
        vector = [0.0] * 768
        vector[axis] = 1.0
        vectors.extend(vector)
    reply({"id": request["id"], "ok": True, "dim": 768,
           "vectors": base64.b64encode(struct.pack("<" + "f" * len(vectors), *vectors)).decode("ascii")})
