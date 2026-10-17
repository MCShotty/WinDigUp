# Continuous indexing UI review

Scope: the changed compact panel and Activity measurements. Direction: the supplied capsule reference
and DESIGN.md, ENERGY 1 / RHYTHM 2 / MOTION 1. Anti Slop ran in the user's selected during mode.
No assets, branding or unrelated screens were redesigned.

Evidence:
- [Native and browser checks](https://github.com/MCShotty/WinDigUp/actions/runs/39062310972).
- [Native captures](https://github.com/MCShotty/WinDigUp/actions/runs/39062310972/artifacts/12111648652):
  twelve actual WebView2 theme/material/layout cases, painted corners, no non-client frame,
  real app results and no model inference. All twelve pixel captures were validated.
- [Browser captures](https://github.com/MCShotty/WinDigUp/actions/runs/39062310972/artifacts/12111613779):
  theme/scaling/contrast, stable selection and details, keyboard activation and rendered alpha.
- [Service measurements](https://github.com/MCShotty/WinDigUp/actions/runs/39062311004/artifacts/12112012418)
  are labelled synthetic inference; no GPU utilization or physical speed is inferred.

Native Acrylic painted outside the capsule in both tested API paths. Automatic therefore reports
the existing Solid fallback. The report does not claim working desktop blur.
Physical Windows 10/11 hotkey latency, mixed-DPI behavior, screen readers and GPU/NPU acceptance
remain separate manual gates.

## Reasons for the changed design

- Color: keep the existing neutral surfaces and moss focus/selection so indexing diagnostics share the application's established states.
- Layout: show the current wait reason and job counts first; keep cumulative technical measurements in one expandable definition list.
- Typography: retain the system font and existing text hierarchy for a Windows launcher.
- Spacing: retain the 640 by 64 capsule and use the existing compact Activity spacing.
- Surface: clear native rectangular backdrops and omit the Windows frame inset so paint follows the supplied capsule.
- Focus: use a thin field edge while keeping explicit control focus and forced-color indicators.
- Motion: update existing text nodes at the existing throttled cadence so progress does not move focus or selection.
- Assets: reuse the existing search/window glyphs and real Windows app icons; no new illustration or decorative asset is needed.

## Delivery gate

Each PASS below applies to this changed scope and the evidence above.

| Rule | Result and evidence |
| --- | --- |
| R-01 | PASS: no gradients or glows were added. |
| R-02 | PASS: changed UI labels and this report contain no em dashes. |
| R-03 | PASS: panel and Activity overflow checks passed at their tested narrow/normal/wide sizes. |
| R-04 | PASS: existing search/window glyphs retain their actions; no decorative icon set was added. |
| R-05 | PASS: the supplied launcher and live diagnostic content determine the composition. |
| R-06 | PASS: system typography is retained; no display monospace or tracked headline was added. |
| R-07 | PASS: no grid, blueprint, dots or background pattern was added. |
| R-08 | PASS: no decorative arrows were added; existing shortcut glyphs describe keyboard actions. |
| R-09 | PASS: the capsule contains the actual search field; no promotional/status badge was added. |
| R-10 | PASS: incompatible native Acrylic is cleared and reported as a Solid fallback. |
| R-11 | PASS: the search capsule, circular window action and compact result/detail controls keep distinct shapes. |
| R-12 | PASS: the Windows shadow/frame inset was removed; no new component shadow was added. |
| R-13 | PASS: no new glow was added; moss is reserved for focus and selection. |
| R-14 | PASS: measurements use content rows, with no repeated feature-card grid. |
| R-15 | PASS: existing Open/Preview/Launch actions remain specific; new details expose stage measurements. |
| R-16 | PASS: changed copy describes actual work and failures without promotional claims. |
| R-17 | PASS: counts and durations come from native samples; synthetic screenshots are labelled fixtures. |
| R-18 | PASS: no testimonial or customer content was added. |
| R-19 | PASS: no animation was added; reduced-motion checks passed. |
| R-20 | PASS: the supplied capsule and existing moss selection remain the application's visual motif. |
| R-21 | PASS: saved Light/Dark/System behavior and both OS color schemes passed; no dark default was imposed. |
| R-22 | PASS: no illustration was added. |
| R-23 | PASS: existing glyphs/icons were reused; no unapproved visual or navigation asset was created. |
| R-24 | PASS: no new navigation link was added; Activity opens through the registered existing action. |
| R-25 | PASS: existing palette/text-contrast regressions and forced-color checks passed; Solid avoids variable desktop contrast. |
| R-26 | PASS: the new measurements summary expands/collapses; existing launch, preview and handoff actions passed. |
| R-27 | PASS: preparation, running, pause, failure, idle, unknown/older-schema states are covered. |
| R-28 | PASS: no FAQ was added. |
| R-29 | PASS: existing neutrals and one moss accent are retained. |
| R-30 | PASS: the user supplied the capsule direction; no other product's branding or screen was copied. |
| R-31 | PASS: reasons for color, layout, typography, spacing, surface, focus, motion and assets are recorded above. |
| R-32 | PASS: keyboard/selection regressions and expanded-details focus preservation passed. |
| R-33 | PASS: changes live in checked-in source; no runtime CSS/source patch script implements the feature. |
| R-34 | PASS: Light/Dark/System, contrast and tested window sizes passed browser and native checks. |
| R-35 | PASS: the actual pages and real WebView2 shell were built/run; changed interactive controls were exercised. |
| R-36 | PASS: performance scope and unperformed physical-device gates are explicit. |
| R-37 | PASS: the existing direction and dials were declared before changes. |
| R-38 | PASS: no fabricated realistic content was added; fixture captures identify their synthetic data. |
| Liveliness: dials | PASS: ENERGY 1 / RHYTHM 2 / MOTION 1 is retained. |
| Liveliness: consistency | PASS: compact controls, expandable detail and hover/focus feedback follow those dials. |
| Liveliness: focus | PASS: the query/selected result leads search; the wait reason leads Activity. |
| Liveliness: whitespace | PASS: existing spacing separates state, counts and optional measurements. |
| Liveliness: accent | PASS: moss marks interaction; diagnostic text stays neutral. |
| Liveliness: motif | PASS: the capsule and moss selection repeat the supplied direction. |
| Liveliness: design read | PASS: the desktop launcher direction was established before editing. |
| C-1 | PASS: changed decisions have recorded reasons. |
| C-2 | PASS: changed details and existing actions were exercised. |
| C-3 | PASS: the new section explains measured indexing work rather than filling a template. |
| C-4 | PASS: failure, pause, schema compatibility, delayed updates, focus, themes and scaling passed. |
| C-5 | PASS: raw evidence and limits accompany every measured claim. |

New code comments explain ownership, the credit bound, queue ordering or transparent-canvas behavior.
They contain no workflow narration or decorative headings. Required licensing/protocol comments
remain intact.
