---
target: WinDigUp November 21 critique and audit
total_score: 32
max_score: 40
na_heuristics: ""
p0_count: 0
p1_count: 0
target_identity: "file:/workspace/WinDigUp/shell/ui/window.html"
target_fingerprint: "sha256:ebe32369a2ae7da656b414f83bbec22e3d342cfb28150b9cbc7cd3a86f2b51d6"
target_path: /workspace/WinDigUp/shell/ui/window.html
timestamp: 2026-11-21T17-22-03Z
slug: shell-ui-window-html
---
## November 21 follow-up

Independent design and technical assessments used separate Chromium contexts.

The follow-up retained the Windows launcher and grouped Settings into DigUp and Sources. Search Help is available from both search views and through F1. The full window shows the guide's shortcuts beside the search examples, and the quick panel expands for the guide and restores its previous height on close. At narrow widths, Details opens the preview on demand. Quick search shows an actionable file retry without interrupting the app or settings results that already arrived. [Design decisions](../DESIGN.md)

| Area | Result |
| --- | --- |
| Keyboard and accessibility | Explicitly owned result groups, labelled Setup folder choices, stable folder focus, keyboard movement between Settings rows, and focus return from Help. |
| Recovery | Setup explains what remains available during model failure. Both search views retry the file provider in place. |
| Appearance | All four pages use one effective palette for System, Light and Dark. Selection uses the same outlined treatment across sources. |
| Reflow | The primary actions remained reachable with doubled computed text sizes at widths from 320 to 410 CSS pixels in the tested scenes. Quick Help and Settings resumed scrolling after a cancelled Chromium touch gesture. |
| Rendering | In a local Chromium fixture with 80 files and 18 successive queries, category controls removed from the DOM fell from 540 to zero and layout compositions fell from 338 to 72. Median time from filling the query to the fixture's final generation was 152.6ms before and 146.0ms after. |

The 21 browser suites include Help focus, file recovery, source navigation and Setup keyboard coverage. axe-core 4.14.1 flagged zero automated violations across 18 states. The fixture suite and audit use synthetic native replies and browser accessibility semantics. Windows WebView2 window management, actual screen-reader announcements, display scaling and physical touch need native validation.

### Independent design critique

**16/20**, converted from **32/40** on Impeccable's ten-heuristic scale. The November 18 design sample was **14.5/20** on the same scale. The reviewer confirmed the fixes in a second targeted walkthrough. At 440 × 560, the search header dropped from 221px to 116px, leaving room for all three fixture matches. At 820 × 520, the guide fit all six shortcuts and returned focus to the query. File retry kept the selected app while recovering the missing file result. Setup displayed the available app-name search beside the model failure, with the footer actions still reachable.

| Heuristic | Score out of 4 |
| --- | --- |
| Visibility of system status | 3 |
| Match with the real world | 3 |
| User control and freedom | 3 |
| Consistency and standards | 3 |
| Error prevention | 3 |
| Recognition rather than recall | 3 |
| Flexibility and efficiency | 4 |
| Aesthetic and minimalist design | 3 |
| Error recognition and recovery | 4 |
| Help and documentation | 3 |

The reviewer noted that later search categories still require horizontal scrolling at 440px. The full-width experience keeps the side-by-side details and results at the 820px native minimum.

### Technical audit and repairs

**18/20**, up from **16/20** on November 18. The independent audit retested each verified issue after the repairs.

Manual checks found that the responsive search preview rule also widened the Settings folder status column, leaving the folder text at zero width. The rule now targets the search preview by ID. The audit also led to a named tray-click radio group, a live Setup phase and determinate progress, an exposed state for weaker matches, larger coarse-pointer targets, and paired destructive action colors.

After the typography pass the Impeccable detector reported zero findings in five rendered states. Its source scan flagged the search field's padding. The rendered 48px field centered its 28px input and Clear control with 10px of space above and below. Browser checks used Chromium 154 with Playwright because the Browser plugin was unavailable. Both passes used Impeccable 4.8.0 and separate seeded browsers.

| Dimension | Score out of 4 | Evidence |
| --- | --- | --- |
| Accessibility | 3 | The accessibility tree exposes the active result, disclosure state, named radio group and Setup progress. Native screen-reader verification remains open. |
| Performance | 3 | The fixture recorded fewer category replacements and layout compositions. Full search still rebuilds some result section wrappers during refinement. |
| Theming | 4 | The destructive confirmation measured 5.84:1 in Light, 9.70:1 in Dark, and 21:1 in the exercised forced-colors palette. |
| Responsive design | 4 | Folder text had 453px at the shipped Settings width and 137px at 360px. The audited search and Setup buttons met the 44px coarse-pointer target. |
| Implementation integrity | 4 | The shared controls passed the expanded fixture checks and the scoped preview styles preserve Settings layout. |
