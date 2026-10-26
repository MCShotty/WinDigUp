# Discovery and search experience

This stage starts from merged main `4aa0e49`. It changes presentation and additive Activity fields; it does not change model fingerprints, app launch identities or inference policy.

## Source choices

Settings has separate destinations for Drives, Review apps and Windows settings. Drives retains independent Files and Applications choices per volume GUID, Save/Revert, pending edits across refresh, unavailable volumes and optional administrator-installed fast NTFS discovery. Drive rows are updated by identity rather than replaced when progress arrives. View activity opens the corresponding observed drive row.

Review apps contains executable filters and include/hide/reset decisions. Including a candidate does not run it. The preferred registered shortcut still owns launch arguments and working directory. Online descriptions remain an opt-in Apps source.

## Truthful activity

The outer Activity snapshot remains version 1. File status version 2 adds discoveryActive; readers accept earlier file snapshots. Discovered names and content-searchable counts remain separate. A scan still in progress does not expose a completion percentage, even when an indexing batch has a known count. Older snapshots retain their existing explanations.

Device measurements are optional version-1 data. Unsupported counters stay unknown. Stale samples are labelled; utilization and memory describe the whole physical device and can include other applications. Worker counts and overlapping durations are never converted into utilization.

## General controls

Resource-profile controls preserve the explicit GPU job limit and use Apply and Restart. Quiet, Balanced and Faster are policy choices, not measured speed claims. Local relevance controls use the native personalization contract, and are disabled with an explanation when that contract is absent. History clearing does not change app annotations or indexes.

## Validation

Actual-page browser checks cover source navigation, loading/empty/error states, focus and draft preservation, keyboard tabs, unavailable drives, concurrent discovery/content counters, optional device metrics, General controls, light/dark themes and narrow layouts. Native Activity tests cover additive fields and independent counts. The wider Activity workflow retains search, preview, selection, source-policy and native Windows checks.

The local execution environment is unavailable; edits use the GitHub connector and checks run in Actions. Browser data is explicitly synthetic. Physical Windows screen-reader/mixed-DPI/hotkey checks and accelerator throughput remain unperformed by these fixtures.
