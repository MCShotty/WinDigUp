# Windows application search

Press Ctrl+Shift+Space and type an application name. Relevant applications appear in an **Apps** group before file
results. Enter or double-click launches the selected application. Use `apps: photoshop` to search only applications,
or choose **Apps** in the larger window. `apps:` by itself lists the catalog alphabetically; Show All/Show More opens
the remaining matches. Ctrl+8 selects the Apps filter. Existing file/code filter shortcuts retain their meanings.

Names and aliases work without model files, selected folders, an accelerator or a running file-search helper. On first
launch, **Open app launcher now** completes setup without choosing folders or waiting for a model. The existing model
download can continue in the background. File search can be configured later.

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
application-only routing, name/semantic merging, stable selection, pagination, launch IDs, file-only actions and Linux
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
