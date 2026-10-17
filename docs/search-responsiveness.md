# Search responsiveness

This work depends on PR #6 (`codex/nvidia-cuda`, base `81ca3d5`).

## Scheduling baseline

Before scheduling changes, `scripts/check-search-responsiveness.py --baseline` ran the real Swift service with
explicitly synthetic unit vectors and a 750 ms delayed test worker. On the Linux x86-64 development container,
the concurrent keyword request waited **754.25 ms**, thirteen encoder calls executed (one active plus twelve
newer typing generations), and zero requests were superseded. This demonstrates head-of-line blocking and stale
work; it is not a neural inference benchmark or physical accelerator validation.

Run the same workload after changes without `--baseline`; the keyword request must complete within 250 ms while
the encoder is occupied, at most three encoder calls may run, and superseded requests must receive replies.
The raw measurement can be saved outside the repository with `--output report.json`.

The same development workload after the change returned keyword results in **2–4 ms** across repeated runs, executed
two encoder calls, and completed twelve superseded requests explicitly. These are host scheduling measurements with
an empty file index and delayed synthetic unit vectors, not Windows end-to-end latency or model throughput.

## Execution and recovery

Keyword reads, inference, semantic retrieval, maintenance, snapshot construction and previews have separate bounded
owners. The input reader never waits for preview capacity. A session retains one pending query generation; panel and
window sessions have native-issued instance IDs. File and app-purpose queries share a 256-entry LRU keyed by the full
model revision, runtime, backend, precision/build identity and actual query prompt/profile. Code remains distinct.
Queued previews carry the current generation, so old thumbnails complete as superseded before rendering. A newer
request never reuses an obsolete pending preview; completed images remain cached. Folder summaries use maintenance-owned
readers and cached counts between SQLite data revisions, while folder availability is checked again on each request.
Ordinary result metadata is hydrated in two bounded SQL reads for the selected candidate set. Code definition lookup
retains its existing bounded behavior. File availability and exclusion checks remain enforced before publication.

The native encoder runs in its own persistent worker, preserving accelerator-only execution. Startup has a 180-second
deadline and each 512-token query/app-document request a 60-second deadline. A timeout or worker failure is persistent
until an explicit retry/restart. Keyword reads and native app launching remain available. Indexing/reference workers
retain their own budgets. Timeout and shutdown termination target the model child only; launched applications retain
their independent Windows Shell lifetime.

Foreground inference renews a two-second indexing lease; after one second without foreground work, renewals stop.
Each indexing inference boundary checks the lease. App preparation remains one document per background step and never
wakes an idle encoder. Passive refreshes neither reset the five-minute idle deadline nor overwrite user-query timing
with time spent reading an unchanged results page.

Read-only SQLite connections skip migrations and WAL negotiation. A background builder publishes complete vector and
metadata read transactions together, serves the prior snapshot meanwhile, and retains ownership until publication.
There is one builder plus a coalesced refresh request. Estimated overlap includes vector and file/name metadata;
the budget is one quarter of host RAM capped at 4 GiB. Under pressure, readers drain before replacement. An oversized
snapshot reports an error and preserves keyword search. Read transactions are released on replacement/idle unload;
while indexing, refresh notifications normally arrive at most every three seconds.
Old filename caches retire on a utility thread after the serial ownership handoff. Portable similarity scoring uses
a runtime-gated F16C conversion on compatible x64 CPUs, checking both CPU features and OS AVX state. Other hosts use
a portable conversion. Both paths preserve every finite half-float bit pattern; the neural pipeline is unchanged.

The exact-filename cache is built in the background across indexed names. Mixed-result ordering now preserves exact
file/app/settings collisions together using shared match classes; it no longer waits for collision metadata before
showing native names. See [mixed-result ordering](mixed-result-ordering.md). File/code schemas and embedding fingerprints
are unchanged.

## Automated checks

`scripts/check-search-responsiveness.py --helper PATH` exercises the installed/real helper transport, a blocked and
crashed synthetic encoder, superseded requests, shared file/app queries, persistent failures, keyword recovery,
foreground lease renewal/expiry and idle unload without passive model wake. It loads no neural model.

`swiftc Sources/digup/SearchWorkQueue.swift tests/native/search-queue.swift -o queue-check` tests bounded preview
admission, two active render jobs, independent keyword work and explicit completion of displaced jobs.
Swift tests cover read-only revision consistency, concurrent writes, combined facets and exact-name invalidation.
Native tests cover settings/annotations, timing privacy/bounds, device contracts and helper retirement. Actual-page
Chromium tests cover Apps placement, collisions, blocked providers, stale replies, stable selection/DOM/preview,
pagination, keyboard behavior, dark mode and a smaller viewport. The Browser plugin is unavailable in development.

