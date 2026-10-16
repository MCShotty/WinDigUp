#!/bin/bash
# Installed app launch and strict-policy checks on a runner without accelerator hardware.
# No model download or CPU inference is allowed. Real inference requires the hardware check documented in docs/acceleration.md.
set -euo pipefail
cd "$(dirname "$0")/.."
setup=${1:?the installer}
work=$(mktemp -d)
cleanup() {
  if [[ -n ${app:-} ]] && kill -0 "$app" 2>/dev/null; then kill "$app" 2>/dev/null || true; fi
  # Windows releases the helper's database handles asynchronously after the parent exits.
  for attempt in {1..20}; do
    rm -rf "$work" 2>/dev/null && return
    sleep 0.25
  done
}
trap cleanup EXIT
win() { cygpath -m "$1"; }
MSYS_NO_PATHCONV=1 "$setup" /S
installed=$(cygpath -u "$LOCALAPPDATA")/DigUp
helper=$installed/helper/digup.exe
test -f "$installed/DigUp.exe"
test -f "$installed/helper/ggml-vulkan.dll"
test -f "$installed/helper/ggml-cuda.dll"
test -f "$installed/helper/cudart64_12.dll"
test -f "$installed/helper/cublas64_12.dll"
test -f "$installed/helper/cublasLt64_12.dll"
test ! -f "$installed/helper/nvcuda.dll"
python=python3
python3 -c '' 2>/dev/null || python=python
"$python" - "$(win "$installed/helper")" <<'PYCUDA'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); record=json.loads((root/'cuda-runtime.json').read_text())
assert record['version']=='12.9.1' and record['schemaVersion']==1
for name,expected in record['files'].items():
 with (root/name).open('rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest()==expected,name
assert json.loads((root/'native-runtime.json').read_text())['policyVersion']==2
PYCUDA
PATH="/c/Windows/System32:/c/Windows" DIGUP_ACCELERATOR=nvidia-cuda "$helper" accelerator --list --json > "$work/devices.json" 2> "$work/devices-error.txt"
"$python" - "$(win "$work/devices.json")" <<'PYDEVICES'
import json,sys
p=json.load(open(sys.argv[1])); assert p['schemaVersion']==1 and p['probeOnly']
assert all(d['vendorID']!=0x10de for d in p['devices'] if d['backend']=='vulkan')
PYDEVICES
if DIGUP_ACCELERATOR=nvidia-vulkan "$helper" accelerator > "$work/removed.txt" 2>&1; then
  echo "Removed NVIDIA Vulkan backend was accepted" >&2; exit 1
fi
grep -q 'NVIDIA Vulkan has been removed' "$work/removed.txt"
if DIGUP_ACCELERATOR=nvidia-cuda GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 "$helper" accelerator > "$work/spill.txt" 2>&1; then
  echo "CUDA managed-memory override was accepted" >&2; exit 1
fi
grep -q 'managed-memory spill is disabled' "$work/spill.txt"
test -f "$installed/helper/openvino/digup_openvino.py"
test -f "$installed/helper/digup-discovery.exe"
# No developer tools/runtime on PATH: DLLs and VC/Swift runtimes must be app-local.
if PATH="/c/Windows/System32:/c/Windows" DIGUP_DEVICE=cpu "$helper" accelerator > "$work/cpu.txt" 2>&1; then
  echo "CPU selection was accepted" >&2; exit 1
fi
grep -q 'CPU inference is disabled' "$work/cpu.txt"
if DIGUP_DEVICE=cpu "$helper" speed --model --json --index "$(win "$work/index")" > "$work/speed.txt" 2>&1; then
  echo "CPU benchmark was accepted" >&2; exit 1
fi
grep -q '"event":"error"' "$work/speed.txt"
grep -q 'CPU inference is disabled' "$work/speed.txt"
if PATH="/c/Windows/System32:/c/Windows" DIGUP_ACCELERATOR=invalid "$helper" accelerator > "$work/invalid.txt" 2>&1; then
  echo "Unknown accelerator was accepted" >&2; exit 1
fi
grep -q 'Unknown accelerator' "$work/invalid.txt"
# Probe physical GPU availability, never load a model. Missing/software GPU must produce an explicit failure.
if DIGUP_ACCELERATOR=amd-vulkan "$helper" accelerator > "$work/gpu.txt" 2>&1; then
  grep -q 'accelerator-only' "$work/gpu.txt"
else
  grep -q 'No compatible amd-vulkan hardware GPU' "$work/gpu.txt"
fi
# First launch with an unconfigured NPU must still render Settings and show a recoverable model error.
cat > "$work/settings.json" <<'JSON'
{"setUp":true,"updateChecksOff":true,"acceleration":{"backend":"openvino-npu"}}
JSON
"$installed/DigUp.exe" --settings "$(win "$work/settings.json")" --index "$(win "$work/index")" \
  --debug-window "" --debug-settings --debug-quit > "$work/ui.txt" 2> "$work/ui-error.txt" &
app=$!
started=$(date +%s)
while kill -0 "$app" 2>/dev/null && (( $(date +%s) - started < 90 )); do sleep 1; done
if kill -0 "$app" 2>/dev/null; then
  kill "$app" || true
  cat "$work/ui.txt" "$work/ui-error.txt"
  echo "Installed app did not render Settings" >&2; exit 1
fi
cat "$work/ui.txt" "$work/ui-error.txt"
grep -q '"settings":true' "$work/ui.txt"
grep -q '"accelerator":"openvino-npu"' "$work/ui.txt"
grep -q '"cpuOption":false' "$work/ui.txt"
grep -q '"activitySchema":1' "$work/ui.txt"
grep -q '"activityRendered":true' "$work/ui.txt"
echo "PASS: installed Windows GUI launches; CPU and invalid backend selection rejected"
# A reinstall replaces the private runtime folder, including obsolete dependencies, without touching app data.
printf '%s\n' obsolete > "$installed/helper/obsolete-cuda-fixture.dll"
MSYS_NO_PATHCONV=1 "$setup" /S
test ! -f "$installed/helper/obsolete-cuda-fixture.dll"
test -f "$installed/helper/cuda-runtime.json"
PATH="/c/Windows/System32:/c/Windows" DIGUP_ACCELERATOR=nvidia-cuda "$helper" accelerator --list --json > "$work/reinstalled-devices.json"
echo "PASS: CUDA dependency manifest, removed NVIDIA Vulkan, clean-PATH discovery and runtime replacement"
