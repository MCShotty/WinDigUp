# Windows application search

Press Ctrl+Shift+Space and type an application name. Relevant applications appear in an **Apps** group before file
results. Enter or double-click launches the selected application. Use `apps: photoshop` to search only applications,
or choose **Apps** in the larger window. `apps:` by itself lists the catalog alphabetically; Show All/Show More opens
the remaining matches. Ctrl+8 selects the Apps filter. Existing file/code filter shortcuts retain their meanings.

Names and aliases work without model files, selected folders, an accelerator or a running file-search helper. On first
launch, **Open app launcher now** completes setup without choosing folders or waiting for a model. The existing model
download can continue in the background. Folder and code choices already made are saved before opening the launcher.
File search can also be configured later.

The Windows file scanner skips child directory junctions and symbolic links, so a link back to a parent cannot keep
the first scan running repeatedly. While files are being discovered, the status says **Scanning folders…**. If the
launcher opened while model verification was pending, it resumes encoder warm-up and purpose queries when the model
becomes ready. Empty `apps:` listings still run without inference.

## Indexing diagnostics and recovery

**Settings → Folders → Indexing diagnostics…** (also available in Apps) shows the running build, saved folders,
selected accelerator, scheduler blockers, helper PIDs, current scan stage, app preparation state, and bounded local
log tails. **Copy report** copies it; if Windows denies clipboard access, the report is selected for Ctrl+C. Review
the report before sharing: it includes local file/folder names. It does not start inference or scan folders, so it
also works when a helper is stalled. Logs rotate at about 1 MiB, retaining one previous file.

Worker exits, startup failures and synchronization errors remain visible instead of returning to “0 files indexed.”
A successful empty scan shows why files were skipped (unsupported types, cloud placeholders, excluded folders, and
other crawl rules). Scan progress reports checked entries and candidates before embedding begins. **Index now**
retries using the existing saved choices; model errors still require fixing the selected accelerator.

App preparation uses an already-running query encoder and pauses when it becomes idle. **Prepare purpose matching**
explicitly starts the selected encoder without a file search. The Apps status distinguishes an idle encoder from
an unavailable accelerator and from preparation progress. It never enables CPU inference.

The earlier junction fix did not resolve the reported RX 7900 XTX zero-index issue. These diagnostics are needed to
establish the remaining cause on that installation; a hosted fixture passing is not evidence that this device-specific
report is resolved. Hosted checks include a 4,000-file mixed tree without inference and an installed one-document
indexing flow with synthetic unit vectors. Real model indexing on the affected installation remains unverified.

A separate scanner stall was reproduced with a named pipe ending in `.ts`: media header inspection happened before
the regular-file/cloud-placeholder checks. Those checks now precede inspection for `.ts`, `.mts` and `.m2ts` so special
files cannot block this read and offline files are not opened to sniff media content. Regression fixtures cover a
pipe, ordinary video/document files, and the Windows offline attribute. The pipe reproduction establishes a scanner
defect; it does not establish which file or phase is blocking the reported Windows installation.

## Windows supplies the catalog

DigUp reads Windows Shell's AppsFolder and the current-user/shared Start menu Programs folders using Windows APIs.
This covers registered desktop and packaged applications. A portable application is included when it has a Start menu
shortcut. DigUp does not scan drives for executables or require Windows Search's content index.

Shortcuts remain shortcuts when launched, preserving arguments and working directories. Entries with different launch
arguments stay separate. Windows handles packaged applications and activation of an already-running app. An accepted
Shell request does not guarantee that the application itself successfully rendered a window.

Apps launched from DigUp have their own lifetime: closing, restarting or updating DigUp does not terminate them.

The catalog refreshes at startup, from Shell change notifications, when a stale launcher is opened, and from
**Settings → Apps → Refresh applications**. A source that temporarily fails retains its previous entries. Missing
applications produce a launch error and trigger a refresh.

Names and stable launch identities are published before optional publisher/description properties are read. The
previous metadata stays available during that refresh, avoiding needless embedding invalidation. Disabling discovery
stops the scan between entries; enabling it again schedules a refresh. Icon extraction and launching use independent
execution paths.

## Purpose matching

With **Match applications by purpose** enabled, try descriptions such as “retouch a portrait.” DigUp embeds the app's
name, available Windows description, aliases and user-supplied purpose using the selected AMD/NVIDIA Vulkan GPU or
Intel OpenVINO NPU. Names appear first; semantic suggestions supplement them after the model answers. Exact names and
aliases retain priority. Selecting a result with the keyboard or mouse preserves it as later results arrive.

Windows descriptions can be sparse. In **Settings → Apps**, add aliases or a purpose description, or hide an entry.
Empty overrides restore Windows metadata. Up to 16 aliases of 80 characters and a 1,024-character purpose are accepted.
Unsaved edits survive a Settings focus refresh. Turning off purpose matching retains name matching and launching.

