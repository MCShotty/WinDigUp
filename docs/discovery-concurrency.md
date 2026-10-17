# Discovery and GPU concurrency

This change builds on PR #9, which includes the Windows source/discovery work from PR #8. It does not change accelerator selection, the vector model, prompts, or existing file/code index schemas.

## Physical disks own scan capacity

The shell asks the optional NTFS component for authenticated volume topology before scheduling. A volume's complete physical extent set is its resource identity. Partitions on the same disk share capacity. Multi-extent volumes conflict with every disk they overlap.

At most two scans run at once, with one scan per proven physical disk. Unknown topology, unsupported virtual/storage arrangements, and incomplete topology replies share a conservative exclusive lane. Logical drive letters never establish independence.

Both the shell and NTFS service enforce the policy. The service gate is process-wide across its bounded client handlers. The shell requires the new scheduler capability before using fast NTFS enumeration. An older installed component uses directory discovery until the component is updated; it cannot bypass the new service policy.

Metadata workers are separate from scan producers:

| Resource | Limit |
|---|---|
| Active scan producers | 2 globally, 1 per overlapping physical disk set |
| Metadata work | 4 globally; 2 per known SSD, 1 per hard disk or unknown topology |
| Queued metadata | 64 items |
| Pending scan events / metadata replies | 128 each |
| Candidate write batch | 64 items; storage API rejects batches above 256 |
| Path-resolution cache | 4,096 entries and 8 MiB per inventory owner |

The candidate database has one user-process writer. Scanners publish immutable events. Metadata workers own their file/COM work and never share a mutable SQLite connection. Writes and catalog publication are bounded. Cancellation drains owners before closing storage. Partial enumeration retains the source's prior applications.

Non-NTFS and directory fallback scans use the same metadata and commit pipeline. Automatic fallback scans are throttled; explicit rescan remains available.

## Measure the stages independently

The version-2 discovery snapshot includes a per-volume map while retaining the older aggregate fields. Counts are nullable when not observed. It reports source errors, scan mode, physical topology, last progress time, and bounded stage measurements.

Service measurements include enumeration, path resolution, access checks, and inventory commits. User-process measurements include metadata waiting, metadata reads, candidate commits, and catalog publication. Each stage has counts and cumulative/last/maximum durations with a bounded 128-sample p95 history. Durations use each process's monotonic clock.

Parallel stage durations are not summed into an elapsed estimate. Activity labels them cumulative and allows expansion by drive. Icon extraction, log reads, directory enumeration, and model inference do not happen while taking an Activity snapshot.

The reported example remains literal: **443,831 entries checked**, **107,857 executable candidates**, and **663 prepared applications** describe different stages. Candidates are not a known completion denominator. Waiting drives show unknown counts instead of zero.

### Recorded storage fixture

The same hosted Windows x64 run compared 2,000 candidate writes individually and in batches, alongside a 40,000-record inventory. These are database/path fixtures, not end-to-end drive or GPU measurements.

| Measurement | Observed milliseconds |
|---|---:|
| Individual candidate commits | 7,811.3152 |
| Batched candidate commits | 188.6556 |
| Inventory commits | 4,867.8903 |
| Path resolution | 19.1501 |
| Cached catalog read | 3.2255 |

