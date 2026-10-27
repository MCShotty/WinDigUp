# Windows settings, drive discovery and app descriptions

This change is based on `codex/search-responsiveness` at `3534b36` and depends on PR #7.
Windows 10 (19041+) and Windows 11 x64 are the supported desktop targets. Linux and macOS keep their existing providers.

## Searching and opening Windows settings

Use **Settings** (Ctrl+9 in the larger window) or type `settings: display`. An empty `settings:` lists destinations
alphabetically. Ordinary searches include up to two matching destinations in the shared Best matches/source ordering. Exact settings
names and aliases can lead file results; Apps placement preferences continue to apply to applications. Settings → Windows settings controls inclusion, purpose
matching and ordinary-search visibility independently.

The versioned built-in catalog contains 38 destinations, descriptions and aliases. Display names have English
and selected Arabic translations; this is not a complete localized Windows Search catalog. Build ranges and
known hardware fixtures filter entries; hardware detection can remain unknown, in which case the result explains
that availability depends on this PC. Windows decides whether a policy-restricted destination can open.

Names bypass the model helper. Purpose documents use `windows-settings.sqlite`, the existing 512-token profile,
the serialized encoder and the same compatible query-vector cache as apps/files. Documents remain outside the
file crawler. GPU/NPU failures leave name search and Windows activation available. Only allowlisted catalog IDs
can open an `ms-settings:` URI; query text is never converted into a URI or command line.

## Finding unregistered applications

