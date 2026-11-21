# WinDigUp UI critique and audit remediation

This closes the 15 issues from the November 11 Impeccable review. The November 18 verification used the Tauri UI pages with fixture responses in Chromium. Anti Slop ran during implementation. [Design decisions](../DESIGN.md)

## Repairs and regression coverage

| Finding | Repair | Verification |
| --- | --- | --- |
| F01 · Setup footer overflow | A wrapping status area sits above the action row. Long messages can scroll within the status area. | With the CUDA upgrade message and doubled computed font sizes, every footer action stays in bounds and can receive a pointer click. |
| F02 · Search selection | The query controls a labelled results grid. The active row has a stable ID and the result count has a separate status announcement. | Active row and selection survive refinement. Files, code, apps and Windows settings resolve to named grid rows. Enter opens the selected result. |
| F03 · Full preview focus | The modal gives initial focus to Close and keeps background controls inert. | Tab cycles in the dialog. Escape closes it and returns focus to the query without clearing the search. |
| F04 · Settings field names | File types, code editor, and start and end times have visible labels. The time controls have a named group. | Named controls are discoverable by role and label in Chromium. |
| F05 · Rejected saves | Acceleration, file types, hours, and editor saves report an alert and expose Retry beside the control. Native updates commit in memory after the file is saved. | Forced rejections keep the draft. Retrying uses the latest input, and delayed responses leave newer edits intact. A blocked temporary file leaves both stored values intact and a retry persists the edit. |
| F06 · Action contrast | Primary controls use paired fill and text tokens. Amber actions use a theme-specific link color. | Search chips, Launch, the focused menu item, dark preview Open, Setup actions and the drive activity action meet 4.5:1 in their exercised themes. |
| F07 · Forced colors | Selected rows keep readable system text and use a Highlight outline. Controls use system pairs. | Selected application text and Launch remain readable, and search focus remains visible under forced colors. |
| F08 · Recovery and fallback copy | Setup reports the specific model problem and links to Model acceleration. Words-only search suggests filenames and remembered words. Mixed search gives file recovery a visible position. | The Settings link leaves the chosen folders and setup state in place. App-ready, file-ready and model-failed states show the corresponding capability. Retry is reachable beside working app matches at 820 × 520. |
| F09 · More menu keyboard access | More exposes its open state and focuses an enabled item. Arrow keys, Home and End move focus. | Escape restores the trigger, Tab advances through the window and a second click closes the menu. |
| F10 · Tab scroll | Each Settings tab starts at the top and remembers its own scroll position. The tab strip fits the shipped width. | Opening Apps from the bottom of General begins at the Apps controls. Returning to General restores the previous position. Storage is visible in the initial tab strip. |
| F11 · Compact Activity | The current phase, counts and Pause sit together ahead of supporting details. Enter can activate only visible results. | At 820 × 520, the first view includes phase, counts and Pause. Diagnostics stays reachable by scrolling. Clicking or editing the query restores the results. |
| F12 · Fallback app glyph | The generic icon follows DigUp's effective theme. | System, Light and Dark use the correct icon treatment with either OS color scheme. |
| F13 · Reduced motion | Setup shows a stationary marker for unknown work and updates measurable progress in place. | The waiting marker stays centered and the 50% state updates without a transition. |
| F14 · Supporting text | Reviewed captions and supporting prose use at least 12 CSS pixels. Long Settings explanations have a maximum width of 70ch. | The drive note uses the larger type and fits its measure in the shipped Settings window. |
| F15 · Drive headings | Drive headings sit one level below the section title in Settings and in Activity. | Chromium exposes Settings drive names at level 3 and Activity drive names at level 4. The drive action focuses the corresponding Activity heading. |

## Impeccable follow-up

