# Continuous indexing

This feature depends on PR #13 and starts from 2847b57. It preserves the selected accelerator,
three-owner GPU admission ceiling, single-owner NPU path, profiles, prompts and vector fingerprints.
Existing vectors do not need rebuilding.

## Reproduced stalls

The baseline service runs a maximum of 24 files before draining its pipeline. Three eight-image
batches fill that turn. Even when another inference owner becomes free, a fourth batch cannot start
until the oldest batch finishes and the next turn starts.

A test of the actual IndexService blocks the first inference until a fourth starts. On the baseline,
the deadline expires after three calls and 24 inputs. A separate test blocks preparation of input
zero and checks that input one can reach inference. The baseline leaves it waiting.

Both expected baseline failures were observed in
[run 39056640480](https://github.com/MCShotty/WinDigUp/actions/runs/39056640480):
- SERVICE_REFILL_EVIDENCE: fourthBeforeFirstFinished=false, calls=3, inputs=24.
- READY_DISPATCH_EVIDENCE: laterReadyInputRan=false.

These tests use deterministic embedders. They establish scheduling defects, not GPU performance.

## Ownership and bounds

IndexService synchronizes selected file/code roots and then runs one shared scheduler. Priority
new-file demand leads; equally eligible file and code sources alternate. Changing source or
fetching another page does not drain inference.

Each writable SQLite connection remains on the coordinator. A connection-owned disposable TEMP
table captures eligible file IDs once, ordered by priority, kind, modification time and ID. Its
128-record pages contain metadata only. The page size is not an inference cap. TEMP data uses
file-backed storage and a bounded SQLite page cache; SQLite and the filesystem still have their own
allocations. No durable schema or file state is added for the queue.
Page queries keep the queue's rowid range as the outer loop and perform point lookups of files.
Small priority-only requests start from their membership IDs. Query-plan tests reject file-state
scans and temporary ordering on the page request path.

Two preparation owners produce immutable inputs. Inference owners take the earliest ready input
rather than waiting for an earlier extraction. Publication remains ordered on the coordinator.
The shared credit window includes preparing, ready, running and unpublished jobs:
- Before an encoder is needed: two jobs.
- One inference owner: two jobs.
- Two owners: six jobs.
- Three owners: eight jobs.

Credits return after publication and cleanup. Slow publication can therefore apply intentional
backpressure. This is a job-count limit, not a strict RSS, scratch-byte or VRAM limit. Existing
extraction limits, PDFium locking, memory admission and device-wide leases still apply.

Partial long-file work is generated one step at a time. Successfully committed cursor positions are
the resume boundary. Later admitted steps for an already-terminal file are discarded. Source
identity and embedding fingerprints are checked at publication.

Pause, stop, sync demand and foreground search holds keep their existing control paths. Work
already submitted drains before scratch or model owners are released. Failures stop admission,
wake waiters, retain pending database states and return a nonzero service status. Small new-file
demand still follows the existing 50-file policy when backfill is off. CLI --limit remains an exact
file limit.

## Measurements in Activity

Schema 2 index_pipeline samples arrive at most once per second and at the end of a session. A shared
epoch identifies cumulative counters; source IDs distinguish the file and code contributions.
Activity retains 120 samples per source in memory without reading folders or log files.
Unchanged counters do not advance the recorded progress time.

The overview shows prepared work, outstanding inference requests and unpublished results.
Expandable measurements separate queue construction/fetch, preparation, inference calls,
publication, notifications and scratch cleanup. Prepared text/path and scratch-file byte counts
describe those payloads only. They do not claim total process or dedicated GPU memory.

Inference-call time includes admission, foreground holds, IPC and runtime execution. Owner/input
waits can overlap. These counters cannot be added into elapsed time or interpreted as GPU
utilization. Native GPU-admission receipts remain the source for device-wide running/waiting jobs.

A verified indexing receipt is emitted only after a successful accelerator-only vector result.
Configuration or discovery alone cannot establish inference verification. Pipeline samples do not
evict significant failures from the Activity timeline.

## Automated comparisons

The concurrency workflow runs the actual IndexService against its baseline on the same macOS
runner, with fresh indexes, warm fixture files and three delayed deterministic embedding owners.
It alternates five paired trials each of image-only, document-only and mixed file/code workloads for the baseline and changed service. Reports retain
elapsed time, first file, completion gaps, vectors, inference calls, peak active calls and machine
identity. Equal completed work is required before comparison.

The separate 100,000- and 1,000,000-record queue fixture measures metadata construction and paging.
It is not a million-vector or million-file extraction benchmark. The measured process RSS envelope
includes SwiftPM and its children; it is not isolated helper memory or GPU memory.

Regression coverage includes ready-first dispatch, out-of-order failures, exact CLI limits, queue
paging/scopes, priority membership, file/code fairness, pause/resume without duplicate vectors,
stale-source rejection, scratch lifetime, long-file resume and original publication tests.
Browser and native panel checks are described in floating-search-ui.md.

Validation results and raw comparison artifacts are recorded in the PR when the workflows finish.
No throughput improvement is claimed until those measurements pass.


## Recorded validation

At d9daec7, [run 39062311004](https://github.com/MCShotty/WinDigUp/actions/runs/39062311004)
passed 15 scheduling/queue/service tests, three worker-deadline tests and 53 shared-engine regressions,
then exercised the actual service on macOS 15.7.9 (24G830), three logical processors and 7 GiB RAM.
The fixtures use fresh indexes, warm files and three synthetic embedding owners. They do not
establish physical accelerator throughput.

Initial runs assigned synthetic delays by request ordinal. Ready-first dispatch changes that
assignment, and hosted runs varied: one run reduced elapsed time for all three workloads, while a
subsequent run was slower for documents and mixed inputs. Those percentages are provisional.
Raw [initial measurements](https://github.com/MCShotty/WinDigUp/actions/runs/39062311004/artifacts/12112012418)
and [subsequent measurements](https://github.com/MCShotty/WinDigUp/actions/runs/39063136563/artifacts/12111839961)
are retained; neither is presented as a general speedup.

The workflow now fixes source modification times, binds text delays to input identity, gives the
identical image batches a fixed cost, alternates before/after order over five paired trials per
workload, and rejects unequal synthetic-delay totals, call counts or vector counts. Both versions
are prebuilt before timing. The final paired results are recorded in the PR.
RSS sampling includes SwiftPM/test subprocesses and is not isolated helper RSS or GPU memory.

The same run measured the disposable metadata queue:

| Metadata records | Queue construction | Page fetch total | Pages | Peak buffered records |
| --- | ---: | ---: | ---: | ---: |
| 100,000 | 55.36 ms | 79.86 ms | 783 | 128 |
| 1,000,000 | 577.98 ms | 780.93 ms | 7,814 | 128 |

Selecting two priority IDs took 0.30 ms and 0.27 ms respectively. The query-plan check observed
a file-state scan plus temporary ordering for an unconstrained join, and queue rowid ranges plus
file primary-key lookups for the production page query. These measurements cover metadata only,
not a million source files or vectors.

[Windows/native/browser run 39062310972](https://github.com/MCShotty/WinDigUp/actions/runs/39062310972)
passed the real WebView2 shell checks, application discovery/launch fixtures and browser regressions.
All twelve native theme/material/layout cases passed painted-corner checks, with no unvalidated
captures. Both native Acrylic APIs painted rectangles beyond the capsule in the regression;
Automatic now reports a Solid fallback. Actual native and labelled browser captures are retained
as that run's native-panel-evidence and activity-browser-evidence artifacts.

Accelerator-policy, strict NPU/conversion and Windows application-provider checks passed in
[run 39062310969](https://github.com/MCShotty/WinDigUp/actions/runs/39062310969).
No physical GPU/NPU throughput, retained-reference agreement or installed-device latency is
established by these hosted fixtures. Windows installer and final-commit validation are recorded
in the PR.

## Physical-device protocol

scripts/benchmark-index-service.py runs two installed helpers against the same unchanged input
folders. It requires an explicit backend/device, at least five paired trials and a new disposable
output directory outside every input root. It does not touch the user's existing index.
Quit DigUp and other neural workloads for the paired baseline; measure foreground contention separately.
Order alternates to reduce a consistent before/after bias. Content hashes detect changed inputs.
Every trial warms source data, starts a cold model process and creates a fresh index.

The harness first executes a real validation embedding on each helper and requires compatible
model/runtime/device identities. The service must finish all pending and long-file work, produce
vectors, return success and complete the same work in every trial. Raw protocol, worker logs,
receipts and measurements stay local in the chosen output directory. They can contain local paths.

For example, in PowerShell, replace the example paths and stable ID from accelerator --list --json:

    python scripts/benchmark-index-service.py --before-helper "C:\DigUp-before\helper\digup.exe" --helper "C:\DigUp-after\helper\digup.exe" --models "C:\DigUp-models" --backend amd-vulkan --gpu "STABLE_DEVICE_ID" --folder "D:\DigUp-test-pictures" --trials 5 --jobs 3 --output "D:\DigUp-measurements-new"

Repeat with document-only and mixed file/code roots (--code-root), then --jobs 1/2/3 on the GPU.
NPU comparisons require --backend openvino-npu --jobs 1 and the configured compatible OpenVINO
bundle. No backend or device fallback is permitted.

Optional psutil records process-tree RSS at approximately 100 ms intervals. Shared pages can be
counted more than once. Missing counters stay unknown. Capture dedicated GPU memory/utilization
separately with a supported vendor tool and retain GPU, driver, build and model details. The harness
does not fabricate either metric.

Test foreground searches during indexing, manual/scheduled pause, unavailable devices, low memory,
restart and unplugged roots separately. Run retained-reference/media numerical acceptance without
weakening thresholds. Physical RX 7900 XTX, representative CUDA and Intel NPU acceptance remains
unperformed by hosted fixtures.