Evidence: [concurrency workflow run 38993554517](https://github.com/MCShotty/WinDigUp/actions/runs/38993554517), job 117280952120. Its measurement artifact records the hosted CPU and disk inventory. Cache state and virtualized storage limit comparisons with a user's machine. This measurement does not establish a whole-application speedup.

## Up to three GPU operations

AMD Vulkan, generic non-NVIDIA Vulkan, and NVIDIA CUDA can admit up to three neural operations on the same explicitly selected physical device. Intel OpenVINO retains its existing serialized NPU owner; Metal keeps its existing path.

Settings → General → GPU jobs accepts Automatic, 1, 2, or 3 through the existing Apply and Restart flow. Automatic is an upper bound of three with conservative memory admission. It is not a promise that three is faster or a throughput auto-tuner. CLI processes use `DIGUP_GPU_JOBS=0|1|2|3`, where 0 means Automatic. Invalid values fail validation.

The shared admission mechanism uses OS-owned file leases instead of another long-lived broker process. Locks coordinate the native indexing, search, and command-line workers for the same user and stable physical device identity. They contain no document/query data, and the OS releases them when a worker exits or crashes. Coordination is operational and shared across isolated indexes; catalog, settings, and vector data still honor their own index/settings overrides.

There are at most three active GPU operations, regardless of how many callers exist. Foreground requests mark priority before waiting. Background work yields at the next complete operation and resumes after one quiet second. Already submitted inference completes safely. A startup mutex prevents simultaneous model-load peaks.

Up to three background model owners are created lazily, plus a resident slot reserved for the query encoder. Residency and active inference are different limits. Free device memory and actual model-weight sizes gate additional owners and reserve room for an absent query model; unavailable memory reporting allows the first owner and rejects speculative extra owners. Capacity failures reduce background pool width with a visible reason. They do not change GPU, backend, precision, or execution policy. A runtime/model failure remains an error rather than triggering a CPU retry loop.

Each child owns its context and scratch memory. Text requests can join a two-millisecond dynamic batch, bounded by 16 sequences, an 8,192-byte grouping target, and the native token-budget check. The text queue holds at most 128 calls. The native 512-token query/application-document profile and 2,048-token indexing profile are unchanged.

## Prepare, infer, commit

File extraction stays ahead of inference on its existing owner. Prepared GPU jobs use three owned serial execution lanes instead of blocking a shared executor pool. Single-owner embedders keep synchronous inference. Only immutable results cross back to the single database owner, which commits in original order.

Before publication, commits recheck source size, modification time, known physical file identity, the current database row, and the vector fingerprint. Changed sources stay pending for resynchronization. Incompatible configuration changes cannot publish old vectors. A failed later job does not erase already committed work, and long-document cursors advance only with their transaction.

File and code demand use bounded 24-file turns. Application and Windows-settings documents stay incremental and use expiring atomic claims; two consumers cannot embed the same current document at once. Unchanged text and icon-only refreshes preserve vectors and live claims. Removed or changed documents invalidate stale work.

Every prepared vector must contain 768 finite values and satisfy the existing normalization tolerance. Host validation, tokenization, I/O, and similarity scoring remain on the host. Neural arithmetic, pooling, and normalization stay on the selected accelerator.

## Interface behavior

Activity now has stable per-drive rows, separate stage measurements, and GPU work states. Running/waiting labels derive from worker receipts. Missing occupancy is unknown; there is no invented GPU utilization or speed estimate.

Apps settings keeps drive choices across focus/progress changes, disables stale candidate actions as soon as the filter changes, and rejects older settings revisions. Each source has independent busy state and feedback. Candidate pages retain row identity and keyboard focus while progress arrives. First run, no matching name, no review-needed entries, unavailable catalog, and failed discovery have different explanations.

System/Light/Dark preference is stored atomically through the native settings path and broadcast to every view. App placement, launch IDs, file/code previews, copying, dragging, and model-independent name search retain their existing contracts.

## Validation and remaining hardware gates

Automated checks cover disk conflicts and independence, metadata limits, cancellation, partial discovery, real NTFS permissions, admission cleanup after process death, foreground priority, three isolated fake embedders, ordered persistence, stale sources, document claims, native settings contracts, and actual rendered browser interactions.

Synthetic unit vectors establish ownership and protocol behavior. They do not establish GPU execution, relevance, memory fit, or throughput. The Windows installed-package workflow exercises application launch/lifetime, NTFS/portable discovery, indexing, search recovery, and CPU rejection.

### Run on a physical GPU

Stop DigUp and other benchmark workers before running a comparison. Use an installed helper, real model weights, and the exact stable ID returned by `digup accelerator --list --json`.

```powershell
python scripts/benchmark-gpu-concurrency.py --helper "C:\Users\you\AppData\Local\DigUp\helper\digup.exe" --models "D:\DigUpModels" --backend amd-vulkan --gpu "<stable-id>" --output "D:\DigUpEvidence\full" --profile full2048
python scripts/benchmark-gpu-concurrency.py --helper "C:\Users\you\AppData\Local\DigUp\helper\digup.exe" --models "D:\DigUpModels" --backend amd-vulkan --gpu "<stable-id>" --output "D:\DigUpEvidence\queries" --profile query512
```

The harness compares 1/2/3 workers with batch sizes 1/8, records receipts and raw latency distributions, validates finite normalized output, and requires cosine agreement ≥0.999 with its first single-worker run. That comparison is not the retained reference corpus. CUDA still requires `check-cuda-hardware.ps1` and the retained text/media reference checks. The protocol reader accepts bounded interleaved Activity events without treating them as vector replies.

Record dedicated GPU memory with a supported vendor tool; the harness leaves unknown memory null. Record installed-app foreground latency while discovery and preparation run separately from worker-only measurements.

Physical acceptance remains required on the RX 7900 XTX, a supported NVIDIA RTX device including the minimum generation, Intel Ultra 7 258V NPU regression, low-memory and missing-hardware cases, and representative multi-disk storage. No threefold speed claim or device-validation claim follows from hosted tests.
