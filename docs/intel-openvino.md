# Intel OpenVINO setup and validation

This change adds an explicit `openvino-gpu` backend for Intel integrated graphics and supplies the runtime/setup
missing from the earlier NPU installer. It depends on PR #22's launcher/Control Panel work.

The flow under test is: Settings → choose Intel backend → inspect runtime/device → prepare or choose model →
preflight → restart → verify the selected hardware → index. Name matching and native launching stay independent.

## Automated coverage

- Real Python/OpenVINO package imports from the installed, relocated environment with developer paths removed.
- Native helper metadata discovery through the bundled Python, without model weights or inference.
- Strict GPU/NPU target selection, stable identity/reordered devices, missing pins, CPU/mixed-device rejection,
  and GPU FP32 compilation checks using fake driver objects.
- The existing tiny real text/vision/audio converter checks. Their CPU execution verifies export mathematics only.
- Model download uses a fixed repository, resolves a full revision, avoids cached credentials, keeps an explicit read-only token in the download process only, and offers a local
  checkpoint recovery for gated access. Local preparation is network free.
- Native serial/cancellable preparation, retained previous bundles, invalid revisions and managed-path isolation.
- Actual Settings page: missing-model explanation beside Apply, no Python path required with the bundled runtime,
  explicit preparation, preserved manual drafts, cancellation, separate backend pins, stale probes and native errors.
- Existing file/code search, native providers, accelerator policy, launcher and worker-lifetime regressions.

The Windows package workflow builds the private environment using pinned Python and direct dependencies, retains a
versioned package manifest and license files, and runs `scripts/check-windows-openvino.ps1` against the installed app.
Browser evidence is captured at 720 and 420 pixels in Light and Dark. Browser plugin not available; hosted Playwright
and the existing native WebView2 workflow provide the rendered checks.

## Physical gates

Hosted runners do not establish full-model inference, relevance or speed on Intel hardware. Before marking the
Ultra 7 258V NPU or integrated GPU validated, run the installed build with the actual driver and full checkpoint:

- Prepare the full model, apply each backend separately, and retain successful per-stage parity/execution receipts.
- Index text, code, image, document, mono 16 kHz audio, and video; run file/app-purpose/Windows settings searches.
- Check 768 finite normalized outputs and the unchanged 0.999 reference-cosine gate across both text profiles and
  all media budgets. Wrong-device and CPU execution must fail rather than fall back.
- Exercise idle unload, restart, concurrent foreground search, cancellation, unavailable hardware and memory failure.
- Record GPU/NPU model, driver, OpenVINO/runtime manifest, checkpoint revision, cold/warm latency and throughput.

Until those runs exist, GPU/NPU full-model compatibility, hardware generation coverage and performance remain open.
No hardware speedup is claimed from the synthetic scheduling tests or package import checks.
