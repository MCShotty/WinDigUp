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
test -f "$installed/helper/openvino/digup_openvino.py"
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
echo "PASS: installed Windows GUI launches; CPU and invalid backend selection rejected"
