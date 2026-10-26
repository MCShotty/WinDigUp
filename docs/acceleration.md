# Accelerator-only EmbeddingGemma 2

This fork keeps the upstream Windows/Tauri application and Swift engine. All model execution must use hardware:
the text backbone, token embeddings, vision/audio encoders, projections, mean pooling and L2 normalization.
Missing hardware, insufficient accelerator memory or an unsupported operation stops inference. There is no CPU
inference mode, CPU benchmark or CPU query encoder. Old saved CPU preferences are ignored.

The application, file/database access, search scoring, decoding, image/audio preprocessing, attention/position input
preparation, tokenization and tensor transfers still use the host CPU. A Windows desktop application cannot use
zero CPU. Offline model export also uses the CPU; it never runs as an inference fallback.

## AMD Vulkan and NVIDIA CUDA

Choose **AMD Vulkan — RDNA1 / RX 5000 and newer** or **NVIDIA CUDA — RTX 20-series and newer** in
Settings → General → Model acceleration, then Apply and Restart DigUp. Generic Vulkan accepts non-NVIDIA hardware
only. NVIDIA Vulkan has been removed, including native discovery and visibility overrides.

| Hardware | Execution path | Driver requirement |
| --- | --- | --- |
| AMD RDNA1 / RX 5000 | Standard Vulkan compute shaders | Current vendor Vulkan 1.3 driver |
| AMD RDNA2 / RX 6000 | Vulkan; optional features detected | Current vendor Vulkan 1.3 driver |
| AMD RDNA3 / RX 7000, including RX 7900 XTX | Vulkan | Current vendor Vulkan 1.3 driver |
| AMD RDNA4 / RX 9000 and newer compatible hardware | Vulkan | Compatible vendor Vulkan driver |
| NVIDIA RTX 20/30/40/50 desktop and laptop GPUs | CUDA, compute capability 7.5+ | NVIDIA 576.57 or newer, supporting CUDA 12.9 |

Windows installers bundle CUDA 12.9.1 runtime dependencies. Users install the NVIDIA driver; the CUDA Toolkit is not
required. No ROCm, HIP or cooperative-matrix extension is required for AMD. Memory requirements depend on the
workload and precision profile; model allocation failure stops inference instead of moving computation to CPU.

Use Refresh devices to list adapters without model weights. A listed device is available, not yet verified running
the model. Activity records a separate receipt after actual inference. Device IDs and stable UUIDs belong to their
backend; Vulkan0 cannot identify CUDA0. Explicit selections never fall through to another GPU or backend.

Saved NVIDIA Vulkan preferences migrate to CUDA. Old numbered Vulkan pins require re-selection because excluding
NVIDIA can change numbering. The migration retains folders, annotations and legacy indexes. Fresh installations
resolve an initial supported GPU in the background; legacy generic Vulkan retains eligible non-NVIDIA hardware.
OpenVINO selection remains explicit. Discovery errors leave native app name search and launching available.

CUDA uses the existing Q8 GGUF weights with the initial **cuda-fp32-v1** precision profile: FP32 dequantization and
pedantic cuBLAS matrix operations on the GPU, FP32 attention buffers, and disabled flash-attention/fusion paths.
The compiled policy prevents unsafe FP16 activation down-conversion and managed-memory spill overrides. This is a
correctness-first profile; no performance improvement is claimed without physical-device measurements.
AMD also avoids unsafe FP16 activation conversion. Pooling and L2 normalization run on the selected accelerator.

The patched ggml core rejects CPU/host numerical graph execution before schedule submission and on direct,
asynchronous and graph-plan paths. A CPU module remains for storage and transfers. Its presence in logs does not
establish CPU inference. The helper verifies native policy version 2 and pins text, vision and audio to one device.

CUDA stores file/code/app vectors under `<base-index>/nvidia-cuda/`. The Windows app catalog and icons remain under
`<base-index>/applications/`; annotations remain in settings. `--index` always names the base directory, even when its
last component happens to be a backend name. CUDA fingerprints include full model revision, native build and precision
profile. Switching accelerators retains other backend indexes and prepares compatible vectors separately.

```powershell
$env:DIGUP_ACCELERATOR = 'nvidia-cuda' # AMD: amd-vulkan; NPU: openvino-npu
# Optional: use a CUDA device ID or the stable GPU UUID from discovery.
# $env:DIGUP_GPU = 'CUDA0'
& 'C:\Users\YOUR_NAME\AppData\Local\DigUp\helper\digup.exe' accelerator --list --json
& 'C:\Users\YOUR_NAME\AppData\Local\DigUp\helper\digup.exe' accelerator
```

An explicit `DIGUP_ACCELERATOR=nvidia-vulkan` request is rejected with migration guidance. CUDA failures never
activate Vulkan or CPU. Older NVIDIA architectures are unsupported; native application launching still works.

## Intel NPU (OpenVINO)

The Core Ultra 7 258V has an Intel NPU. Install Intel's current Windows NPU driver and use 64-bit Python 3.12.
NPU mode requires the complete Transformers **google/embeddinggemma-2** checkpoint, including its vision/audio
weights and processor. The application's GGUF files are for CUDA/Vulkan and cannot be loaded by OpenVINO.
Obtain the checkpoint through your own Hugging Face account under its model license, with a pinned full snapshot
commit. Preparation is offline once those files and the Python packages have been downloaded.

From a checkout of this fork, in PowerShell:

