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

## Physical acceptance

Windows RX 7900 XTX input-to-render targets remain to be measured: p95 <=50 ms for 2,000 cached app names,
<=100 ms for warm keyword search over a representative 100,000-file index on local SSD, and <=300 ms including
debounce for warm uncached semantic search over 70,000 vectors. Record 100 uncached samples, cached samples
separately, GPU/driver/model/build identity, cold startup and indexing state. Also measure 250,000 and one million
vectors, refresh memory, and CUDA/NPU regressions. Hosted and synthetic fixtures do not establish these results.
