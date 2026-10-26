# Search storage and availability

This stage starts from main 4aa0e494. It preserves vector dimensions, fingerprints, semantic relevance rules and accelerator-only execution.

## Delayed filesystem evidence

The actual SearchService.fileSearch path called fileExists synchronously for exact-name collision candidates and returned hits. With three explicitly injected 200 ms probes, the baseline search took 690.04 ms on the hosted macOS runner. This establishes that a slow probe blocks the search owner; it is not a measured network-drive or physical Windows delay.

Baseline evidence: [run 40408142396](https://github.com/MCShotty/WinDigUp/actions/runs/40408142396), commit eb46354.

## Advisory availability

Search now requests availability through a per-helper memory cache. Two background owners admit at most 256 queued probes and retain at most 4,096 observations. A blocked filesystem call occupies one of those two owners; it cannot create more threads or block a search queue. Shutdown discards queued work without waiting for an operating-system filesystem call to return.

Available observations expire after five seconds; unavailable observations after two. Expired and unobserved entries report unknown. Fresh unavailable entries are omitted from hits; unknown entries remain useful while a drive wakes or reconnects. Exclusions and selected-root checks apply before admitting a probe. Folder-configuration changes discard old queued observations, and an older in-flight probe cannot republish into the new epoch.

Each hit carries availability, availability_stale and, when known, availability_checked_ms_ago. Unknown is advisory and never grants access. Native open actions must recheck the actual file before dispatch and report a readable unavailable error. A cached result is not proof that a path still exists or can be opened.

The search ms object reports availability lookup time; the separate availability_checks field reports lookup count. Status reports bounded queue/cache counts and measured background probe durations without paths or query text. These counters are not disk utilization or an inference measurement.

## Scale protocol

The existing benchmark-search-scale.py supports explicit --vectors values and retains raw roundtrip samples. Run:

    python3 scripts/benchmark-search-scale.py --helper .build/release/digup --vectors 100000 250000 1000000 --samples 100 100 100 --output search-scale.json

The workflow builds the actual release helper on Linux and measures 100,000 metadata rows, 200 existing tiny files and constant 768-dimensional synthetic vectors. It records refresh time, keyword latency during refresh, retrieval roundtrips, helper RSS, phase timings, binary/source identities and host details. It loads no neural model. This tests scoring and refresh work, not model quality, GPU/NPU speed, UI latency or a representative million-file corpus.

Physical Windows SSD/HDD/network/disconnected-drive measurements remain required. No ANN index, incremental vector publication or production model change follows from synthetic scale results alone. Those require separate evidence and relevance acceptance.
