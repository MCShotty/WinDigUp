# CUDA acceptance

The Windows CUDA implementation is stacked on PR #5. Compiled architecture targets are RTX 20/30/40/50 families
(SM 75/86/89/120a); this is not a claim of physical-device validation. All neural computation, including pooling and
normalization, must remain on the selected NVIDIA CUDA device. CPU input preparation and validation are separate.

## Evidence required before hardware acceptance

| Generation | Representative target | Physical result |
| --- | --- | --- |
| RTX 20 | Turing / SM 75, required minimum | Not run |
| RTX 30 | Ampere / SM 86 | Not run |
| RTX 40 | Ada / SM 89 | Not run |
| RTX 50 | Blackwell / SM 120a | Not run |

Record GPU name/UUID, driver and CUDA API versions, native build identity, precision profile, complete model
revision, installed artifact checksum and Windows version. NVIDIA driver 576.57 or newer is the initial supported
baseline. End-user acceptance must run without the CUDA Toolkit on PATH.

Run device discovery without weights, then the `accelerator` probe. The latter is a device probe, not evidence of
model execution. Exercise the full-model reference corpus (multilingual queries, short/long documents, screenshot,
photo, video-frame budget and speech). Every reference cosine must be at least 0.999. Every vector must contain 768
finite numbers and have norm-squared within 0.005 of one. Validate image budgets 70/140/280/560/1120 and the
512-token query/app-document and 2048-token indexing profiles. Do not weaken thresholds or rewrite reference
vectors merely to pass CUDA.

Run app-purpose positive queries with documented descriptions and unrelated negatives through the current relevance
gate. Record actual rankings, scores and misses; raw cosines are not confidence percentages. Check mixed results,
apps-only searches, native name matching during model failure and native launch acceptance.

Exercise file/code indexing, query/index concurrency, incremental app embedding, idle unload, helper restart and
application restart. Repeat with CUDA/Vulkan/NPU backend changes and confirm index isolation. Simulate an unavailable
selected GPU, low VRAM, absent runtime DLL, old driver, `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`, and an unsafe cuBLAS
precision override. Failures must remain readable and must not select another backend or run CPU inference.

For each measured workload record cold load time, warm median/p95 query latency, indexing throughput, peak memory,
input corpus and sample count. Capture a warm-up separately and retain at least 30 warm query measurements. Do not
claim a speedup from architecture targets, successful compilation or a CPU-only hosted runner.

The installer check validates app-local CUDA dependencies, hashes, clean-PATH startup, removed NVIDIA Vulkan and
replacement of obsolete runtime files. Native contract tests use simulated discovery; those do not establish GPU
execution. Physical CUDA acceptance remains pending until the matrix above has evidence.
