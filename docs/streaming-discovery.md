# Streaming discovery and incremental reconciliation

This stage starts from merged main 4aa0e49. File/code schemas, neural profiles, fingerprints and accelerator policy remain compatible.

## Discovery and database ownership

The scanner publishes immutable batches of at most 64 candidates through a four-message channel. Each scanner owns a separate disposable SQLite TEMP spool for candidates, seen paths and pending directories. Windows uses a single-directory native cursor rather than retaining a complete child list. These bounds cover scanner-owned queues and metadata; they are not a strict process RSS bound for SQLite or OS/framework allocations. Metadata read connections, model contexts and the index writer are never shared. File and code scans serialize directory work through a common gate; a slow source does not hold foreground search or another ready inference source.

Documents, screenshots and explicitly selected media folders can publish immediately. Other media waits for its folder's dataset classification. Dataset, project, secret, cloud-placeholder, reparse-point and git-ignore behavior remains part of the admission path. Selected roots retain their existing dataset exemption during targeted subtree scans.

The coordinator owns an independently disposable scan session: original IDs, seen paths, deferred identity candidates and paged eligible IDs. Exact-path metadata and names commit incrementally. Identity moves require one old source and one new destination; ambiguous hard-link variants remain separate. Source metadata and fingerprints are checked again before vector publication.

Only successful scan completion can remove unseen rows. Unreadable subtrees and roots that disappear retain cached entries. Cancellation drops transient scan state without deleting old rows. Canonical root spellings are captured before scanning, so a disappearing aliased root is still protected.

A live pending queue distinguishes temporarily empty input from completed discovery. The existing bounded preparation/inference pipeline continues as new metadata arrives. When backfill is disabled, discovery still publishes names, but the service waits for final demand before applying the existing 50-file immediate-index policy.

## Changes and priority

Native watcher events retain both paths of a rename and coalesce affected paths. The accumulator is bounded by 1,024 paths and 256 KiB; overflow and watcher errors request a full-root reconciliation. File quiet time remains two seconds; code quiet time remains one minute with a ten-minute maximum.

The helper accepts bounded JSON changes commands while keeping legacy sync and sync code. Ordinary changes reconcile their parent subtree. Ignore-rule, project-marker and ambiguous changes request the configured root. Unavailable paths are preserved; successful parent scans remove deleted files. The privileged application-discovery service is unchanged and no filesystem journal is created.

Index this first queues one preference per file/code source. It is applied between complete batches, not by interrupting submitted inference. Other ready sources receive a turn after at most eight consecutive batches. The choice does not resume paused indexing or override schedules and survives worker restarts during the current application session.

## Status and verification

Discovery-active snapshots have no completion percentage or known total. Names committed, content-ready files and pending work remain separate. The installed app can continue name search and launching while neural inference is unavailable.

The Swift suites cover filtering equivalence, early batches, partial roots, rename ambiguity, live input, queue cursors, source independence and bounded cancellation. Native tests cover coalescing, overflow, rule changes and status contracts. Exact workflow results are recorded in PR 19.

These are software and synthetic-embedding checks. Physical RX 7900 XTX, CUDA, Intel NPU, SSD/HDD throughput and Windows accessibility validation remain separate gates. No GPU-utilization or hardware-speed claim follows from hosted tests.
