# Search storage and availability

This stage starts from main 4aa0e494. It preserves vector dimensions, fingerprints, semantic relevance rules and accelerator-only execution.

## Delayed filesystem evidence

The actual SearchService.fileSearch path called fileExists synchronously for exact-name collision candidates and returned hits. With three explicitly injected 200 ms probes, the baseline search took 690.04 ms on the hosted macOS runner. This establishes that a slow probe blocks the search owner; it is not a measured network-drive or physical Windows delay.

Baseline evidence: [run 40408142396](https://github.com/MCShotty/WinDigUp/actions/runs/40408142396), commit eb46354.

## Advisory availability

Search now requests availability through a per-helper memory cache. Two background owners admit at most 256 queued probes and retain at most 4,096 observations. A blocked filesystem call occupies one of those two owners; it cannot create more threads or block a search queue. Shutdown discards queued work without waiting for an operating-system filesystem call to return.

Available observations expire after five seconds; unconfirmed negative observations after two. fileExists=false conflates absent, inaccessible and offline paths, so every negative remains unknown and never suppresses a hit. Expired and unobserved entries also report unknown. Reconciliation removes confirmed deleted entries; cached results remain useful while a drive wakes or reconnects. Exclusions and selected-root checks apply before admitting a probe. Folder-configuration changes discard old queued observations, and an older in-flight probe cannot republish into the new epoch.

Each hit carries availability, availability_stale and, when known, availability_checked_ms_ago. Unknown is advisory and never grants access. Native open actions must recheck the actual file before dispatch and report a readable unavailable error. A cached result is not proof that a path still exists or can be opened.

The search ms object reports availability lookup time; the separate availability_checks field reports lookup count. Status reports bounded queue/cache counts and measured background probe durations without paths or query text. These counters are not disk utilization or an inference measurement.

## Scale protocol

The existing benchmark-search-scale.py supports explicit --vectors values and retains raw roundtrip samples. Run:

    python3 scripts/benchmark-search-scale.py --helper .build/release/digup --vectors 100000 250000 1000000 --samples 100 100 100 --output search-scale.json

The workflow builds the actual release helper on Linux and measures 100,000 metadata rows, 200 existing tiny files and constant 768-dimensional synthetic vectors. It records refresh time, keyword latency during refresh, retrieval roundtrips, helper RSS, phase timings, binary/source identities and host details. It loads no neural model. This tests scoring and refresh work, not model quality, GPU/NPU speed, UI latency or a representative million-file corpus.

Physical Windows SSD/HDD/network/disconnected-drive measurements remain required. No ANN index, incremental vector publication or production model change follows from synthetic scale results alone. Those require separate evidence and relevance acceptance.

## Explicit shell selection

The native shell attaches a versioned file_scope to each search from the current selected roots, exclusions and file types. The helper uses that scope immediately, even when a queued folders-control message has not arrived yet. Empty shell selection returns no file results without requesting inference. A scope edit during a pending search discards its older reply; code requests use their separate code-root selection.

Folder changes notify both search views. They invalidate and clear file rows immediately while retaining the independent app/settings providers and any selected launcher result. Explicit Apps and Windows settings browsing and empty unfiltered home routing retain their existing behavior.

An omitted file_scope keeps the developer helper/CLI convention of searching the loaded index when no roots were supplied. A malformed or unknown explicit scope fails closed. This distinction prevents an installed app with zero selected folders from exposing retained rows without changing developer CLI behavior.

Scoped helper replies acknowledge file_scope_version=1. Native search rejects a successful reply from a helper without that acknowledgement; superseded/status-only replies and readable errors remain available. Empty native selection short-circuits before the helper. An older helper therefore cannot silently ignore the selection contract.

## Names during streamed discovery

The native backend sends refresh_names after committed scan batches. This operation schedules a background name/kind snapshot without requesting the encoder or vector loading. Active search generations are unchanged. Multiple pending refreshes coalesce; an already loaded vector snapshot is retained, and a trailing names refresh does not implicitly request a full vector rebuild. Explicit vector reload requests still retain their independent pending flag.

A service regression holds an actual scanner at its next folder while a pre-existing SearchService reads committed name rows. It exercises file-kind filters, exact filename collisions, request generation echoing and a stopped encoder. A separate warm-vector regression floods metadata refresh requests and checks that the retained vector revision is not replaced. These deterministic checks establish protocol and ownership behavior; installed Windows time-to-first-result remains a physical validation gate.

## Refresh queue profiling

[Two repeated scale rounds](https://github.com/MCShotty/WinDigUp/actions/runs/40421535567/artifacts/12699080515) reproduced the initial refresh outlier. The 100k-vector keyword maxima were 439.73 ms and 218.99 ms; helper queue time accounted for 438.62 ms and 217.79 ms, while search itself took 0.62 ms and 0.77 ms. Larger scales had 55.98–66.90 ms maxima, again mostly queue time. These are hosted Linux synthetic measurements with an AMD EPYC 9V45 CPU, about 16 GB host memory and Swift 6.4, not installed Windows or neural throughput.

The original retirement closure and its lexical caller both retained the old name snapshot. Whichever released last could destroy its large dictionary; simply dispatching a copied strong value did not guarantee background destruction. Publication now transfers the old references into a container, replaces the owner's properties, then explicitly clears the container on the retirement task. A deterministic tagged-queue destructor regression keeps the lexical job/container alive until the worker has disposed its contents. Name loading and pointer-publication timings are recorded separately. Subsequent scale runs must retain all outliers; this change does not justify approximate retrieval or a vector-index rewrite.

## Nonblocking refresh handoffs

Concurrent service tests exposed loader workers waiting on semaphores for publication jobs queued to the same global utility pool. In run 40423969547, availability probes had not started, metadata publication exceeded its unchanged five-second deadline, and the concurrent cached-vector fixture took about 5.4 seconds. The standalone suite passed; running the separate suites concurrently exposed the ownership cycle.

Refresh now transfers work through loader, lexical and retrieval continuations without waiting on another lane. One ticket owns the active refresh and one coalesced request retains the newest intent. Every stage checks its ticket; shutdown invalidates it, and cancellation completes the matching refresh without affecting a newer one. The memory gate still drains and releases the old retrieval snapshot before building a replacement when both would exceed budget. Read-only vector transactions remain pinned through publication, and metadata/retirement ownership remains serialized.

The stress fixture holds two availability probes while four actual search services refresh committed metadata and complete every control/search reply. It keeps the original deadlines, runs alongside the other suites and does not start an encoder. Combined acceptance separately holds an actual scanner at its next folder. These tests validate ownership and responsiveness under controlled blocking, not physical-drive or accelerator performance.
