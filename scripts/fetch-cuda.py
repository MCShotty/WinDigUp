#!/usr/bin/env python3
"""Assemble the pinned NVIDIA redistributables; the CUDA Toolkit is a build dependency only."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request
import zipfile

VERSION = "12.9.1"
BASE = "https://developer.download.nvidia.com/compute/cuda/redist/"
MANIFEST_SHA256 = "8335301010b0023ee1ff61eb11e2600ca62002d76780de4089011ad77e0c7630"
COMPONENTS = ("cuda_cudart", "libcublas", "cuda_nvcc", "cuda_cccl")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(url, target, checksum):
    if target.is_file() and sha(target) == checksum:
        return
    temporary = target.with_suffix(target.suffix + ".part")
    with urllib.request.urlopen(url, timeout=120) as source, temporary.open("wb") as output:
        shutil.copyfileobj(source, output, 1024 * 1024)
    if sha(temporary) != checksum:
        temporary.unlink()
        raise RuntimeError(f"checksum mismatch: {target.name}")
    temporary.replace(target)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--platform", choices=("windows-x86_64", "linux-x86_64"), required=True)
    p.add_argument("--output", type=Path, default=Path("Vendor/cuda"))
    p.add_argument("--runtime-only", action="store_true")
    a = p.parse_args()
    root = a.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    cache = root / "downloads"
    cache.mkdir(exist_ok=True)
    manifest_file = cache / f"redistrib_{VERSION}.json"
    download(BASE + manifest_file.name, manifest_file, MANIFEST_SHA256)
    manifest = json.loads(manifest_file.read_text())
    components = COMPONENTS[:2] if a.runtime_only else COMPONENTS

    def fetch(name):
        item = manifest[name][a.platform]
        archive = cache / Path(item["relative_path"]).name
        print(f"CUDA {name} {manifest[name]['version']}", flush=True)
        download(BASE + item["relative_path"], archive, item["sha256"])
        return name, archive

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        archives = list(pool.map(fetch, components))
    for name, archive in archives:
        temporary = root / ("unpack-" + name)
        if temporary.exists():
            shutil.rmtree(temporary)
        temporary.mkdir()
        if archive.suffix == ".zip":
            with zipfile.ZipFile(archive) as z:
                for member in z.namelist():
                    if not (temporary / member).resolve().is_relative_to(temporary):
                        raise RuntimeError("unsafe archive member")
                z.extractall(temporary)
        else:
            with tarfile.open(archive) as t:
                t.extractall(temporary, filter="data")
        folders = list(temporary.iterdir())
        if len(folders) != 1 or not folders[0].is_dir():
            raise RuntimeError(f"unexpected archive layout: {archive.name}")
        source = folders[0]
        for child in source.iterdir():
            if child.is_dir():
                shutil.copytree(child, root / child.name, dirs_exist_ok=True, symlinks=True)
            elif child.name.lower().startswith(("license", "eula", "copyright")):
                license_dir = root / "licenses" / name
                license_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(child, license_dir / child.name)
            else:
                shutil.copy2(child, root / child.name)
        shutil.rmtree(temporary)
    if a.platform.startswith("linux") and not (root / "lib64").exists():
        (root / "lib64").symlink_to("lib", target_is_directory=True)
    (root / "version.txt").write_text(f"CUDA Version {VERSION}\n")
    record = {"version": VERSION, "platform": a.platform, "manifestSHA256": MANIFEST_SHA256,
              "components": {name: {"version": manifest[name]["version"], "sha256": manifest[name][a.platform]["sha256"]}
                             for name in components}, "minimumWindowsDriver": "576.57"}
    (root / "redistribution.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"CUDA {VERSION} assembled in {root}", flush=True)


if __name__ == "__main__":
    main()
