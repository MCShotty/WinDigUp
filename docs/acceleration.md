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

## Intel NPU and integrated GPU (OpenVINO)

Windows builds bundle a private x64 Python 3.12.10 environment with OpenVINO 2026.4.1 and the model-preparation
dependencies. Installing a system Python environment is unnecessary. The normal GGUF download is for CUDA/Vulkan;
OpenVINO uses separately exported IR and processor files.

1. In Settings → General → Model acceleration, choose **Intel NPU · OpenVINO** or **Intel integrated GPU · OpenVINO**.
2. Choose **Check Intel setup**. This checks runtime imports and driver device metadata without running model inference.
   NPU mode needs Intel's NPU driver; integrated GPU mode needs a compatible Intel graphics driver.
3. Choose **Download and prepare model**, **Choose bundle**, or expand **Prepare from a local model checkpoint**.
   Downloads are user initiated and pinned to the full revision returned by the fixed model repository. The downloader
   does not use cached account credentials. If access requires a Hugging Face account or license acceptance, open the
   model page and provide a read-only token under Download access, or choose a local snapshot folder. Tokens are scoped
   to the download process, cleared from the field on submission, redacted from download errors and never saved in settings. Local preparation never downloads.
4. Apply and Restart after the bundle and selected device pass preflight. The application then compiles and verifies
   every required graph on that device before content indexing starts. Activity shows the preparation, verification,
   or actual failure reason; a device listing alone never establishes inference readiness.

The Core Ultra 7 258V contains an Intel NPU and integrated graphics. Eligibility depends on what the installed drivers
and OpenVINO plugins expose. GPU mode requires an Intel device reported as integrated; discrete or software adapters
are excluded. Stable identities pin the chosen adapter. Missing, ambiguous or unsupported devices stop with a readable
error. CPU, AUTO, HETERO and switching between GPU and NPU after a failure are unavailable.

**Preparation is a separate, explicit offline export action.** It uses PyTorch on CPU to write full-precision IR and
reference fixtures; it is never an application inference fallback. It needs several GB for the checkpoint and static
profiles. Cancellation, failure or interrupted preparation retains existing bundles, indexes and settings. The export
does not overwrite a bundle in use. Complete local snapshots need vision/audio weights, processor files and a full
40-character checkpoint revision. Snapshot folder names are recognized automatically.

OpenVINO IR can be shared between Intel GPU and NPU. Their vectors cannot: effective stores are
`<base-index>/openvino-gpu/` and `<base-index>/openvino-npu/`. Managed source downloads and exported bundles live under
`<base-index>/openvino-models/`; custom index/settings scopes remain isolated. Existing GPU vectors and annotations stay
in place. Advanced settings retain support for an explicitly chosen Python environment and exported bundle.

The query/app-document profile remains 512 tokens; indexing uses 2048 tokens, five image budgets and 30-second audio.
Token lookup, all backbones/projections, pooling and normalization execute on the chosen device. Intel GPU requests
FP32 computation and checks the compiled precision. NPUW stays disabled for NPU. Both paths reject unsupported operations,
CPU profiling entries and wrong/mixed execution devices; all exported stages must pass reference parity before readiness.
GPU fingerprints include the full revision, bundle, runtime/package versions, precision policy, code identity,
dimension, prompts and text profiles. The existing NPU numerical profile remains compatible.

The private environment includes CPU PyTorch solely for the named preparation action. Runtime workers load processor
and transport code, then execute neural graphs through explicit OpenVINO GPU/NPU compilation. They do not instantiate
a PyTorch model or fall back to it when a graph fails. Compilation caches are backend scoped.

Development CLI setup remains explicit:

```powershell
$env:DIGUP_ACCELERATOR = 'openvino-gpu' # or openvino-npu
$env:DIGUP_OPENVINO_PYTHON = 'C:\DigUpNPU\.venv\Scripts\python.exe'
$env:DIGUP_OPENVINO_MODELS = 'C:\DigUpNPU\models'
$env:DIGUP_OPENVINO_WORKER = "$PWD\worker\openvino\digup_openvino.py"
& .build\release\digup.exe accelerator --list --json # metadata only
& .build\release\digup.exe accelerator # verifies the required model stages
```

The existing command-line exporter is also supported. Its requirements are in `worker/openvino/requirements.txt`.
See [Intel setup validation](intel-openvino.md) for hosted evidence and the physical-device gates.

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