## Supplemental host scale measurements

The Linux release-helper fixture uses 100,000 synthetic metadata rows, only 200 existing tiny files, and constant
768-dimensional unit vectors. It loads **no neural model** and measures helper roundtrips, excluding UI/debounce.
This is a reproducible retrieval/refresh workload, not representative installed-Windows latency or relevance evidence.
Reference host: AMD EPYC 9V74, 17.6 GiB reported RAM, Swift 6.2.3. The comparison starts after the queue refactor and
measures the portable conversion/cache-retirement follow-up. Raw reports include binary hashes and source identity:
[before](evidence/search-scale-before.json), [after](evidence/search-scale-after.json).

| Vectors | Uncached samples | Earlier p95 | Updated p95 | Updated peak helper RSS |
|---|---:|---:|---:|---:|
| 70,000 | 100 | 205 ms | 49 ms | 244 MiB |
| 250,000 | 20 | 682 ms | 117 ms | 640 MiB |
| 1,000,000 | 10 | 2,754 ms | 443 ms | 2,059 MiB |

The larger scales are exploratory; their smaller sample counts do not establish robust performance budgets. Keyword
roundtrips during refresh had p95 2.0–2.2 ms, with outliers up to **124 ms**. Refreshes took 2.8–6.3 seconds. These
outliers and real-world corpora still need installed-Windows measurements. No UI, GPU, NPU or model speedup is claimed.
An [independent repeat](evidence/search-scale-repeat.json) with the published script measured retrieval p95
42/128/487 ms at the three scales, with refresh-time keyword outliers up to 167 ms. Preserve these outliers when
assessing foreground responsiveness; the small p95 alone does not establish a consistently instant experience.

Reproduce on Linux after building the release helper:

```bash
python3 scripts/benchmark-search-scale.py --helper .build/release/digup --output scale.json
```

Use `--samples 100 100 100` for a longer host run. The fixture creates and removes its own temporary index; it does
not open the configured user index. Existing file/code schemas, vectors and model fingerprints need no rebuild.

After keyboard/click selection or activation, the chosen launch target (including a PDF page or code line) remains
fixed through current-query refinements. If that result disappears, selection clears instead of redirecting Enter
to another result. A new query or explicit selection uses the current results.

## Recording physical latency

Activity records up to 200 numeric phase samples and includes them in diagnostic exports without queries or paths.
For a longer semantic run, paste `scripts/benchmark-search-ui.js` into the installed search window's WebView2 DevTools
and call `benchmarkDigUpSearch` with a warm-up plus at least 100 unique, whole file queries from the retained corpus.
It waits for the rendered semantic phase, keeps cached/uncached samples separate, records the verified runtime,
indexing state and viewport, and rejects keyword-only responses or synthetic model receipts. Query text is omitted
from its JSON report. Preserve the corpus separately. Run with an already-prepared index and normal selected backend;
record GPU/driver, index size, peak memory and whether indexing was active alongside the report. Cold startup is a
separate workload. Existing app-purpose acceptance gates remain uncalibrated on physical hardware in this change.

## Physical acceptance

Hosted regression checks passed for functional revision `90c3357` on 2026-10-16:

- [Native/browser regressions and Windows command/C compilation](https://github.com/MCShotty/WinDigUp/actions/runs/38909496594).
- [Accelerator policy, model-conversion tests and Windows application discovery/launch fixtures](https://github.com/MCShotty/WinDigUp/actions/runs/38909496351).
- [Light/dark/scaled browser screenshots](https://github.com/MCShotty/WinDigUp/actions/runs/38909496594/artifacts/12049348160).

These hosted checks do not establish physical accelerator execution or real-model latency. The installer workflow
also exercises the installed helper and application; its final outcome and download are recorded in PR #7.

Windows RX 7900 XTX input-to-render targets remain to be measured: p95 <=50 ms for 2,000 cached app names,
<=100 ms for warm keyword search over a representative 100,000-file index on local SSD, and <=300 ms including
debounce for warm uncached semantic search over 70,000 vectors. Record 100 uncached samples, cached samples
separately, GPU/driver/model/build identity, cold startup and indexing state. Also measure 250,000 and one million
vectors, refresh memory, and CUDA/NPU regressions. Hosted and synthetic fixtures do not establish these results.
