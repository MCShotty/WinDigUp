#!/usr/bin/env python3
"""Bounded callers use this metadata-only probe; no model is compiled or executed."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))


def inspect(backend, models=""):
    result = {"schemaVersion": 1, "probeOnly": True, "devices": [], "backends": [],
              "runtimeReady": False, "bundleReady": False, "modelMessage": "Choose or prepare an exported OpenVINO model bundle."}
    try:
        import openvino as ov
        from devices import device_inventory
        result["devices"] = device_inventory(ov.Core(), backend)
        result["runtimeReady"] = True
        result["runtimeVersion"] = ov.__version__
        available = any(d["available"] for d in result["devices"])
        result["backends"] = [{"backend": backend, "state": "available" if available else "unavailable",
            "message": "" if available else "The Intel driver exposes no eligible device to OpenVINO. No fallback was attempted."}]
        if models:
            try:
                from npu_runtime import validate_bundle
                manifest = validate_bundle(Path(models))
                result.update(bundleReady=True, bundleID=manifest["bundle_id"], revision=manifest["revision"],
                              modelMessage="Exported model verified. Hardware execution is checked after restart.")
            except Exception as error:
                result["modelMessage"] = str(error)[:1500]
    except Exception as error:
        result["backends"] = [{"backend": backend, "state": "unavailable",
                              "message": "OpenVINO runtime is unavailable: " + str(error)[:1500]}]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=("openvino-npu", "openvino-gpu"), required=True)
    parser.add_argument("--models", default="")
    parser.add_argument("--output")
    args = parser.parse_args()
    result = json.dumps(inspect(args.backend, args.models), ensure_ascii=True)
    if args.output:
        Path(args.output).write_text(result, encoding="utf-8")
    else:
        print(result, flush=True)
