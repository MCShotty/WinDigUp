#!/bin/bash
# Builds DigUp's Windows installer: the Tauri shell (shell/) with DigUp's helper, llama.cpp, PDFium, the Swift and C++
# runtimes and ffmpeg in its helper folder, as an NSIS installer that installs for the current user (no admin prompt).
# Run it in Git for Windows' bash inside a Visual Studio developer environment, after scripts/fetch-vendor.sh,
# scripts/build-llama.sh and scripts/build-ffmpeg.sh (that one in MSYS2's MINGW64 shell). Needs Swift, Rust, Python and
# Node (for Tauri's CLI):
#   scripts/package-windows.sh      → shell/src-tauri/target/release/bundle/nsis/
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x Vendor/ffmpeg/bin/ffmpeg.exe ]] || { echo "no Vendor/ffmpeg/bin/ffmpeg.exe: run scripts/build-ffmpeg.sh in MSYS2" >&2; exit 1; }
tauri_runner="$PWD/scripts/tauri-cli.sh"

test -f Vendor/llama/lib/ggml-cuda.dll || { echo "CUDA backend missing: run the pinned CUDA/Vulkan build first" >&2; exit 1; }
python=python3
python3 -c '' 2>/dev/null || python=python
"$python" - <<'PYVERIFY'
import json
from pathlib import Path
m=json.loads(Path('Vendor/llama/native-runtime.json').read_text())
assert m['policyVersion']==2 and m['flavor']=='vulkan-cuda' and m['cudaToolkit']=='12.9.1', 'Native build is not the pinned CUDA/Vulkan runtime'
PYVERIFY
swift build -c release --product digup

# What the installer puts beside DigUp.exe, in helper\ ("DigUp.exe" and "digup.exe" can't share a folder): the helper
# finds the DLLs, llama.cpp's backends and ffmpeg in its own folder. The C++ runtime goes with them, so nothing needs
# installing first; the shell itself links its C runtime statically (.cargo/config.toml).
swift_root=$(cd "$(dirname "$(command -v swift)")/../../../.." && pwd)   # …/Swift from …/Swift/Toolchains/*/usr/bin
swift_runtime=$(ls -d "$swift_root"/Runtimes/*/usr/bin | tail -1)
crt=$(ls -d "$(cygpath "$VCToolsRedistDir")"x64/Microsoft.VC*.CRT | tail -1)   # set by the developer environment
helper=shell/src-tauri/helper
rm -rf "$helper"
mkdir -p "$helper"
cp .build/release/digup.exe Vendor/llama/lib/*.dll Vendor/pdfium/bin/pdfium.dll "$helper/"
cp "$swift_runtime"/*.dll "$helper/"
cp Vendor/llama/native-runtime.json "$helper/"
cp "$crt"/*.dll "$helper/"   # over the Swift runtime's copies of the same: the newer C++ runtime
cp Vendor/ffmpeg/bin/ffmpeg.exe Vendor/ffmpeg/bin/ffprobe.exe "$helper/"   # the small static build, no DLLs
# Installed only on explicit request with UAC. It never inherits a writable user installation as its service path.
(cd shell/src-tauri && cargo build --release --locked --bin digup-discovery)
cp shell/src-tauri/target/release/digup-discovery.exe "$helper/"
"$python" - "$helper/digup-discovery.exe" <<'PYDISCOVERY'
import re, subprocess, sys
report=subprocess.run(["dumpbin.exe", "/DEPENDENTS", sys.argv[1]],check=True,capture_output=True,text=True).stdout
libraries=re.findall(r"^\\s+([\\w.-]+\\.dll)\\s*$",report,re.M|re.I)
assert libraries, "Discovery component dependency audit returned no imports"
for name in libraries:
 assert not re.match(r"(swift|ggml|llama|cudart|cublas|vcruntime|msvcp|WebView2Loader)",name,re.I), "Discovery must run independently: "+name
print("Discovery component imports:", ", ".join(libraries))
PYDISCOVERY
"$python" scripts/package-cuda-runtime.py --helper "$helper"
mkdir -p "$helper/openvino"
cp worker/openvino/*.py worker/openvino/requirements.txt "$helper/openvino/"

# With the release's signing key (TAURI_SIGNING_PRIVATE_KEY, and its password) the packages that update themselves are
# signed for in-app updates (a .sig beside each). Installed copies check those signatures with the public key in
# tauri.conf.json (plugins.updater.pubkey): a release built without it could never update.
signing=
if [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  if grep -q '"pubkey": ""' shell/src-tauri/tauri.conf.json; then
    echo "the signing key is set, but plugins.updater.pubkey in shell/src-tauri/tauri.conf.json is empty" >&2
    exit 1
  fi
  signing=',"createUpdaterArtifacts":true'
fi
# The license of everything the installer carries, installed beside the app. (python3 can be the Store's stub.)
python=python3
python3 -c '' 2> /dev/null || python=python
"$python" scripts/notices.py windows shell/src-tauri/THIRD-PARTY-NOTICES.txt
# Installers of an earlier build (another version) would be taken for this one's.
rm -rf shell/src-tauri/target/release/bundle/nsis
# The helper folder goes in as the installer's resources here only: Tauri checks resources on every build.
resources='{"helper/":"helper/","THIRD-PARTY-NOTICES.txt":"THIRD-PARTY-NOTICES.txt"}'
(cd shell/src-tauri && bash "$tauri_runner" build --bundles nsis \
  --config "{\"bundle\":{\"resources\":$resources$signing}}")
ls -la shell/src-tauri/target/release/bundle/nsis/
