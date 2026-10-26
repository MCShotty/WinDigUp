#!/usr/bin/env python3
"""Copy the exact CUDA DLL dependency closure into the installed helper directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def dependencies(path):
    result = subprocess.run(["dumpbin", "/NOLOGO", "/DEPENDENTS", str(path)], check=True, capture_output=True, text=True, errors="replace")
    return {line.strip() for line in result.stdout.splitlines() if re.fullmatch(r"\s*[\w.+-]+\.dll\s*", line, re.I)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cuda", type=Path, default=Path("Vendor/cuda"))
    p.add_argument("--helper", type=Path, default=Path("shell/src-tauri/helper"))
    a = p.parse_args()
    record = json.loads((a.cuda / "redistribution.json").read_text())
    if record["version"] != "12.9.1" or record["platform"] != "windows-x86_64":
        raise RuntimeError("Expected pinned Windows CUDA 12.9.1 redistribution")
    available = {path.name.lower(): path for path in (a.cuda / "bin").glob("*.dll")}
    installed = {path.name.lower(): path for path in a.helper.glob("*.dll")}
    system = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32"
    pending = [a.helper / "ggml-cuda.dll"]
    checked, copied = set(), {}
    while pending:
        path = pending.pop()
        if path.name.lower() in checked:
            continue
        checked.add(path.name.lower())
        for dependency in dependencies(path):
            name = dependency.lower()
            if name == "nvcuda.dll":
                continue  # NVIDIA's driver owns this; it is never redistributed by DigUp.
            if name in installed:
                pending.append(installed[name])
            elif name in available:
                source = available[name]
                target = a.helper / source.name
                shutil.copy2(source, target)
                installed[name] = target
                with target.open("rb") as stream:
                    copied[source.name] = hashlib.file_digest(stream, "sha256").hexdigest()
                pending.append(target)
            elif name.startswith(("api-ms-win-", "ext-ms-win-")) or (system / dependency).is_file():
                continue
            else:
                raise RuntimeError(f"Unresolved dependency {dependency} of {path.name}; refusing an incomplete installer")
    required = {"cudart64_12.dll", "cublas64_12.dll", "cublaslt64_12.dll"}
    if not required.issubset({name.lower() for name in copied}):
        raise RuntimeError("The compiled CUDA backend did not resolve the expected CUDA runtime dependencies")
    if (a.helper / "nvcuda.dll").exists():
        raise RuntimeError("The NVIDIA driver DLL must not be bundled")
    record.update({"schemaVersion": 1, "files": copied, "checkedModules": sorted(checked)})
    (a.helper / "cuda-runtime.json").write_text(json.dumps(record, indent=2) + "\n")
    print("Packaged CUDA dependencies: " + ", ".join(sorted(copied)))


if __name__ == "__main__":
    main()