Two independent passes used Impeccable 4.8.0. The design pass sampled the actual frontend at the shipped dimensions with fixture data. It rated the design **29/40** after the original repairs, up from **26/40** on November 11. The capsule, native app icons and match explanations give the launcher a recognizable identity. The compressed layout keeps the query and chosen result prominent. Settings still has nine peer destinations, and the full-search keyboard guidance is chiefly in tooltips and the accessible input description.

| Heuristic | Score | Observation from the design pass |
| --- | --- | --- |
| Visibility of system status | 3 | Activity names the phase and distinguishes indexed and queued work. Before follow-up, mixed search could show its file failure only in the footer on first view. |
| Match with the real world | 3 | Files, apps, Windows settings and Explorer use familiar names. Acceleration still takes specialist vocabulary. |
| User control and freedom | 3 | Activity can close and return focus. Setup has Back. Drive choices have Save and Revert. |
| Consistency and standards | 3 | Search surfaces share control and selection cues. The original app-only handoff opened the All scope. |
| Error prevention | 2 | Drive selection and diagnostic redaction protect deliberate choices. Compact Activity previously allowed activation of a hidden result. |
| Recognition rather than recall | 3 | Match reasons, publishers and scope labels help readers identify results. Storage was initially offscreen at the shipped Settings width. |
| Flexibility and efficiency | 4 | Keyboard navigation, scope shortcuts, the global hotkey and handoff support repeated searches. |
| Aesthetic and minimalist design | 3 | Search stays focused, with some repeated actions in quick details. |
| Error recovery | 3 | Setup has an acceleration destination. File retry initially required scrolling past working results. |
| Help and documentation | 2 | Setup teaches the main keyboard commands. Full search relies on examples, tooltips and its accessible description. |

Follow-up fixes covered the hidden-result activation, file retry placement and Storage visibility. Setup now focuses the step heading and sends the app-only action to the Apps scope through the existing search handoff. The browser checks verified the emitted command and the empty, focused Apps landing using the handoff payload. The 29/40 design score records the independent pass before these follow-up fixes.

The technical audit rated the repaired UI **16/20** after polish, up from **12/20**. Chromium's accessibility tree confirmed that the combobox controls the named results grid and its active descendant resolves to the selected row within that grid. The final five rendered states produced one detector warning for the deliberate selection edge on a file row. The source detector returned five warnings: the Activity tab underline, two search placeholder warnings, and two indeterminate meter rules. The tab computes to a square underline, search placeholders measured 5.85:1 to 7.63:1, and the meter flagged as a marquee was hidden and motionless in the sampled state.

| Dimension | Score | Evidence |
| --- | --- | --- |
| Accessibility | 3 | Named roles and regions, modal and menu keyboard traversal, visible focus, and measured contrast in the repaired states. |
| Performance | 3 | Existing lazy previews, bounded result tests and progress updates run with the repaired UI. Native timing remains unverified. |
| Theming | 3 | Paired action tokens and automatic glyph treatment follow the effective scheme. The GPU prompt now measures 6.63:1 in dark Settings. |
| Responsive design | 3 | Shipped viewports, doubled computed font sizes and interrupted touch scroll passed in the browser. |
| Implementation integrity | 4 | Source and rendered warnings were checked in context. Polish also raised preview metadata to 12px and balanced Activity's explanatory line wrapping. |

## Browser verification

All 21 UI suites passed. The new suites cover [search and Activity](../tests/ui/search-accessibility.cjs), [Settings](../tests/ui/settings-accessibility.cjs) and [Setup](../tests/ui/setup-recovery.cjs). The existing floating panel suite covers the collapsed capsule, results, preview, application details and theme transitions. The browser CI job runs the new suites and archives their captures. [UI workflow](../.github/workflows/activity.yml)

Settings was checked at its shipped 660 × 620 logical-pixel size. The November 11 report had attributed the 720 × 600 Setup size to Settings. Full search was checked at its 820 × 520 minimum and quick search at its 640 × 64 collapsed size and in expanded states. [Native window configuration](../shell/src-tauri/src/main.rs)

