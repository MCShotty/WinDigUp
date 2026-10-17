# Floating search panel

Depends on PR #11. The implementation branch is based on its 147d377 head. This change does not
change query prompts, relevance rules, accelerator execution, model fingerprints or vector storage.
Existing embeddings stay compatible.

## Behaviour and ownership

Ctrl+Shift+Space opens a 640 by 64 logical-pixel capsule where the monitor work area permits.
Native geometry owns the physical monitor position, DPI conversion, work-area bounds and rounded
hit region. The page owns content measurement and sends a coalesced height request only when its
desired height changes. The empty header's content area is 62 pixels plus the two border edges.

The query stays at the top. Current-generation native and keyword results arrive independently.
The list grows with content, retains its height while later replies refine the current query,
and scrolls at its maximum. A new query can choose a new height. Full search remains available
through the circular button and Ctrl+O.

The panel reuses the shared Best matches ordering, preferences, explicit prefixes and bounded app
browsing. File rows and section containers are reconciled by stable identity. Progress-only updates
do not rebuild the result list. Thumbnail observation is limited to current rows; visible rows and
a small scroll margin request thumbnails. A file's text/full preview is requested only through
Preview or the existing navigation-then-Space interaction.

A preview or application-details region uses the same native window and leaves the query and footer
reachable. Escape closes that region first and returns focus to the query. A subsequent Escape
dismisses the panel. File copying, revealing, code opening and native launcher identities retain their
existing paths.

Handoff to full search carries the query, scope and selected stable key. A scope-specific Show all
action carries the selection only if it belongs to that scope. A pending handoff never turns an
earlier provider's first row into the intended selection. User navigation takes precedence over
a selection that has not arrived. A selected weaker file unfolds the weaker group when available.

## Appearance and platform boundaries

The persisted panelMaterial setting is automatic by default; solid is the other accepted value.
It is saved through the existing isolated atomic settings path. It does not change the global theme,
accelerator settings, annotations, folder or drive choices.

On Windows, the native service checks contrast mode, transparency, composition and Remote Desktop
before enabling accent-policy Acrylic and checking the native API result. Windows 11's whole-window
system backdrop paints beyond the capsule region, so this panel does not request it. Clearing the
effect disables both the system backdrop and the accent policy. A failed request keeps the page solid
and provides a readable reason. There is no CSS claim that native blur succeeded.

A rounded native window region excludes the invisible corners. Region ownership follows Win32:
Windows owns a region accepted by SetWindowRgn; rejected regions are released. Shape updates use a reentrancy guard and cache only successful API submissions. Windows omits the native shadow/frame inset, uses a transparent native/WebView background, and reapplies clipping after a material change. Acrylic overlays leave more of the native material visible; the field focus edge stays one pixel.

Automatic follows OS restrictions each time the panel opens. Explicit appearance changes update native window themes and refresh
material on the main thread. Material/status events are separate from model and indexing progress.
The document root keeps a normal color scheme so WebView2 can preserve its transparent canvas;
controls inside the panel follow the selected Light/Dark/System appearance. Browser tests inspect
rendered alpha pixels as well as computed CSS backgrounds.
Other desktops retain a usable solid surface and their existing hotkey/Wayland behaviour.

The previously defined appearance and set_appearance commands are now registered in Tauri, and
native Settings navigation accepts drives. A synthetic browser boundary previously hid those gaps.

## Accessibility and measured performance

The input is a labelled combobox with stable option IDs and aria-activedescendant. More-results
buttons live outside the listbox. Selected preview controls expose their expanded state and region.
The listbox is marked closed while its preview is visible. Result availability announcements are
debounced and exclude progress counters.

The shared desktop layer supplies consistent moss focus/selection, controls, spacing and text
hierarchy for quick search, the larger window and Settings. Forced-colour and reduced-motion modes,
narrow windows and large display scaling have dedicated checks. Native screen-reader and
mixed-monitor interaction still require installed Windows validation.

panel_ready acknowledges an opening receipt after the query is focused and a render frame is reached.
The native process records show-to-focus duration using its own monotonic clock. Log writes run off
the UI command path, and these samples stay out of the Activity event timeline. It never subtracts
clocks from different processes and does not record query text in this metric. Diagnostic history
is bounded by the existing diagnostics owner.

The browser comparison uses the production page at base 147d377 and the new page with identical
synthetic native replies. It records 100 distinct render samples against a seeded 2,000-app fixture,
panel height, automatic preview count and labelled screenshots. These are hosted Chromium
measurements; they exclude OS hotkey delivery, native catalog cost and inference. They cannot
establish the installed-Windows p95 target of 100 ms from shortcut to focused input.

## Validation commands and evidence

The Activity workflow runs:
- cargo test --release --locked --manifest-path tests/applications/native/Cargo.toml
- the existing actual-page suites and tests/ui/floating-panel.cjs
- Windows Tauri cargo check --locked
- the existing hosted Windows discovery boundary checks

The Packages workflow builds an installer and runs scripts/check-windows-panel.ps1 after installation.
That script exercises a real WebView2 compact panel with OS catalog results, both material preferences,
System/Light/Dark appearance, empty and expanded geometry, no non-client frame and a native rounded hit region. It captures the full window over a controlled desktop color and samples painted corners and surrounding pixels when the hosted session supports screen capture. Unsupported pixel capture is explicitly UNVALIDATED, not a passing visual check. PNG evidence is retained. It does not load a neural
model, require an accelerator or prove visual Acrylic quality. Remote or restricted hosted sessions
are expected to use Solid.

Physical Windows 10/11 testing remains necessary for bright/dark/busy desktop backgrounds,
transparency changes, contrast, dismissal, screen readers, mixed-DPI monitors and actual shortcut
latency. Existing physical CUDA, AMD Vulkan and NPU validation remains distinct from UI fixtures.


## Recorded browser comparison

The first complete browser pass used 0403ee0 on an Ubuntu 24.04 hosted runner with headless Chromium
and the pinned Playwright 1.61.1. It compared the production base UI at 147d377 with identical native
boundary fixtures. The actual machine inventory is not a physical Windows/GPU reference machine.

| Measurement | Base | New UI |
|---|---:|---:|
| Distinct app-render samples | 100 | 100 |
| Median input-to-render | 15.4 ms | 15.5 ms |
| p95 input-to-render | 15.8 ms | 15.8 ms |
| Three-file panel height | 480 px | 343 px |
| Automatic full-preview requests | 1 | 0 |

These figures show bounded fixture rendering and reduced eager preview work. They do not establish
an installed-Windows speedup. The installed shortcut-to-focus target and native material quality
remain unmeasured. Later commits add stronger short-query/contrast checks and fix the Windows
accessibility import; the final validation run is recorded separately in the PR.
