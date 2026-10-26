# Activity and Apps implementation plan

Base: `codex/windows-app-launcher` at `4927a6b` (PR #3). Work belongs on
`codex/activity-apps`, with a PR targeting that branch until #3 is merged.

The visual target is the final “Activity at a glance” sample: a restrained moss-green
Apps launcher and an independently accessible Activity drawer. This is production
integration into the existing Tauri app, not a replacement frontend or a static mock.

## Delivery and acceptance

1. Native contract: version the aggregate and file/catalog/purpose/inference/helper
   sections independently. Record event, meaningful-progress and phase timestamps.
   Unknown totals are null. An in-memory snapshot must never query a helper, load
   logs, inspect directories or start inference. Preserve searchable counts across
   scans and retain failures until a successful reconciliation or explicit recovery.
   Keep configured hardware separate from a runtime's accelerator-only receipt.
2. Shared Activity: reuse one component in the main window and Settings. Overview
   presents discovery/queue/index/rest phases, honest progress and independent app
   availability. Diagnostics presents provider health and bounded significant events;
   technical log tails are requested on demand. Report preview supports redaction,
   copy and native Save As export. Pause is pending until acknowledged. Narrow
   windows show Activity at full width and restore prior focus when it closes.
3. Apps search: use native icons with a licensed generic fallback, publisher and
   purpose, moss selection and selected-row launch. Preserve native ranking, stable
   IDs, pagination, six mixed hits, delayed semantic replies and existing file/code
   behavior. No raw similarity percentages. Empty Apps browsing never wakes inference.
4. Apps settings: searchable native-paginated Visible/Hidden/All catalog and one
   selected editor. Drafts survive selection, focus and provider updates. Save, Revert
   and Reset overrides retain existing limits (16 aliases of 80 characters and 1024
   purpose characters). Show discovery and semantic preparation independently.
5. Verification: native state/contract fixtures before UI integration; browser
   fixtures for first scan, rescan, preparation, paused/scheduled/failed/unavailable,
   stale replies, slow helper, report redaction/export, draft retention and routing.
   Compare the rendered layout with the visual target, including dark mode,
   1440×1024, 1040×700, the 660×620 Settings window and effective Windows scaling.

The acceptance fixture has 443,831 entries checked, 107,857 preliminary candidates,
and 663 prepared apps. It must communicate active discovery and available Apps
without JSON, percentages with unknown denominators, or invented performance data.
Metadata/scanning stays on the host CPU; all neural inference remains on the selected
GPU/NPU with no CPU fallback. No index migration or re-embedding is required.

Automated fixtures validate contracts and UI behavior, not real device acceleration,
semantic relevance or packaged-app activation. Record actual commands, captures and
remaining Windows/RX 7900 XTX/Intel NPU/NVIDIA checks in the handoff.