Across the six combinations of OS light or dark and app System, Light or Dark, the measured search action minima were 6.62:1 in effective Light and 8.68:1 in effective Dark. Dark preview Open measured 8.68:1. These are text contrast measurements from the rendered styles of the exercised controls.

Settings and compact Activity scrolled under Chromium-synthesized touch after an interrupted gesture. With doubled computed font sizes, each scroller fit the shipped window width and exposed its main action. The UI tests also doubled computed font sizes in Setup. The browser used synthetic data, Chromium accessibility semantics and media-query emulation.

The portable Rust fixture suite passed 133 tests, including a disk write failure followed by a successful retry. Three tests marked ignored were skipped. Windows WebView2, the native Setup handoff, Windows display scaling, NVDA announcements, and physical touch remain unverified. [Settings persistence test](../shell/src-tauri/src/settings.rs)

<details>
<summary>Anti Slop delivery checks</summary>

The checks below cover the changed paths and the browser and portable tests described above.

| Rule | Result and evidence |
| --- | --- |
| R-01 | PASS · Solid surfaces and visible outlines provide hierarchy. |
| R-02 | PASS · Changed labels and guidance use ordinary punctuation. |
| R-03 | PASS · Setup actions, the Settings tab strip and compact Activity fit the measured viewports. |
| R-04 | PASS · The existing search, close and generic-app glyphs retain their functions. |
| R-05 | PASS · Search results, setup steps and drive choices use layouts specific to their tasks. |
| R-06 | PASS · The system font and larger supporting text keep the density appropriate for a desktop launcher. |
| R-07 | PASS · The search backdrop is the established solid surface. |
| R-08 | PASS · Arrow symbols identify the existing keyboard controls. |
| R-09 | PASS · Category chips change search scope and expose their selected state. |
| R-10 | PASS · The existing launcher remains the only desktop-material surface. |
| R-11 | PASS · The search capsule, round window control and rectangular dialogs retain distinct shapes. |
| R-12 | PASS · Borders and focus outlines define the repaired controls and panels. |
| R-13 | PASS · Selection and focus use a moss outline with a Highlight equivalent. |
| R-14 | PASS · Drive and result rows expose the identity and state needed for their actions. |
| R-15 | PASS · Retry and acceleration actions identify the task they perform. |
| R-16 | PASS · New status copy describes model availability and what the search can match. |
| R-17 | PASS · Application and indexing counts come from their source responses. |
| R-18 | PASS · The repaired screens contain settings, results and progress from their data sources. |
| R-19 | PASS · Setup progress motion tracks active work and uses a static indicator in reduced motion. |
| R-20 | PASS · The capsule, native app artwork and match reasons identify the launcher. |
| R-21 | PASS · System, Light and Dark work with both OS color schemes in the exercised controls. |
| R-22 | PASS · Setup and previews use the existing app mark and file content. |
| R-23 | PASS · The changes reuse the existing Settings tabs and application icons. |
| R-24 | PASS · The recovery links reach Model acceleration, Activity and the Apps scope. |
| R-25 | PASS · Measured action text meets 4.5:1, including the forced-color result checks. |
| R-26 | PASS · Retry reissues each save, Pause sends the new state and More opens and closes. |
| R-27 | PASS · Pending progress, no-match, partial search failure and unavailable model states provide specific feedback. |
| R-28 | PASS · Help lives in Setup instructions and the search controls where it applies. |
| R-29 | PASS · Neutral surfaces and moss interaction states use shared theme tokens. |
| R-30 | PASS · The changes follow the existing DigUp design and source behavior. |
| R-31 | PASS · The design file records the reasons for hierarchy, spacing, color, type and motion. |
| R-32 | PASS · Keyboard tests cover result selection, dialog traversal, More, Setup transitions and Settings. |
| R-33 | PASS · The production behavior lives in the Tauri UI sources and native command handlers. |
| R-34 | PASS · Browser theme, forced-color, viewport and text-size checks passed for the repaired paths. |
| R-35 | PASS · The shipped frontend pages ran with fixtures. The repair table records the exercised actions. |
| R-36 | PASS · Test environments and native verification limits accompany the measured claims. |
| R-37 | PASS · The established DigUp design and motion dials guided the repair. |
| R-38 | PASS · Synthetic replies stay in fixtures. The production UI reads the actual providers. |
| Dials | PASS · ENERGY 1 / RHYTHM 2 / MOTION 1. |
| Consistency | PASS · Compact rows, disclosures and restrained focus cues follow the dials. |
| Focus | PASS · The query, setup step, active tab and current Activity phase lead their views. |
| Whitespace | PASS · Spacing separates footer status, main actions and optional details. |
| Accent | PASS · Moss identifies focus, selection and primary actions. |
| Motif | PASS · The capsule and moss selection connect the search surfaces. |
| Design read | PASS · The launcher and native Settings context were established before edits. |
| C-1 | PASS · The repairs address observed interaction and readability failures. |
| C-2 | PASS · Changed actions were executed and their focus or result was checked. |
| C-3 | PASS · Each added message explains a result, state or recovery action. |
| C-4 | PASS · Tests exercise errors, stale replies, keyboard use, theme changes and larger text. |
| C-5 | PASS · Scores, test counts and contrast measurements state their source and limits. |

