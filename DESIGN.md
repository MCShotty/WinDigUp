# WinDigUp interface direction

This records the direction in the accepted Apps and Activity plan. It keeps the existing search interface and its moss-green selection, Windows application icons, publisher information, concise purpose descriptions, and Activity side pane.

## Identity and hierarchy

DigUp is a Windows search and application launcher. The query and selected result are the focal points. Activity explains whether useful work is happening and what needs attention. Settings lets the user change a source without losing choices in another source.

Use the existing native system font stack, including Segoe UI on Windows. File paths may wrap. Counts use tabular numerals so changing progress does not move the surrounding text.

Retain the project's neutral surfaces and moss-green accent. Green marks selection, focus, and a primary action. Error text identifies an actual failure. It does not decorate a section.

## Composition

Results stay compact, with native icons and useful descriptions. Smart placement puts files, applications, and Windows settings into one Best matches section according to explicit match classes. Remaining file results keep their relevance order. Files first and Apps view only remain explicit alternatives.

Activity occupies the existing side pane in the larger window and expands across the available width in a narrow window. A drive is one readable row: identity, phase, observed counts, and an optional explanation. Stage measurements stay collapsed until requested.

Settings gives drive choices a visible Drives tab, with direct links from Apps and Activity. Windows settings search and online descriptions stay grouped by source in Apps. Each source owns its pending state and feedback. Drive choices have Save and Revert. Progress updates do not rebuild a focused row or discard drafts.

Whitespace separates source decisions and drive rows. Dividers distinguish adjacent drives. There are no decorative charts or percentages for unknown work.

## Themes and motion

System appearance remains the default. Light and Dark are explicit alternatives, shared across the search panel, larger window, setup, and Settings.

Design dials: **ENERGY 1 / RHYTHM 2 / MOTION 1**.

The difference between compact search rows, explanatory drive rows, and collapsed measurements supplies rhythm. Motion is limited to interaction feedback. Discovery uses textual phases and unknown counts instead of an endless animated strip.

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


## Floating search panel

The supplied floating capsule is the visual reference for Ctrl+Shift+Space. Its neutral desktop material,
rounded ends, thin edge and circular action distinguish quick search from the larger search workspace.

The empty panel is 640 by 64 logical pixels where the work area permits. It expands downward around a
single full-width result list. Its top anchor stays fixed, and its height is limited by the work area.
A file preview or application details view opens deliberately in the same window. The compact panel
does not reserve a second column or prepare a full preview merely because a row is selected.

Use one native material surface. Windows Acrylic is requested through the already-pinned
window-vibrancy runtime; native application success determines the material receipt. Respect Windows
transparency, contrast and Remote Desktop restrictions. The Solid preference and unsupported desktops
use an opaque neutral surface. The result list and footer remain opaque to protect reading contrast.

The circular button opens full search and retains the query, compatible scope and selected result ID.
It has a visible focus state, a tooltip and an accessible name. The input uses the existing Segoe UI
system stack rather than the reference's command-oriented monospace. The desktop supplies background
colour; DigUp does not capture wallpaper or add an image behind the launcher.

Purpose notes:
- The capsule shape identifies the quick-search entry point.
- Native material places one transient launcher over the desktop; it does not decorate every row.
- Moss selection and a full outline identify exactly what Enter activates.
- A compact footer keeps primary actions reachable and sends failures to Activity.
- Shared field, control and spacing tokens connect the panel, full search and Settings.

Dials remain ENERGY 1 / RHYTHM 2 / MOTION 1. Reduced motion removes transitions. System, Light and Dark
remain independent of Automatic/Solid material. No new illustration, branding asset or navigation
hierarchy is introduced.
