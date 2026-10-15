# Accelerator-only EmbeddingGemma 2

This fork keeps the upstream Windows/Tauri application and Swift engine. All model execution must use hardware:
the text backbone, token embeddings, vision/audio encoders, projections, mean pooling and L2 normalization.
Missing hardware, insufficient accelerator memory or an unsupported operation stops inference. There is no CPU
inference mode, CPU benchmark or CPU query encoder. Old saved CPU preferences are ignored.

The application, file/database access, search scoring, decoding, image/audio preprocessing, attention/position input
preparation, tokenization and tensor transfers still use the host CPU. A Windows desktop application cannot use
zero CPU. Offline model export also uses the CPU; it never runs as an inference fallback.

## AMD and NVIDIA

In **Settings → General → Model acceleration**, choose AMD Vulkan or NVIDIA Vulkan, then **Apply and Restart DigUp**.
Leave the GPU device blank for automatic selection, or enter `Vulkan0`, `Vulkan1`, etc. to pin a device.
The helper's `accelerator` command reports the selected physical adapter without loading model weights.

| AMD architecture | Typical discrete cards | Execution path |
| --- | --- | --- |
| RDNA1 | RX 5000, including 5500 XT, 5600 XT, 5700 XT | Standard Vulkan compute shaders |
| RDNA2 | RX 6000 | Standard Vulkan shaders; optional capabilities detected at runtime |
| RDNA3 | RX 7000, including RX 7900 XTX | Same Vulkan backend |
| RDNA4 and newer | RX 9000 and successors with compatible Vulkan drivers | Same capability-based backend |

Install a current AMD Adrenalin or NVIDIA driver with Vulkan 1.3 support. No ROCm, HIP, CUDA toolkit or cooperative
matrix extension is required. Newer optional GPU features are never a prerequisite for the standard shader path.
The build includes Vulkan even if CUDA tools are installed. Software/virtual Vulkan adapters are rejected.
Quantized Q8 model weights stay on the selected GPU; FP16 activation conversion is disabled because EmbeddingGemma 2
can exceed FP16's numeric range. Out-of-memory errors never spill model computation onto CPU.

The patched ggml library checks the entire schedule before submission and rejects numerical operations on a CPU or
host accelerator backend. It also checks direct/asynchronous graph and opaque graph-plan execution. A CPU backend
remains installed for host storage and transfers; its presence in a log does not mean CPU inference is enabled.
The Swift helper verifies the loaded library's compiled enforcement flag and pins text, vision and audio to the
same device. Vector version 2 rebuilds existing GPU indexes for accelerator normalization.

For the CLI in PowerShell:

```powershell
$env:DIGUP_ACCELERATOR = 'amd-vulkan' # or nvidia-vulkan / vulkan
# Optional: $env:DIGUP_GPU = 'Vulkan0'
& 'C:\Users\YOUR_NAME\AppData\Local\DigUp\helper\digup.exe' accelerator
```

## Intel NPU (OpenVINO)

The Core Ultra 7 258V has an Intel NPU. Install Intel's current Windows NPU driver and use 64-bit Python 3.12.
NPU mode requires the complete Transformers **google/embeddinggemma-2** checkpoint, including its vision/audio
weights and processor. The application's GGUF files are for Vulkan and cannot be loaded by OpenVINO.
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
Every required graph is queried and compiled explicitly for `NPU`. The worker checks `EXECUTION_DEVICES`, profiling
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
Windows CI builds the actual installer, checks the packaged Vulkan backend and launches installed Settings with only
app-local Swift/VC runtime DLLs. It does not run user-model inference on a CPU-only hosted runner.

These checks do **not** establish full-checkpoint execution, performance, memory use or accuracy on RX 5000/6000/7000/
9000, NVIDIA hardware or the Ultra 7 258V NPU. A physical-device acceptance run is required before calling those
combinations validated. NPU compilation and FP16 internal precision are particularly driver-dependent.

On each target machine, run `digup accelerator`, then `digup speed --model --measure-only --json`, index a folder
containing text, an image and mono 16 kHz WAV, and search it. Confirm device/policy logs, valid vectors for every
modality and a query encoder on the same backend. With the adapter disabled or unavailable, repeat and confirm a
clear error and no CPU inference. To exercise RDNA1's shader path on newer hardware, disable optional cooperative
matrix and integer-dot features through ggml's diagnostic environment flags; a real RX 5000 run is still required.

The updater now reads this fork's feed, so accepting an upstream update cannot replace this execution policy.