```powershell
py -3.12 -m venv C:\DigUpNPU\.venv
$python = 'C:\DigUpNPU\.venv\Scripts\python.exe'
& $python -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cpu
& $python -m pip install -r worker\openvino\requirements.txt
& $python worker\openvino\export_model.py --source C:\DigUpNPU\source --output C:\DigUpNPU\models --revision FULL_40_CHARACTER_SNAPSHOT_COMMIT
```

Allow several GB for the static profiles: queries (512 tokens), indexing (2048 tokens), five image budgets and
30-second audio. The exporter writes full-precision IR, checksums, processor files and per-stage reference fixtures.
The source model and PyTorch forward passes are used only during this explicit preparation step.

Choose **Intel NPU — OpenVINO** in Settings, enter the Python executable and exported bundle folder, and apply.
Every required graph is queried and compiled explicitly for `NPU`, with the NPUW wrapper disabled. The worker checks `EXECUTION_DEVICES`, profiling
and reference parity for every stage before reporting ready. `CPU`, `AUTO`, `HETERO` and mixed-device execution are
rejected. A driver that cannot compile a stage or reproduce its reference output produces an error, never a partial
CPU pipeline. NPU vectors have a bundle fingerprint and a separate `index/openvino-npu` store, including code search.
Changing the model bundle requires restarting DigUp.

For a development checkout, point the helper to the worker:

```powershell
$env:DIGUP_ACCELERATOR = 'openvino-npu'
$env:DIGUP_OPENVINO_PYTHON = 'C:\DigUpNPU\.venv\Scripts\python.exe'
$env:DIGUP_OPENVINO_MODELS = 'C:\DigUpNPU\models'
$env:DIGUP_OPENVINO_WORKER = "$PWD\worker\openvino\digup_openvino.py"
& .build\release\digup.exe accelerator # verifies all NPU stages
```

## Validation and hardware limits

Automated tests verify that direct/scheduled CPU arithmetic leaves output buffers untouched, invalid/mixed devices
are rejected, and tiny real EmbeddingGemma 2 text/vision/audio exports reproduce Transformers. The tiny conversion
test evaluates IR on CPU solely to check the exporter mathematics; the application's `NPURuntime` never permits it.
Windows CI builds the actual installer, checks the packaged CUDA/non-NVIDIA Vulkan backends and launches installed Settings with only
app-local Swift/VC runtime DLLs. It does not run user-model inference on a CPU-only hosted runner.

These checks do **not** establish full-checkpoint execution, performance, memory use or accuracy on RX 5000/6000/7000/
9000, RTX 20/30/40/50 hardware or the Ultra 7 258V NPU. A physical-device acceptance run is required before calling those
combinations validated. NPU compilation and FP16 internal precision are particularly driver-dependent.

On each target machine, run `digup accelerator`, then `digup speed --model --measure-only --json`, index a folder
containing text, an image and mono 16 kHz WAV, and search it. Confirm device/policy logs, valid vectors for every
modality and a query encoder on the same backend. With the adapter disabled or unavailable, repeat and confirm a
clear error and no CPU inference. To exercise RDNA1's shader path on newer hardware, disable optional cooperative
matrix and integer-dot features through ggml's diagnostic environment flags; a real RX 5000 run is still required.
With the GGUF model installed, `swift test --filter ReferenceVectorTests` compares GPU vectors with the retained
version 1 golden corpus and verifies normalization. The minimum cosine agreement remains 0.999.

The updater reads this fork's feed and rejects upstream package URLs inherited by a sync, preserving this execution policy.

## Building the Windows CUDA runtime

Use the pinned MSVC 2022 toolset 14.44 and CMake 4.4.4. `python scripts/fetch-cuda.py --platform windows-x86_64`
assembles the checksummed NVIDIA 12.9.1 redistributables. Add its `bin` to PATH and point `CUDAToolkit_ROOT` there.
`scripts/build-llama.sh` builds CUDA and Vulkan against one patched core, with explicit SM 75/86/89/120a targets.
CPU-only production builds and unsupported Toolkit versions are rejected. Linux CUDA builds require the same
Toolkit with `DIGUP_BUILD_CUDA=1`; default Linux Vulkan builds do not support NVIDIA. Metal remains the macOS path.

The package script follows the compiled DLL dependency closure, checks redistributable provenance, and refuses
unresolved dependencies. The driver-owned nvcuda.dll is never bundled. The installer replaces its private helper
folder on upgrades and reports a runtime-in-use error rather than mixing old and new DLLs.

Physical CUDA execution, full-model parity, throughput, memory requirements and purpose relevance require the
hardware acceptance procedure in [CUDA validation](cuda-validation.md). Compilation and mocked-device tests are
not hardware validation. RTX 20-series is the required minimum-generation acceptance target.

## GPU work limits

General settings offers Automatic or 1, 2, or 3 GPU jobs through Apply and Restart. CUDA and non-NVIDIA Vulkan use
shared per-device admission, foreground priority, and memory checks before creating extra model owners. Automatic
means an upper bound of three, not a measured threefold speedup. OpenVINO and Metal retain their current ownership.
The CLI equivalent is `DIGUP_GPU_JOBS=0|1|2|3`. This does not change vector compatibility or permit another adapter,
backend, CPU arithmetic, or a weaker CUDA precision profile. See [concurrency contracts and hardware checks](discovery-concurrency.md).