Application embedding reuses the existing 512-token text encoder, one document per idle background request. It never
loads a second model solely for catalog preparation or synchronously embeds the whole catalog during a query. Neural
inference, pooling and normalization remain on the configured accelerator; failures never select CPU inference. OS
calls, name matching, tokenization, storage and similarity scoring use the host CPU, as in the rest of this fork.
See [accelerator setup](acceleration.md), including the separately prepared model bundle required by OpenVINO NPU mode.

The initial semantic gate is cosine >= 0.60 and within 0.08 of the best match, ranking version 1. These are **provisional,
uncalibrated defaults**. Unit/browser tests do not establish real-model relevance. Physical AMD/NVIDIA/NPU inference
and purpose-search quality must be measured before calling this feature hardware-validated.

## Data and compatibility

- `<base-index>/applications/catalog.json` and `icons/` contain the disposable native catalog and icon cache.
- The existing Settings file holds aliases, purpose descriptions and hidden entries.
- `<effective-index>/applications.sqlite` contains app documents and vectors. The effective index follows the current
  accelerator rules, including the separate OpenVINO NPU directory.

Model/runtime/precision/backend/prompt/profile fingerprints prevent incompatible vector reuse. Changed descriptions
invalidate their own vectors; icon-only changes do not. The application cache has its own schema and never migrates
or rebuilds the file/code indexes. Corrupt application SQLite caches are rebuilt without touching those indexes or
Settings. `--index` and `--settings` isolate development/test data. All application metadata stays local.

## Validation

Portable catalog/ranking fixtures and a 2,000-entry cached-name benchmark:

```sh
cargo test --release --manifest-path tests/applications/native/Cargo.toml --locked -- --nocapture
```

Swift cache/policy checks:

```sh
swift test --filter 'AccelerationTests|ApplicationStoreTests'
```

The portable tests also exercise the real helper transport with a deliberately blocked subprocess pipe, concurrent
reply IDs and a restart. Native app-name requests and shutdown remain independent of that pipe. A corrupt-catalog
fixture checks that annotations survive recovery/reinstallation and icon changes leave embedding text unchanged.

The UI checks run the actual panel, window, Settings and setup pages in Chromium. They cover a blocked helper,
application-only routing, name/semantic merging, model-ready resumption, saved setup choices, stable selection, pagination, launch IDs, file-only actions and Linux
behavior. The Windows installer check compiles a disposable GUI target, registers its own Start menu shortcut,
launches it from the installed DigUp window, verifies Unicode arguments/working directory, and checks that it survives
DigUp exiting. It cleans up its own shortcut and process. Packaged-app activation still needs a real Windows check.

The installed Swift service also runs `scripts/check-app-protocol.py` with an explicitly synthetic worker (unit
vectors, no neural inference). It verifies one-document background steps, query-cache reuse, persistent fingerprints,
changed-runtime invalidation and rejection of CPU device proof. These protocol checks do not validate an accelerator.

On a machine with model files and the configured accelerator, evaluate synthetic app-purpose fixtures through the
real strict helper:

```powershell
$env:DIGUP_ACCELERATOR = 'amd-vulkan' # or nvidia-vulkan / openvino-npu with its documented configuration
python scripts/check-app-semantics.py --helper "$env:LOCALAPPDATA\DigUp\helper\digup.exe" --output app-relevance.json
```

The report records device/execution proof, the full embedding fingerprint, query results, precision, recall@3, negative
false positives and candidate thresholds. Its acceptance gate is precision >= 0.95, recall@3 >= 0.80 and negative-query
false-positive rate <= 0.05. It exits unsuccessfully if the current gate fails or the accelerator is unavailable;
there is no CPU evaluation fallback. A threshold recommendation does not change application code automatically.
The synthetic suite is an initial calibration aid; supplement it with varied real app catalogs and held-out queries.

The UI target is cached app-name results rendered within 50 ms at p95 for 2,000 apps on a recorded reference Windows
machine. Native benchmark output measures backend time only. Report actual end-to-end results separately; no model
performance or hardware relevance result is implied by hosted CPU-only CI.

Development measurement (2026-10-15): the release native fixture reported **2.18 ms p95** for cached name matching over
2,000 entries on a Linux x86-64 container backed by an AMD EPYC 9V74 CPU. This excludes Tauri IPC and rendering and is
not the required reference-Windows end-to-end measurement.

Windows hosted measurement (2026-10-15, commit `a1301b2`): **5.11 ms p95** for the same release native fixture on
Windows Server 2025 x64 / AMD EPYC 7763 with four logical processors. The
[workflow log](https://github.com/MCShotty/WinDigUp/actions/runs/38750128191/job/116474039374) records the machine and
timing. This is also backend-only; the separate transport test in that run exposed a subprocess startup timing
assumption that was subsequently corrected to wait for a ready signal.
