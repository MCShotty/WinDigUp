# Asynchronous indexing

This change depends on PR #12 and starts from ecaf1a6. It leaves models, device selection, GPU admission, text/media profiles, prompts and vector fingerprints unchanged. Existing vectors remain compatible.

The service-level 24-file turn limit and ready-dispatch stall are addressed by [continuous indexing](continuous-indexing.md), which also documents schema 2 measurements and current validation.

## Why additional model owners could sit idle

The previous Indexer prepared one batch ahead, submitted up to the model width, then waited for the oldest result and committed it before submitting more work. A slow first job or commit prevented otherwise free inference lanes from receiving prepared inputs.

Preparation now has two owners. Up to three owned inference lanes take prepared inputs without waiting for the database owner to commit earlier results. Completed results return to the same database owner in source order, including long-document steps. SQLite connections and model scratch buffers are not shared between stages.

The total admission window covers preparation, active inference and completed results together. It contains two batches for a serialized encoder, six for two inference lanes, and eight for three. Before a model is needed, only two batches are prepared. Capacity is returned after publication and scratch cleanup, so slow storage applies backpressure instead of building an unbounded result queue. Each batch retains the existing extraction limits; audio/video scratch is still streamed to disk. This is a batch-count bound, not a promised byte or VRAM ceiling.

PDFium keeps its process-wide lock. Independent extraction never bypasses the library's thread-safety contract. Watchdog tracking retains every active reader and exposes the oldest, so completing one reader cannot clear another's deadline.

## Cancellation and failures

Pause, new sync demand and shutdown checks stay on the index owner. They stop admissions and discard uncommitted work. Started extraction and inference drain before their scratch folders or model owners are closed. A paused long-file cursor only reflects successfully committed steps.

Inference failures stop new admissions. Earlier results can commit; the failing result is reported and subsequent uncommitted work stays pending. Source identity and vector fingerprints are checked at publication. The existing memory admission, device-wide GPU job leases and foreground search holds remain authoritative. Additional threads do not create additional models or permit CPU neural work.

Metadata-only inputs do not start an encoder. The NPU and single-owner embedding paths remain serialized for inference while host preparation can overlap.

## Diagnostic measurements

Each completed or failed indexing turn emits an `index_pipeline` event. Activity snapshots and report exports retain the latest file and code measurements separately under `files.pipeline` / runtime `indexPipeline`. Sampling performs no directory or log reads.

Version 1 records:
- Preparation and inference owner counts, admission capacity and peak resident batches.
- Prepared, inferred and committed batches.
- Cumulative preparation, inference-call and publication milliseconds.
- Initial model loading, index-owner waiting, inference-lane waiting for prepared inputs, and turn wall time.

Inference-call time includes admission, foreground holds, IPC and model execution. Publication time includes source validation, database work and its progress observer. These are stage durations, not GPU utilization. Parallel totals must not be summed into elapsed time. Timing events do not displace failures from the Activity timeline.

## Validation

Tests block the oldest inference, hold the database consumer, overlap preparation, stop work with pending results, fail an encoder and check scratch cleanup. Actual Indexer tests retain stale-source rejection, vector validation, ordered publication, nested rollback and long-file resume.

The workflow compares the actual base and changed Indexer on the same macOS runner using 96 short documents, five trials, three delayed synthetic embedding owners, a fresh SQLite index and warm source-file cache. The workload introduces an occasional slow inference and a slow publication observer. Raw per-trial times, inference counts and completion gaps are uploaded alongside the comparison. At 41465d4, the hosted macOS 15 runner (three logical processors, 7 GiB RAM) measured:

| Measurement | Base ecaf1a6 | Asynchronous pipeline |
| --- | ---: | ---: |
| Median elapsed time, 96 files | 5,281.54 ms | 3,168.45 ms |
| Median throughput | 18.18 files/s | 30.30 files/s |
| p95 gap between completed files | 215.09 ms | 103.43 ms |
| Inference calls per trial | 96 | 96 |
| Peak active inference calls | 3 | 3 |

Elapsed time fell 40.0% in this scheduling fixture. Both versions used three inference owners and produced the same number of vectors. This comparison does not predict the improvement on a physical GPU.

[Raw five-trial evidence](https://github.com/MCShotty/WinDigUp/actions/runs/39036122789/artifacts/12101889979); [53 shared-engine regressions and the comparison](https://github.com/MCShotty/WinDigUp/actions/runs/39036122789). GPU admission, accelerator policy, native Windows catalog tests and browser regressions passed separately. The full Windows installer checks are still running.

These fixtures measure scheduling and persistence overhead. They do not measure physical GPU throughput, dedicated memory, media decoding speed or end-to-end foreground latency. Physical RX 7900 XTX, CUDA and Intel NPU checks remain required.

## Code review

Anti Slop code-comment check: PASS. New comments explain ownership, the admission bound and cleanup order; they do not narrate individual statements. No UI styling, interaction or visual assets changed. Performance claims above cite the retained fixture, with its synthetic-inference scope stated explicitly.
