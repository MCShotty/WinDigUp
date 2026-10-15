# Activity and Apps visual verification

final result: passed

## Evidence and scope

- Visual target: `/workspace/generated_images/exec-9dc55b58-9b37-4aca-a372-5a9a7d915593.png`.
- Rendered implementation: `/workspace/.windigup-setup/design/implemented/final-desktop.png`.
- Same Apps filter, `edit photos` query, four named results, first selection and open
  Activity overview. Counts: 443,831 entries, 107,857 preliminary candidates, 663 prepared apps.
- Source and implementation are both 1487×1058 pixels; implementation CSS viewport is
  1487×1058 with deviceScaleFactor 1. No density scaling is applied to the comparison.
- Combined evidence: `comparison-full.png`, `comparison-drawer.png` and
  `comparison-apps.png` in the same directory. Drawer detail crops exclude the source's
  blank 55px title-area band; the full comparison retains it. Native window chrome is
  provided by Tauri/Windows and is not recreated in HTML.
- Actual production HTML/CSS/JS is served by the repository's static UI server. Native
  calls are mocked for repeatable visual states; the screenshots do not demonstrate
  physical inference. Browser plugin not available; regular Playwright/Chromium used.
- Additional captures: `final-dark.png`, `final-1040.png`, `final-narrow.png`,
  `final-diagnostics.png`, `final-editor-wide.png`, `final-editor-small.png`.
- Routes: `/window.html`, `/settings.html?tab=apps`, `/settings.html?tab=activity`.
  Tested 1487×1058, 1440×1024, 1040×700, 800×650 and the existing 660×620 Settings size.

## Comparison history

1. Initial rendered Activity started below the entire search header, leaving its
   footer below the first viewport. [P2] Corrected with a two-column body grid:
   Activity spans the window height, its content scrolls independently, and its
   footer stays visible. Narrow windows use a single full-width Activity pane.
2. [P2] Apps remained denser than the target and used the previous blue selection.
   Corrected result typography to 16px names and 14px publisher/purpose text, increased
   row/section spacing, applied moss selection and added the selected-row Launch action.
   Post-fix evidence is in the final full and Apps-region comparisons.
3. [P2] Activity counters inherited the preview pane's live region and could announce
   every update. Removed that live region while Activity is open; a dedicated status
   region announces phase changes only. Preview announcements are restored on close.
   Browser regression checks the resulting DOM contract.

## Required fidelity surfaces

- Typography: native Segoe UI Variable/Segoe UI fallbacks are retained; Linux capture
  uses its installed system fallback. Heading weights, readable 14px body, tab labels,
  counters, publisher/purpose wrapping and 16px result names reviewed in focused crops.
- Layout: 490px Activity pane at the reference viewport, consistent padding, simple
  dividers and one primary result action. No horizontal viewport overflow. Activity
  footer remains visible, including in the narrow capture; longer content scrolls.
  Settings renders one editor and keeps catalog scrolling independent of draft inputs.
- Colors: existing near-white/dark surfaces and moss/amber tokens retained; lighter
  moss selection replaces blue. Light/dark captures reviewed. Stage plus text conveys
  activity rather than color alone; reduced-motion and forced-colors rules provided.
- Assets: production application icons still come from Windows through the native
  icon cache, now loaded lazily. The Linux native-boundary fixture deliberately returns
  icon errors and therefore shows the product's licensed Fluent fallback. It does not
  substitute fabricated brand art or claim validation of installed Photoshop icons.
  Real Windows catalog/icon behavior remains covered by native provider fixtures;
  installed brand appearance depends on that machine's catalog and OS.
- Copy: candidates are explicitly preliminary, unknown totals have no percentage,
  model-file readiness differs from a verified accelerator receipt, and cached vectors
  differ from encoder readiness. Additional freshness/exclusion text explains real
  production states omitted from the concept. No confidence or utilization figures.

## Functional browser verification

Page identity and meaningful rendering passed, with no framework overlay. Final
capture reports zero page exceptions and zero console errors/warnings. Exercised:

- Open/close Activity, preserve query/selection, switch tabs, keyboard focus and launch.
- First scan/rescan, known progress, pause acknowledgement, scheduled/unavailable,
  finishing/stopped/no-folder states, partial source failures and stale status recovery.
- On-demand logs, report preview, redaction, clipboard fallback and exact export payload.
- One Apps editor, cross-selection/filter/focus drafts, caret preservation, save,
  revert/reset, Unicode limits, native visibility pagination and stale search replies.
- Existing mixed/file/code routing, file previews, launch errors, pagination, disabled
  discovery, setup access, accelerator-settings drafts and Linux Apps-control behavior.

Automated native fixtures additionally cover separate timestamps, retained errors,
significant-event retention, rescan counts, runtime receipts and long-document counts.
The Windows installed-startup check now invokes the real `activity_snapshot` command
and verifies its schema and rendered phase without requiring inference.

## Remaining device checks and polish

Physical RX 7900 XTX, Intel Ultra 7 258V NPU and NVIDIA inference/relevance, packaged-app
activation, actual Windows DPI/accessibility tooling and native Save As interaction
remain separate device checks. Fixtures and a Windows type check do not establish them.
No measured throughput or end-to-end 50ms claim is made.

[P3] The concept's decorative status icons/circular stage markers are simplified to
native-style text/dividers. The existing file filters and preview/settings controls
remain available. These intentional integration differences do not block the workflow.
