# WinDigUp interface direction

This records the direction in the accepted Apps and Activity plan. It keeps the existing search interface and its moss-green selection, Windows application icons, publisher information, concise purpose descriptions, and Activity side pane.

## Identity and hierarchy

DigUp is a Windows search and application launcher. The query and selected result are the focal points. Activity explains whether useful work is happening and what needs attention. Settings lets the user change a source without losing choices in another source.

Use the native system font stack, including Segoe UI on Windows. The shared scale uses 24 logical pixels for screen titles, 16 for section headings, 13 for controls and 12 for metadata. Give Settings explanations a 70-character measure and allow long paths and errors to wrap where they are displayed in full. Counts use tabular numerals. Use the same keycaps for shortcut instructions in search, Settings and Setup.

Retain the project's neutral surfaces and moss-green accent. Green marks selection, focus, and a primary action. Error text identifies an actual failure. It does not decorate a section.

## Composition

Results stay compact, with native icons and useful descriptions. Smart placement puts files, applications, and Windows settings into one Best matches section according to explicit match classes. Remaining file results keep their relevance order. Files first and Apps view only remain explicit alternatives.

Full search opens with the cursor in the query. Keep All, Apps, Windows settings and Code visible when available. Group Screenshots, Images, Documents, Video and Audio under File types, with the active type and count on the trigger. Preserve the direct number shortcuts. The home view offers three example searches in a single list. One accessible grid owns the current result row across source groups and leaves section headings and pagination in normal reading order. Keep the row ID stable through refinement and announce the result count separately. The full preview starts on Close and gives text a theme-matched reading surface. More opens on its first enabled action. Escape closes either surface and returns focus to its trigger. Distinguish finding names and words from checking file contents. If file search fails, place Retry above the working app and settings results.

Activity occupies the side pane in the larger window and expands across the available width in a narrow window. Keep its footer button named Activity, with the current indexing state alongside it. At the 820 × 520 full-search minimum, show the phase, Pause and counts together at the top of Overview. Show search timings when a sample exists. The Diagnostics tab opens recovery actions and the report preview. Clicking the query or editing it brings search back into view. Keyboard activation requires a visible result. At narrower rendered widths, give results the whole pane until the user selects Details, then place the preview below the list. A drive row shows its identity, independent Files and Applications choices, saved state, progress and Activity action. Stage measurements stay collapsed until requested.

Settings opens at 660 × 620 logical pixels on Windows. The navigation rail groups General, Activity and Storage under DigUp and the other destinations under Sources. Arrow Up and Down move through the rail. Below 580 CSS pixels, a native picker uses the same groups. Each destination starts at its top and restores its scroll position on return. Drives has direct links from Apps and Activity. Windows settings search has its own destination. Online descriptions are an opt-in Apps source. Lead Model acceleration with the task it enables and place the hardware details beneath a disclosure. Give each save its own feedback. Put an error next to the relevant control and retry with the current draft. Drive choices have Save and Revert.

Setup opens at 720 × 600 logical pixels. Lead with examples of what file search can find. Keep the step count and actions in the footer, with wrapping status above them. The count includes the optional code step when offered. Move focus to the new step heading after Back or Continue. Name the capability that is ready, show the configured quick search shortcut, and connect model failure to Model acceleration. Preserve the chosen folders when opening that repair destination. Open the Apps scope when the user chooses Open app launcher now.

Whitespace separates source decisions and drive rows. Dividers distinguish adjacent drives. There are no decorative charts or percentages for unknown work.

## Themes and motion

System appearance remains the default. Light and Dark are explicit alternatives, shared across the search panel, larger window, setup, and Settings.

The effective light or dark scheme supplies the same palette to all Tauri views. Primary action text and fill use paired tokens. In Windows contrast themes, controls use system colors and the selected result has a Highlight outline on Canvas. Generic app glyphs follow DigUp's effective theme. Installed app artwork keeps its supplied colors.

Design dials: **ENERGY 1 / RHYTHM 2 / MOTION 1**.

Compact search rows, explanatory drive rows and collapsed measurements supply rhythm. Discovery uses textual phases and unknown counts. Setup shows a stationary activity marker for unknown progress and updates known progress in place.

## Purpose of the retained techniques

| Decision | Purpose |
|---|---|
| Moss selection and visible focus | Identify what keyboard activation will open |
| Native application icons | Recognize an installed app without reading every name |
| Publisher and one-line purpose | Distinguish application variants and purpose matches |
| Stable drive rows | Compare independent scans without losing expanded details |
| Collapsed stage measurements | Explain a bottleneck without making logs the main interface |
| Neutral surfaces and restrained dividers | Keep query, results, and actionable failures prominent |
| Larger targets on narrow/coarse-pointer layouts | Keep source actions usable when space or pointing precision is limited |

No new illustration, logo, decorative icon set, or marketing content is introduced.


## Quick search launcher

On Windows, Ctrl+Shift+Space opens a 720 × 120 logical-pixel launcher where the work area permits. The 64-pixel search header sits above a 56-pixel strip for pinned and recent apps. Arrow Down moves to the strip, Left and Right move between apps, and Up returns to the query. The narrow panel uses a thin edge and a slate surface in Dark. [Launcher details](docs/floating-search-ui.md)

As soon as the user types, the strip gives way to a single full-width result list. The top anchor stays fixed and the work area caps the panel's height. Preview and Details open in the same window on request.

Help and F1 open the same in-app guide in quick search and full search. Examples reflect the available scopes and run in the current window. At the full-search minimum, keep the keyboard shortcuts visible beside the examples. Closing without choosing an example restores focus and the previous search. In quick search, expand the capsule to fit the guide and restore its previous content height afterward. Put the Enter hint beside the selected result action. The details header has Back and the title, with text previews aligned for reading from the top. A file-search failure exposes Retry and keeps the working app and settings results in place.

Use one surface across the launcher. The shaped Windows panel currently uses the Solid fallback after both native Acrylic paths painted outside the panel in real WebView2 pixel checks. Clear whole-window backdrops and preserve the transparent WebView canvas and native rounded hit region. Respect Windows
transparency, contrast and Remote Desktop restrictions. Restore Acrylic only after native pixel
validation proves the shaped surface renders correctly. The result list and footer remain opaque
to protect reading contrast.

The full-search button carries over the query, compatible scope and selected result ID. It has a visible focus state, tooltip and accessible name. Search text uses the same Segoe UI system stack as the full window.

Purpose notes:
- The pinned and recent strip gives repeat launches a visible entry point.
- One transient surface keeps the launcher compact without decorating every result row.
- Moss selection and a full outline identify exactly what Enter activates.
- A compact footer keeps primary actions reachable and sends failures to Activity.
- Shared field, control and spacing tokens connect the panel, full search and Settings.

Dials remain ENERGY 1 / RHYTHM 2 / MOTION 1. Reduced motion removes transitions. System, Light and Dark
remain independent of Automatic/Solid material.

## Verification

The [UI remediation report](docs/ui-ux-remediation.md) records the critique and audit repairs, browser evidence, and native validation limits.
