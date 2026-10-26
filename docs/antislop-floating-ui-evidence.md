# Floating UI delivery evidence

This records the UI review against the supplied floating search capsule and the repository's
Anti Slop During rules. The style direction is in DESIGN.md. The behavioural contract, commands,
browser measurements and platform limits are in floating-search-ui.md.

## Automated review snapshot

At 061b45d the [Activity workflow](https://github.com/MCShotty/WinDigUp/actions/runs/39028492645)
passed portable native contracts, Windows Tauri compilation, hosted Windows discovery checks and
the complete actual-page browser regression suite. Native window-theme follow-up and keyboard
help refinements are checked again on the final implementation head in the PR.

| Delivery block | Status | Evidence |
|---|---|---|
| Hard Gate, browser scope | PASS | Actual controls are exercised on production HTML/JS; empty, pending, error, preview and application states render; existing contrast, keyboard, stale-result, draft and scaling checks pass. Synthetic content is labelled and no unsupported speed or hardware claim is displayed. |
| Purpose-Gate | PASS | One transient native material surface separates quick search from the desktop. The circular action opens full search. Moss identifies selection/focus. Native icons identify actual result types. Reasons are recorded in DESIGN.md. |
| Liveliness | PASS | ENERGY 1 / RHYTHM 2 / MOTION 1; the query is the entry focal point, selected rows carry the accent, and the capsule/result-list geometry follows the supplied reference. |
| Craftsmanship, browser scope | PASS | Both search views and Settings pass their interaction regressions. Preview work is deliberate, stable row identities survive progress updates, a delayed provider cannot replace keyboard selection, and incompatible-scope handoff selections are dropped. |

The report above covers source and hosted browser checks. Installed WebView2 checks are part of
the packaging workflow. Desktop material quality, assistive-technology behaviour and actual shortcut
latency on physical Windows 10/11 machines remain explicit acceptance work.

## Reference comparison

| Reference feature | Implementation | Reason for adaptation |
|---|---|---|
| Wide frosted capsule | 640 by 64 logical-pixel entry, native Acrylic where available | Fits a search query and a usable circular action while following work-area limits |
| Thin edge and desktop elevation | Neutral edge, native rounded region and compositor shadow | Keeps one temporary launcher above the desktop |
| Circular trailing control | Open full search, also available through Ctrl+O | Gives the launcher a useful action |
| Command text in monospace | Existing Segoe UI/system search type | Supports filenames, application names and multilingual queries |
| Single compact entry | Full-width results expand beneath the entry; explicit preview/details | Extends the reference to the complete search interaction |

No wallpaper image is embedded or captured. Chromium screenshots show the rendered page and
synthetic native-boundary fixtures; they do not demonstrate DWM blur.

## Browser evidence

The floating-panel suite records empty light/dark capsules, short results, preview, application
details, error recovery, 320/440/640-pixel layouts, forced colours, full search and Dark Settings.
The existing suites also record mixed results and drive selection at larger/scaled widths.

A 100-query hosted comparison used a seeded 2,000-app fixture:
base median/p95 15.2/15.6 ms; new UI median/p95 15.2/15.5 ms.
The three-file panel changed from 480 to 344 pixels, and automatic text-preview requests changed
from one to zero. This is bounded fixture rendering, not an installed-machine speedup.

The PR links the final run and downloadable screenshot/metrics artifact. The Windows installer
and its installed-panel check are tracked separately.
