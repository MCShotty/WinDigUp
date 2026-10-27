#!/usr/bin/env python3
"""DigUp JSON-lines embedding worker; exclusive Intel NPU or integrated GPU."""
import argparse
import base64
import json
from pathlib import Path
import sys
import time

# -I intentionally excludes the script directory. Add only our bundled code, never the current directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from npu_runtime import NPURuntime


def reply(value):
    print(json.dumps(value, ensure_ascii=True, allow_nan=False), flush=True)


def main():
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True)
    parser.add_argument("--text-only", action="store_true")
    parser.add_argument("--backend", choices=("openvino-npu", "openvino-gpu"), default="openvino-npu")
    parser.add_argument("--device", default="")
    parser.add_argument("--cache")
    args = parser.parse_args()
    started = time.monotonic()
    try:
        runtime = NPURuntime(args.models, args.text_only, backend=args.backend, device=args.device, cache=args.cache)
        info = {"model": runtime.manifest["model"], "revision": runtime.manifest["revision"],
                "runtime": "openvino-npu-v1-" + runtime.manifest["bundle_id"], "dtype": "fp32-ir-npu-verified",
                "dim": 768, "text_only": args.text_only, "load_seconds": time.monotonic() - started,
                "device": "NPU", "execution_policy": "accelerator-only"}
        import hashlib
        import openvino as ov
        info.update({"backend": args.backend, "device": runtime.selected["id"],
                     "device_id": runtime.selected["stableID"], "device_name": runtime.selected["name"],
                     "driver_description": runtime.selected["driverDescription"], "runtime_description": ov.__version__})
        if args.backend == "openvino-gpu":
            import importlib.metadata
            versions = {name: importlib.metadata.version(name) for name in
                        ("openvino", "transformers", "tokenizers", "numpy", "Pillow", "soundfile")}
            identity = hashlib.sha256(json.dumps(versions, sort_keys=True).encode() + b"".join((Path(__file__).parent / name).read_bytes()
                for name in ("devices.py", "npu_runtime.py", "digup_openvino.py"))).hexdigest()
            info.update({"runtime": "openvino-gpu-v1-" + ov.__version__ + "-" + runtime.manifest["bundle_id"],
                         "dtype": "fp32-ir-gpu-f32-verified", "precision_profile": "openvino-gpu-f32-v1",
                         "build_identity": identity})
        reply({"ready": True, "info": info})
    except Exception as error:
        reply({"ready": False, "error": str(error)[:1500]})
        return 1
    import numpy as np
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            op, inputs = request.get("op"), request.get("inputs", [])
            if op == "quit":
                reply({"id": request.get("id"), "ok": True})
                return 0
            if op == "info":
                reply({"id": request.get("id"), "ok": True, "info": info})
                continue
            errors = [None] * len(inputs)
            if op == "text":
                vectors = runtime.texts(inputs)
            elif op in ("image", "audio"):
                vectors = []
                for i, path in enumerate(inputs):
                    try:
                        vectors.append(runtime.image(path, request.get("budget", 280)) if op == "image" else runtime.audio(path))
                    except Exception as error:
                        vectors.append(np.zeros(768, dtype=np.float32))
                        errors[i] = str(error)[:500]
            else:
                raise ValueError(f"Unknown operation: {op!r}")
            reply({"id": request.get("id"), "ok": True, "dim": 768, "count": len(inputs), "errors": errors,
                   "vectors": base64.b64encode(np.asarray(vectors, dtype="<f4").tobytes()).decode("ascii")})
        except Exception as error:
            reply({"id": request.get("id"), "ok": False, "error": str(error)[:1500]})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
