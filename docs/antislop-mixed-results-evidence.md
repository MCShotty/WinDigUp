# Anti Slop delivery evidence: mixed results and drive selection

Scope: the search/result and drive-selection surfaces changed in PR #11. Mode: During, selected explicitly for
this session. Core, UI, code-comment and copy guidance follow the repository-local v3.2.21 installation.
This report does not certify unrelated screens or physical GPU/NPU behavior.

The design read retained `DESIGN.md`: compact Windows search for people finding files, applications and settings,
using DigUp's native controls and moss selection. ENERGY 1 / RHYTHM 2 / MOTION 1. These values were declared before
the visual edits. Best matches is the search focal point; the per-drive Files/Applications pair is the Drives focal point.

## Verification sources

The final evidence commit changes documentation only. The tested implementation revision is `ccc28cd485e0008da689c1c9669bf1980eb32bcb`.

- [Final browser, portable native and Windows shell checks](https://github.com/MCShotty/WinDigUp/actions/runs/39025573194):
  75 portable library tests passed, two explicitly ignored fixtures; the component binary's 15 overlapping tests
  passed separately. The fixed public-description smoke test passed separately.
- [Windows native contracts and accelerator policy](https://github.com/MCShotty/WinDigUp/actions/runs/39024883685):
  75 Windows library tests passed with two explicitly ignored fixtures; the component's 16 overlapping tests passed
  separately. This includes real hosted-Windows mounted-volume discovery without the optional service.
- [Shared engine tests](https://github.com/MCShotty/WinDigUp/actions/runs/39024883694):
  46 tests in eight suites passed, including real SQLite keyword ranking, multilingual hints, stores and concurrent
  readers. The separate worker-deadline suite's three tests also passed.
- Final drive hint, link-contrast and keyboard checks: [successful production-page suite](https://github.com/MCShotty/WinDigUp/actions/runs/39025573194).
- Windows shell `cargo check --locked` and disposable NTFS/standard-user checks passed.
- [Screenshot evidence](https://github.com/MCShotty/WinDigUp/actions/runs/39025573194/artifacts/12097899608): mixed window/panel and Drives, light/dark and scaled widths.
  New mixed-result and drive screenshots label their applications, paths and metadata as synthetic.

Edits were committed through the GitHub connection and checks ran in Actions; the chat's executor was unavailable.
The installed package, latency on the user's disks, real-model relevance and physical AMD/CUDA/NPU execution have
not been validated by these checks. Packaging is a separate workflow. No performance or inference claim is made.

Native and Swift source files are unchanged between the successful native/engine check at `b02932c` and the
tested UI revision above. The final browser suite also runs the portable native tests. The Apps-view preference
regression waits for the current file provider's lexical-ready state, rather than assuming that an immediate
native application reply implies a completed file request. Drive evidence explicitly records that a newly
attached volume remains unchecked after saving another drive.

## Recorded interactions

The production-page browser suites exercise:
- Search typing; Best matches, ordinary source sections and weaker results; exact setting/file collisions,
  aliases, category words, ambiguous variants, Unicode and purpose labels.
- Keyboard movement across compact rows and the file grid; Enter activation; click selection; selected-file
  preview/DOM retention through delayed native replies; scoped filters and panel/window routing.
- Native names and launching while the file helper is blocked or fails; stale response rejection; app paging, launch errors, Settings editors and focused-control keyboard ownership.
- Drives tab and Folders/Apps/Activity entry points; Files and Applications checkboxes independently; Save,
  Revert and Refresh drive list; Space selection and Enter saving; enable/pause options, disconnect/reconnect,
  new drives, loading/errors, revision races and unsaved choices.
- Existing discovery rescan, candidate review/retry/pagination, Windows settings controls and opt-in
  description actions; Activity actions, exports and report redaction.
- Both themes and 1120/760/520-pixel search views; 1100/760/520-pixel Drives views; narrow Settings tab scrolling.
  Screenshots and absence of page errors are recorded. Text contrast is calculated from actual composited colors.

## Block 1: Hard Gate

- R-02 PASS: the added product copy contains no em dashes; added-line audit recorded none.
- R-03 PASS: both search views and Drives passed bounded-width/overflow checks; narrow tabs scroll within their own bar.
- R-17 PASS: displayed counts come from provider replies; fixtures are labelled synthetic and no measured speedup is claimed.
- R-18 PASS: no testimonials or people were added.
- R-23 PASS: Best matches follows the approved plan and Drives follows the user's selection request; existing icons are reused.
- R-24 PASS: Drives, Folders, Apps and Activity links activate existing destinations in the browser tests.
- R-25 PASS: new mixed-row text and drive controls meet 4.5:1 in computed-color checks in both themes; navigation links use leaf-text.
- R-26 PASS: changed controls dispatch existing or registered native commands; save/revert/refresh and result activation are exercised.
- R-27 PASS: pending, failed and empty providers remain independent; drive loading/failure retains selectable cached data.
- R-28 PASS: no FAQ was introduced.
- R-32 PASS: arrow/Enter search navigation and Space/Enter drive controls work; native focus outlines and selected identity remain visible.
- R-33 PASS: behavior and styles live in committed source; production pages do not depend on runtime source/CSS patching.
- R-34 PASS: light/dark snapshots, text-contrast checks and layout assertions passed.
- R-35 PASS: production HTML/JS ran in Chromium and Windows native code passed its check; interactions above are recorded in Actions.
- R-36 PASS: hosted fixtures are distinguished from installed hardware, semantic relevance and performance validation.
- R-37 PASS: DESIGN.md supplied direction; the declared 1/2/1 dials match the compact search and drive editor.
- R-38 PASS: screenshots label synthetic data; no fixture is presented as a real user's inventory.

## Block 2: Purpose Gate

- R-01 PASS: no gradient or glow added; selection uses the established moss color to mark the active target.
- R-04 PASS: existing file/application/Windows-setting icons identify result type; no decorative icon family added.
- R-06 PASS: existing system typography retained for native readability, with no new display face or wide-tracked headings.
- R-07 PASS: no background pattern added.
- R-08 PASS: arrows retain keyboard/help meaning; action labels use verbs without decorative arrows.
- R-09 PASS: Purpose match explains the provider's match reason; no promotional badges added.
- R-10 PASS: no glass surface added.
- R-12 PASS: compact rows and drive choices remain flat; no repeated shadow treatment added.
- R-13 PASS: no glow added.
- R-14 PASS: compact Best matches, existing file grids and drive choice rows have different structures because their actions differ.
- R-19 PASS: updates reuse keyed nodes and existing focus states; no decorative animation introduced.
- R-22 PASS: no illustration added.

## Block 3: Liveliness

- Dials PASS: ENERGY 1 / RHYTHM 2 / MOTION 1 is explicit in the design direction.
- Consistency PASS: calm controls, compact cross-provider rows and existing grids provide the declared limited rhythm variation.
- Focal point PASS: the strongest match leads search; mounted drives and their paired choices lead the Drives editor.
- Whitespace PASS: group spacing separates Best matches from additional results and separates each physical volume's choices.
- Accent PASS: moss/leaf marks selected rows, selected tabs and actionable navigation; neutral metadata remains secondary.
- Motif PASS: DigUp's moss selection, native icons and compact labels repeat across both result views and Settings.
- Design Read PASS: the declared Windows-search direction preceded source/CSS changes and was preserved during visual review.

## Block 4: Craftsmanship and quality locks

- C-1 PASS: Best matches solves fixed category priority; paired drive choices distinguish content indexing from executable discovery.
- C-2 PASS: new navigation, checkboxes, Save/Revert and refresh commands have browser/native interaction evidence above.
- C-3 PASS: every added section serves ranking or selecting a discovery/indexing source; no filler cards or dashboard added.
- C-4 PASS: blocked inference, failed helper, stale replies, disconnected drives, drafts, keyboard use and scaled themes pass regressions.
- C-5 PASS: fixture labels and explicit unperformed hardware gates prevent test data becoming product evidence.
- R-05 PASS: compact best rows, file grids and drive lists reflect content rather than a repeated card template.
- R-11 PASS: existing modest control radii retained; rows, inputs and tabs keep distinct shapes.
- R-15 PASS: actions say Choose drives, Save drive choices, Refresh drive list, Revert and Rescan applications.
- R-16 PASS: added copy has no promotional AI claims.
- R-20 PASS: moss selection, Windows activation and separate Files/Applications controls follow this product's tasks and identity.
- R-21 PASS: both existing themes remain available and tested; no forced dark mode introduced.
- R-29 PASS: neutral surfaces plus existing moss/leaf accent retained.
- R-30 PASS: existing DigUp interface refined; no external product layout transplanted.
- R-31 PASS: reasons for match classes, compact rows, paired choices, spacing and color are recorded here and in mixed-result-ordering.md.

## Comment-only review

Commit `b02932cb20b9012a2838e243b318693ac3dec87d` changes comments only in three source files.
The executable text was compared with its parent `a3bbbb09ce6bda8ee316cf2f40c8293e3ba81cdc` and remained identical.
Outdated comments about per-keystroke inference, grid navigation assumptions and category boosts were replaced
with short constraints describing the actual progressive behavior. Protocol, concurrency and licensing comments remain.