In **Settings → Drives**, choose Applications for the desired drives, enable application discovery and save.
Choose Files independently to index supported file content across a drive. Existing subfolder selections and exclusions
are retained. Refresh drive list works before discovery is enabled. See [drive choices](mixed-result-ordering.md#drives). Volumes are
identified by Windows volume GUIDs; drive letters are labels. Discovery is off by default and has its own pause,
rescan and candidate-review controls in Review apps. Unsaved drive choices survive progress updates and focus changes.

The optional fast component reads NTFS metadata using documented filesystem controls (`FSCTL_ENUM_USN_DATA`,
`FSCTL_QUERY_USN_JOURNAL`, `FSCTL_READ_USN_JOURNAL`). It does not parse raw disk sectors. Reads proceed in bounded
batches; four bounded user-process workers identify PE files and read version resources. File records and directory
parents stay in a disk-backed SQLite inventory. A checkpoint taken before enumeration is replayed afterward.
Journal gaps, serial changes and incomplete baselines require reconciliation. Unrelated document writes advance
the checkpoint without republishing every executable.

The service preserves known hard-link launch variants and rename identities. Initial NTFS enumeration uses the
filename supplied by Windows: an executable hard link whose only enumerated name has another extension may be
missed until a relevant link change or directory fallback. This is not a guarantee to find every executable on
every filesystem. The component never creates a journal on a user's drive; absent journals use fallback discovery.
Reparse points, offline placeholders and inaccessible programs are skipped. Disconnected or failed sources keep
their last usable catalog and remain visible in Activity. A failure on one selected volume does not stop later volumes.

Install **fast NTFS discovery** explicitly from Drives settings. Windows requests administrator permission once
to register a demand-start service. Declining leaves ordinary directory discovery available. Non-NTFS volumes
use the directory provider, which is slower and does not traverse reparse points. The selected-volume controller scans at most two proven independent physical disks concurrently, with one producer per overlapping physical disk set. Metadata work and commit queues are bounded.
Foreground search temporarily holds background work; manual pause and folder schedules are separate.

Executable discovery is not an app recommendation or a trust verdict. Clear desktop products can enter the app
catalog; installers, command line tools, internal helpers and uncertain identities remain in **Needs review**.
Include/hide/reset operates on an opaque candidate ID. Inclusion does not execute the program. Accepted programs
retain their executable path and parent working directory, with no user-supplied arguments. Equivalent registered
shortcuts win so their original arguments, working directory and advertised behavior are preserved. Ambiguous
variants stay separate. Launched programs do not enter DigUp's worker job object.

The semantic preparation cap is 20,000 applications: annotated and registered apps take priority over other drive
candidates. Further accepted applications remain available by name and launching. Activity and Apps settings
report this limit; discovery candidates do not all become embedding documents.

### Machine component and user boundaries

- Protected executable: `%ProgramFiles%\\DigUpDiscovery\\digup-discovery.exe`.
- Protected metadata graph: `%ProgramData%\\DigUpDiscovery`; ordinary users cannot read this inventory.
- Authenticated local named pipe; remote clients and client-created server instances are excluded.
- Clients verify the pipe server PID against the registered service.
- The service impersonates each client before checking executable access or exposing paths.
- The service has no launch, networking, model or arbitrary-command operation.
- User-process candidate and description caches live under `<base-index>/applications/`.
- A per-user uninstall leaves the optional shared machine component in place for other users.

Administrators can unregister it explicitly by running the protected executable with `--uninstall`, then remove
its protected program/data directories after the service has stopped. Updating it uses explicit UAC, a serialized
installation lock and rollback of the previous binary on failure. A protocol mismatch asks for an update instead
of accepting arbitrary compatibility.

## Optional online descriptions

**Fetch online app descriptions** is off by default. When enabled, DigUp uses WinGet's documented JSON export to
read installed package identifiers and exact versions from the configured Microsoft community source. It does
not scrape search results, send search queries or upload local filenames. WinGet may need configuring first;
DigUp does not automatically accept source agreements.

Two bounded HTTP workers request matching version/locale manifests from Microsoft's `winget-pkgs` repository.
Both product name and publisher must match exactly after conservative normalization; ambiguous editions and
publishers are skipped. Publisher-page fallback reads static description metadata only when allowed and the
manifest is too short. Retrieved text is data, never instructions, aliases, launch targets or executable arguments.

HTTPS verification, public-address checks, pinned DNS results, redirect restrictions, response-size limits and
deadlines bound requests. Source errors remain visible and retain the last successful description. Seven-day
success / one-hour failure caches avoid repeated requests; Refresh explicitly retries. Disabling online fetching
keeps descriptions usable offline. **Turn off and clear** removes this cache while preserving aliases, hidden
entries and personal purpose notes. Personal notes take priority over fetched text.

Descriptions carry an attributed source button. The provider receives the product URL and the requesting IP;
publisher pages may also receive a request. The controls explain this before opt-in. Network work never runs on
the search request path, and foreground typing holds new background preparation.

## Storage and recovery

The native catalog, executable candidates and descriptions share the base index's applications directory.
Model vectors stay scoped by the selected accelerator in `applications.sqlite` and `windows-settings.sqlite`.
Icon/source timestamp changes do not invalidate document text. Purpose changes do. Existing file/code indexes
and their schemas remain intact.

`--index` is the base directory and is scoped once by the engine. A custom `--settings` without `--index` now
selects a deterministic adjacent `.digup-index-<settings-path-hash>` development directory, preventing accidental
writes into an installed catalog. Supplying both flags controls both explicitly. Cache recovery removes only the
damaged disposable store and its WAL/SHM files, preserving settings annotations and unrelated indexes.

## Evidence and remaining gates

Automated native tests cover catalog/ranking namespaces, USN V2/V3 parsing, path graphs, rename identities,
hard-link variants, bounded inventory, partial refresh retention, conservative classification, metadata identity,
untrusted YAML/HTML, URL restrictions, cache persistence and custom settings isolation.

Actual-page Chromium tests cover both search views and the settings editor, stalled inference, stale replies,
Windows settings routing, progressive results, draft preservation, candidate review, opt-in/clear behavior and
independent measured Activity counters. Swift store/protocol tests use synthetic vectors to establish separation,
one-document background steps and shared query-cache reuse; they do not establish semantic relevance.

The Windows workflows build a real disposable GUI fixture and an isolated NTFS VHD. The component test exercises
real filesystem controls, Unicode names, renames/hard links, standard-user access filtering and component updates.
The installed-app check additionally verifies portable application dispatch and lifetime outside DigUp's workers through both the NTFS service and unprivileged directory fallback.
Workflow results must pass on the exact reviewed commit before these checks are reported as successful.

Physical Windows 10/11 page activation, large SSD/HDD inventories, CPU/RAM/I/O measurements and full-model
purpose quality on the RX 7900 XTX, RTX CUDA and Ultra 7 NPU still require device validation. Hosted Windows Server,
synthetic vectors and browser fixtures do not establish those results. No latency, throughput or semantic-quality
claim is made without those measurements.