</details>

## November 21 follow-up

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

## All-window refinement

Impeccable’s Distill, Typeset, Layout and Delight passes covered both search windows, all nine Settings destinations, every Setup step and the folder pickers. The walkthrough also covered Help, file and app previews, Activity and its diagnostic report. [Current design direction](../DESIGN.md)

| Pass | Changes |
| --- | --- |
| Distill | Grouped five file types under one control, shortened home to three examples, and moved Activity navigation to its tabs. Show search timings once a sample exists. |
| Typeset | Shared title, section, control and metadata sizes. Used the same keycaps for shortcuts and matched document previews to Light and Dark. |
| Layout | Settings uses a DigUp and Sources rail at 660 × 620 and a native section picker on narrow views. Activity puts Pause next to its phase. Setup keeps step progress beside the persistent actions. |
| Delight | A Help example runs in the current search and returns focus to the query. Quick Search places Enter beside the action it invokes. Setup shows the configured shortcut when search is ready. |

All 21 UI suites passed in Chromium 154 with synthetic native replies. axe-core 4.14.1 found zero violations in 38 rendered states. Those states also passed checks for page errors and horizontal overflow in the main layouts. Impeccable’s rendered typography and layout scans found zero findings across 26 states. The source detector flags the flex-centered search field because it lacks explicit vertical padding. At the supported desktop size, the field centers its input and Clear control with about 10 pixels above and below.

**Anti Slop review.** The navigation and interaction checks exercised the file type menu, runnable Help examples, section picker, Setup actions and diagnostic report. Light and Dark use the same role hierarchy. The four windows kept their primary actions reachable with doubled computed text sizes at narrow widths. Emulated touch reached the file type menu and resumed scrolling in Help and Settings. Moss marks the active scope, selected result or next action. The shortcut hints and readiness cues carry the product’s character within the established motion settings.

Windows WebView2 window behavior, screen-reader announcements and physical touch remain native verification items.

### Launcher integration

The integration keeps the pinned and recent app strip, launcher preferences, Copilot key settings and Control Panel results from PR #22. Closing Help returns the Windows launcher to its 120-pixel home height and restores focus to its trigger. The All apps and Browse apps buttons use their visible text as their accessible names.

All 22 UI suites passed on the integrated branch, including the launcher home and Windows settings checks. The 38-state Chromium walkthrough passed again with a pinned-app fixture and the revised launcher geometry.
