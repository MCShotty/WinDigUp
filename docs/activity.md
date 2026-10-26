# Activity and diagnostics

**Last search** reports local input-to-render time and the available typing-pause, helper queue, model-startup,
encoding, retrieval, metadata and rendering durations. Each process measures its own monotonic durations; total
latency is measured in the UI. Up to 200 numeric samples are included in diagnostic exports, without query text or
result paths. Cached queries are identified separately. These measurements do not imply GPU utilization or a
completion estimate.

Open **Activity** from the search window's bottom status button or the **Activity**
tab in Settings. On a wide window it replaces the result preview; on a narrow window
it uses the available width. Close it to return to the same query and result selection.

**Discovering files** means the crawler is still walking the chosen folders. Entries
checked includes filesystem entries; candidates are preliminary until exclusions and
queue reconciliation finish. A first index can therefore have no searchable files yet
while discovery is making progress. An existing index remains searchable during a rescan.
Unknown totals have an indeterminate indicator. A known indexing queue shows completed
files separately from remaining pages/chunks of long documents.

The Windows app catalog and application-purpose vectors are separate. App names and
launching work without file folders, model files or usable inference hardware. Prepared
vectors can remain cached when the query encoder is idle. The configured backend is
shown separately from the most recently verified accelerator-only runtime/device.
“Verified” reports execution evidence, not current GPU/NPU utilization.

**Diagnostics** shows independent provider health and a bounded timeline of significant
events. Routine scan counters and embedding progress do not evict important events.
The view reads native memory; it does not wait behind the model or read log files.
Open **Technical details → Preview diagnostic report** to load bounded log tails and
build/worker information. Paths are hidden by default in the preview. Review the text
before sharing; turn redaction off only when the full paths are useful. Export uses the
Windows/native Save As dialog and writes exactly the text being previewed. DigUp does
not upload diagnostic reports.

In **Settings → Apps**, search the Visible/Hidden/All catalog and select one app to
edit its aliases, purpose or hidden state. Unsaved drafts stay in this window while
switching applications, changing filters, refreshing the catalog or receiving progress.
Save persists one app; Revert discards that app's draft; Reset overrides restores its
Windows metadata and visibility. Closing Settings discards unsaved drafts.

The Activity UI changes no model backend, launch identity or index schema. CPU inference
fallback remains disabled. Native metadata, scanning and ordinary UI/storage work still
run on the host CPU.
