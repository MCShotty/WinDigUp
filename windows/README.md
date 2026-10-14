# WinDigUp for Windows

WinDigUp uses native WinUI 3 controls and the upstream DigUp Swift engine. The engine keeps the original
EmbeddingGemma 2 prompts, 768-dimensional vectors, SQLite/FTS search, file rules, page/passage/moment extraction,
and separate code index. The macOS app and the existing Tauri shell remain available.

The Windows app has folder setup, search and type filters, passage and image previews, a tray menu,
**Ctrl+Shift+Space**, background folder watching, pause/resume, model download, and persistent settings.
Closing the window keeps it in the tray; **Quit** stops its helpers and releases the models.

| Choice | Runtime | What runs there |
|---|---|---|
| Automatic | llama.cpp | CUDA preferred, then a usable GPU, otherwise CPU |
| NVIDIA GPU | llama.cpp CUDA | Text, image and audio model computation |
| AMD GPU | llama.cpp Vulkan | Text, image and audio model computation, including Radeon integrated GPUs |
| Intel NPU | OpenVINO | Text backbone, including the projected image/audio tokens; vision/audio encoders use CPU |
| CPU | llama.cpp | Entire model |

Explicit choices fail if that device/backend is unavailable. The helpers report the actual encoder device.
OpenVINO requires an exported model bundle; it cannot load the GGUF download. Its index is separate from
llama.cpp's. Switching among llama.cpp devices preserves the upstream vector contract; hardware reference
tests must pass before distributing an accelerated build.

## Build

Windows 10 version 2004 or later, x64 (Windows 11 recommended). Install:

