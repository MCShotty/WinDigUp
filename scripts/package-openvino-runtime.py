#!/usr/bin/env python3
"""Build a relocatable, app-local Python/OpenVINO environment on Windows."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PYTHON = (3, 12, 10)
ROOT = Path(__file__).resolve().parents[1]
REQUIREMENTS = ROOT / "worker/openvino/requirements.txt"


def run(*args):
    subprocess.run([str(value) for value in args], check=True)


def build(output):
    if sys.platform != "win32" or sys.version_info[:3] != PYTHON:
        raise RuntimeError("Build the Intel runtime with the pinned Windows x64 Python 3.12.10.")
    identity = hashlib.sha256(Path(__file__).read_bytes() + REQUIREMENTS.read_bytes() + sys.version.encode()).hexdigest()
    receipt = output / "runtime-manifest.json"
    if receipt.is_file() and json.loads(receipt.read_text())["buildIdentity"] == identity:
        run(output / "python/python.exe", "-I", "-c", "import openvino,torch,transformers,numpy,PIL,soundfile; assert torch.version.cuda is None")
        print("Reusing the matching app-local Intel runtime.")
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="digup-intel-") as temporary:
        temporary = Path(temporary)
        env = temporary / "build"
        run(sys.executable, "-m", "venv", env)
        python = env / "Scripts/python.exe"
        run(python, "-m", "pip", "install", "--disable-pip-version-check",
            "torch==2.14.1", "torchvision==0.29.1", "--index-url", "https://download.pytorch.org/whl/cpu")
        run(python, "-m", "pip", "install", "--disable-pip-version-check", "-r", REQUIREMENTS)
        run(python, "-m", "pip", "check")
        stage = temporary / "runtime"
        destination = stage / "python"
        destination.mkdir(parents=True)
        base = Path(sys.base_prefix)
        for path in base.iterdir():
            if path.is_file() and (path.suffix.lower() in (".exe", ".dll", ".zip") or path.name.lower().startswith("license")):
                shutil.copy2(path, destination / path.name)
        crt_root = os.environ.get("VCToolsRedistDir")
        crt = sorted(Path(crt_root).glob("x64/Microsoft.VC*.CRT")) if crt_root else []
        if not crt:
            raise RuntimeError("The pinned x64 MSVC redistributable environment is required.")
        for library in crt[-1].glob("*.dll"):
            shutil.copy2(library, destination / library.name)
        shutil.copytree(base / "Lib", destination / "Lib",
            ignore=shutil.ignore_patterns("site-packages", "test", "tkinter", "idlelib", "__pycache__"))
        shutil.copytree(base / "DLLs", destination / "DLLs",
            ignore=shutil.ignore_patterns("_tkinter.pyd", "*tcl*", "*tk86*"))
        shutil.copytree(env / "Lib/site-packages", destination / "Lib/site-packages",
            ignore=shutil.ignore_patterns("__pycache__"))
        (destination / "python312._pth").write_text(".\nLib\nDLLs\nLib/site-packages\nimport site\n", encoding="utf-8")
        for plugin in ("openvino_intel_gpu_plugin.dll", "openvino_intel_npu_plugin.dll"):
            if not list((destination / "Lib/site-packages").rglob(plugin)):
                raise RuntimeError("Required Intel runtime plugin missing: " + plugin)
        run(destination / "python.exe", "-I", "-c",
            "import openvino,torch,transformers,numpy,PIL,soundfile; assert torch.version.cuda is None")
        record = subprocess.check_output([str(python), "-c",
            "import importlib.metadata,json; print(json.dumps({d.metadata['Name']:d.version for d in importlib.metadata.distributions()}))"], text=True)
        licenses = []
        for path in sorted(base.glob("LICENSE*")):
            licenses.append(path.read_text(encoding="utf-8", errors="replace"))
        if not licenses:
            raise RuntimeError("Python redistribution license is missing.")
        for dist in sorted((destination / "Lib/site-packages").glob("*.dist-info")):
            files = sorted(p for p in dist.rglob("*") if p.is_file() and
                (p.name.lower().startswith(("license", "notice", "copying")) or "licenses" in p.parts))
            licenses.append("\n" + dist.name + "\n" + "\n".join(
                path.read_text(encoding="utf-8", errors="replace") for path in files))
        (stage / "THIRD-PARTY-NOTICES.txt").write_text("\n".join(licenses), encoding="utf-8")
        manifest = {"schemaVersion": 1, "python": "3.12.10", "buildIdentity": identity,
                    "packages": json.loads(record),
                    "nativeDLLs": {str(path.relative_to(destination).as_posix()): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in sorted(destination.rglob("*.dll"))},
                    "torchSource": "https://download.pytorch.org/whl/cpu",
                    "inference": "OpenVINO Intel NPU or integrated GPU only; PyTorch is used for explicit offline model preparation."}
        (stage / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(stage, output)
    print("Packaged Intel runtime: " + str(output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "Vendor/openvino")
    build(parser.parse_args().output.resolve())
