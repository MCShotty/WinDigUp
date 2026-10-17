# WinDigUp agent instructions

These instructions apply to this repository. Explicit user instructions and higher-priority
system/developer instructions take precedence. Keep work within the requested scope and preserve
unrelated changes.

## Project map

- `Sources/DigUpKit/`: shared search, storage, indexing, and worker contracts.
- `Sources/digup/`: CLI and persistent indexing/search/worker services.
- `Sources/LlamaRuntime/`: llama.cpp embedding integration.
- `shell/src-tauri/src/`: Windows/Linux native shell, application discovery, settings, and helpers.
- `shell/ui/`: Tauri views built with HTML, CSS, and JavaScript.
- `Sources/DigUpApp/`: macOS SwiftUI application.
- `scripts/`, `tests/`, `Tests/`, and `.github/workflows/`: build, packaging, and validation.
- `docs/`: implementation contracts and recorded validation limits.

Read the relevant code and documentation before changing behavior. Use the current branch and
actual diff to establish what is implemented; plans describe intended work, not completed work.

## Runtime constraints

- Neural inference stays on the selected accelerator: NVIDIA CUDA, AMD/non-NVIDIA Vulkan,
  Intel OpenVINO NPU, or the existing macOS Metal path. Never add CPU inference fallback or
  silently change adapters. Ordinary host tokenization, I/O, matching, and similarity scoring
  remain within the established CPU boundary.
- Preserve full model/runtime/profile fingerprints and backend index isolation. A settings or
  presentation change must not force re-embedding when embedding inputs remain compatible.
- Keep app-name matching, Windows settings matching, and native launching independent of
  model loading, helper failures, and file indexing.
- Give each mutable database connection, model context, and scratch buffer an explicit owner.
  Bound queues; reject stale generations; preserve foreground search priority.
- Preserve cached entries after partial discovery failures. Launch through native IDs and
  preserve shortcut arguments/working directories. External applications must survive worker
  cleanup and DigUp exit.
- Honor `--index` and `--settings` isolation. Write settings atomically and retain annotations,
  folders, schedules, and unsaved UI drafts.
- Keep online description lookup opt-in and attributed. Do not send search queries, private
  filenames, or paths to external services.

## Validation and delivery

Choose checks for the code changed. Guidance and vendored-skill changes need installation and
reference checks, not a full application rebuild.

- Shared Swift changes: use the relevant `swift test` suites after preparing their native build
  dependencies. Rust shell changes: use `cargo test --locked` from `shell/src-tauri` where
  supported, plus the relevant Windows checks.
- Portable application/discovery contracts: `cargo test --release --locked --manifest-path tests/applications/native/Cargo.toml`.
- UI changes: run the matching `tests/ui/*.cjs` suites with the server/browser setup in
  `.github/workflows/activity.yml`; check keyboard behavior, selection, dark mode, and scaling.
- Search/ranking changes: run relevant evaluations under `evals/`. Performance changes need
  before/after measurements on the same machine with workload and cache state recorded.
- Accelerator and installer claims require the relevant native/installed-package checks.
  Synthetic vectors and hosted CI do not prove physical GPU/NPU execution, semantic relevance,
  or latency. State unperformed checks and remaining hardware gates explicitly.
- When the local execution environment is unavailable, say whether edits used GitHub and
  checks ran in Actions. Do not imply that local builds, local files, or devices were accessed.

## Repository-local Anti Slop

The six skills below are installed from Anti Slop v3.2.21. Read
`.codex/antislop/README.md` for provenance, updates, and removal. The entry called
`antislop.md` inside upstream skill prose is the packaged core at
`.codex/skills/antislop/SKILL.md`; use that file rather than downloading another copy.

This is a repository-local skill installation. Plugin support, an MCP registration, and
global machine settings are not required. Apply the relevant skills to the requested work;
installing them does not authorize an unsolicited redesign or audit. Keep the upstream mode
selection behavior; this installation does not save a global mode preference.

<!-- antislop:start -->
## antislop
For UI, copy, people, mobile layout, or code comments work, read these installed skill files directly (use these paths even if a same-named global skill exists):
- Core filter, always on: `antislop`: `.codex/skills/antislop/SKILL.md`
- UI / visual: `antislop-ui`: `.codex/skills/antislop-ui/SKILL.md`
- Copy & text: `antislop-copywriting`: `.codex/skills/antislop-copywriting/SKILL.md`
- People: `antislop-human`: `.codex/skills/antislop-human/SKILL.md`
- Mobile / responsive: `antislop-layoutmobile`: `.codex/skills/antislop-layoutmobile/SKILL.md`
- Code comments: `antislop-code`: `.codex/skills/antislop-code/SKILL.md`
Before starting, follow the core's "Two Usage Modes" section in strict order: explicit session instruction first, then global preference, then ask. A session instruction always wins. For a resolved mode, say `antislop active: <mode> (session override).` or `antislop active: <mode> (global preference).` once before presenting findings or making edits, using the actual mode and source. Acknowledging the user's request without naming the source does not replace this notice.
Only an explicit choice of antislop during or after selects a session mode. A request to review, audit, or avoid file edits does not select a mode; read the global preference in that case. Another skill's mode does not select antislop's mode.
If the mode is unresolved, ask during/after and end the response; wait for the answer before any UI review, planning, or concept. For read-only tasks, put the active-mode notice only at the start of the final answer, never in progress messages. For editing tasks, announce before the first edit and omit it from the final answer.
To update antislop later: `npx antislop-ai --update`, or run `npx antislop-ai` and pick Overwrite them.
<!-- antislop:end -->