- Visual Studio 2022 or later with **Desktop development with C++**, a Windows SDK, CMake and Ninja.
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0), [Swift 6.2.3](https://www.swift.org/install/windows/),
  Git for Windows, and Python 3.12.
- CUDA Toolkit for a CUDA build; Vulkan SDK (with `glslc`) for a Vulkan build. Both are needed to package both
  GPU backends. Users need a compatible GPU driver, not the development SDKs.
- Static `ffmpeg` and `ffprobe` **8.1 or newer** on PATH for image/audio/video extraction. The build packages
  them beside the helper, along with the distributor's license and source/build information.

In **x64 Developer PowerShell for Visual Studio**, from the repository root:

```powershell
./scripts/build-windows.ps1 -GpuBackends cuda,vulkan -Test
./windows/artifacts/WinDigUp/WinDigUp.exe
```

`-GpuBackends cpu` builds without a GPU SDK. `auto` detects installed build tools and includes both backends
when both are available. For a redistributable CUDA build set `$env:CUDA_ARCHS = 'all-major'` before building;
the default `native` targets the build machine's GPU. `-SwiftRuntimeDirectory` can specify the installed
Swift runtime's `usr/bin` folder if automatic detection cannot find it.

The build produces the app, helper, shared Swift/llama/PDFium libraries, and OpenVINO worker under
`windows/artifacts/WinDigUp`. The .NET and Windows App SDK runtimes are included. Install the MSVC runtime
where it is not already present. The model downloads separately through the helper's existing pinned,
resumable, SHA-256-verified downloader. CUDA runtime libraries copied from the toolkit are subject to its
redistribution terms.

To build just the UI (requires Windows, but no Swift or GPU toolchain):

```powershell
dotnet run --project windows/WinDigUp.Core.Tests
dotnet build windows/WinDigUp/WinDigUp.csproj -p:Platform=x64
```

The app offers a helper path setting. UI-only builds need a previously built `helper/digup.exe` and its libraries.
CI builds the UI plus separate CPU and Vulkan helpers, then publishes **WinDigUp-Windows-x64** (CPU)
and **WinDigUp-Windows-x64-AMD-Vulkan** (AMD GPU, with CPU fallback). Both contain the full app.
The AMD package includes the Vulkan backend, compiled shaders, loader, and license notices. CI checks
that the packaged helper starts and the Vulkan module loads without a development SDK on PATH.
`build-info.json` records the source commit, native build configuration and Vulkan SDK version.

For AMD, download and extract **WinDigUp-Windows-x64-AMD-Vulkan**, install a current AMD graphics
driver supporting Vulkan 1.3, and run `WinDigUp.exe`. Choose **AMD GPU · Vulkan**, add your folders,
download the GGUF model, and save settings. The encoder status should show your AMD/Radeon device.
GPU inference and performance must still be checked on the actual AMD machine; the CI runner has no AMD GPU.
NVIDIA CUDA distributions require a build with the CUDA SDK.

## Intel NPU / OpenVINO

Install the current Intel NPU driver for your Core Ultra device. Create an isolated environment:

```powershell
python -m venv worker/windows/.venv
./worker/windows/.venv/Scripts/python.exe -m pip install -r worker/windows/requirements.txt
```

Download a **Transformers** snapshot of `google/embeddinggemma-2` separately (with the model's applicable
access/license requirements), or use an existing snapshot. Pin the source commit; the upstream conversion was
made from `914f7f8`. Export from local files only:

```powershell
./worker/windows/.venv/Scripts/python.exe worker/windows/export_openvino.py `
    --source C:/Models/embeddinggemma-2-snapshot `
    --revision 914f7f8 --output C:/Models/digup-openvino --verify-device NPU
```

Export checks the model architecture, uses FP32 weights without FP16 compression, and compares both the
512-token query and 2048-token index graphs with Transformers reference vectors (cosine >= 0.999). It publishes
the bundle only after checks pass. Export may need several GB of RAM and disk space. `--verify-device CPU` can
prepare it on another machine; the worker still checks NPU execution and parity at startup on the target.

In the app select **Intel NPU · OpenVINO**, set **OpenVINO Python executable** to the environment's Python,
and **Exported OpenVINO model folder** to the output. The bundled worker is discovered beside the app.
Use a full export for indexing; `--text-only` exports are for query testing only.

NPU support depends on the driver's operator and precision support for this new architecture. EmbeddingGemma 2
can overflow in float16. A compile or parity failure is an unavailable backend, not successful acceleration.
The worker checks the bundle checksums, verifies `EXECUTION_DEVICES`, rejects non-finite or unnormalized vectors,
and stops if reference parity fails. There is no `AUTO`/`HETERO` device or silent CPU fallback. Vision/audio
encoders execute on the CPU and their soft tokens enter the same NPU backbone. All model reads and inference
are local; Hugging Face offline mode is enforced in the worker.

For direct helper use, set these variables for both indexing and search:

```powershell
$env:DIGUP_BACKEND = 'openvino-npu'
$env:DIGUP_OPENVINO_PYTHON = 'C:/…/.venv/Scripts/python.exe'
$env:DIGUP_OPENVINO_WORKER = 'C:/…/worker/windows/openvino_worker.py'
$env:DIGUP_OPENVINO_MODELS = 'C:/Models/digup-openvino'
```

`DIGUP_BACKEND` also accepts `auto`, `cpu`, `nvidia`, and `amd`. `DIGUP_MODELS` selects the GGUF folder for llama.cpp.

## Verification and current limits

```powershell
dotnet run --project windows/WinDigUp.Core.Tests
python -m pytest -q worker/windows/test_openvino_worker.py
swift test
```

On each GPU machine, install the pinned GGUF files and run `swift test --filter ReferenceVectorTests` with
`DIGUP_BACKEND=nvidia` or `amd`. That suite skips without the model files; a skipped run is not hardware evidence.
For NPU hardware use `--verify-device NPU` during export and test text, images and audio through `digup worker`.
The fixed startup probes do not replace evaluating the full multimodal corpus on the target hardware.

This port retains the portable engine's limitations: Windows extraction does not provide Apple's Vision OCR,
Quick Look, HEIC coverage or QuickTime automation. Previews use DigUp's portable readers. Code can open at its
line in VS Code/Cursor-compatible editors; media opens at its moment when VLC is installed, otherwise in its
default app. PDFs open in the default reader; their matched page is available in the app's preview. Windows
installer signing, automatic updates and battery-aware scheduling are not included in this source port.

Settings, models, logs and indexes live in `%LOCALAPPDATA%/WinDigUp`; the upstream CLI's default remains
`%LOCALAPPDATA%/DigUp`. No indexed files are modified or uploaded.
