# Mixed search ordering and drive choices

This change is based on PR #10 at `a31296b`, on `codex/mixed-result-ordering`.

## Search behavior

Both Windows search views use `shell/ui/mixed-results.js`. Smart placement shows up to five compact Best matches.
Files, applications and Windows settings can appear together. The shared match classes are:

1. Exact display name, filename (including its stem), or native explicit alias.
2. Whole-name and all-word token-prefix matches.
3. Acronym and substring matches.
4. Native bounded typing-error matches.
5. Content and purpose matches already admitted by their provider.

Each provider retains its ordering within a match class. A bounded merge compares the heads of these lists.
Equal classes across providers use the normalized title and stable ID as deterministic ties. File scores,
application cosine scores and settings cosine scores are never compared or converted into confidence percentages.
These rules describe presentation; they do not establish real-model semantic relevance.

A current-generation exact or strong filename returned below the file searcher's strong cutoff can still surface
in Best matches. It is removed from the folded weaker list so it never appears twice. Ambiguous exact application
variants and exact file/settings collisions remain separate, selectable results.

Remaining source sections follow their strongest available match class. File results keep their existing relevance
order in both views; the compact panel no longer gathers all images or documents into a higher section.
Files first keeps application results after files. Apps view only suppresses applications from ordinary searches.
Neither preference disables Windows settings. Explicit file-kind/code scopes exclude launcher providers, while
`apps:` and `settings:` retain bounded browsing and alphabetical empty-query results.

Bare category names such as Photos, Videos, Documents and Sound no longer imply a file-type boost. A category name
remains searchable as a filename. Descriptions such as photos of mountains and sound of rain retain their soft
file-type hint. Explicit file filters retain their existing scope.

Native names and activation can appear and work before the file helper replies. Once a user selects or activates a
result, later replies retain the chosen identity and file location. Removing that result clears selection rather
than redirecting Enter. File cells and panel rows are reused by stable keys, preserving thumbnails and previews.
Existing embeddings, schemas, runtime fingerprints, accelerator selection and neural execution policies are unchanged.

## Drives

Settings now has a visible Windows Drives tab, also reachable from Folders, Apps and Activity. Each mounted drive
has independent Files and Applications checkboxes. No drive is selected automatically.

Files adds the selected mounted root to the existing Folders configuration. Clearing it removes only that root;
individually chosen subfolders, exclusions, file-type choices and schedules remain. Those roots follow the existing
Windows folder-path semantics. Application choices retain stable volume GUIDs across drive-letter changes.

Save writes file and application choices together when both changed. Native code validates reported volume IDs,
rejects unavailable/newly disconnected file roots, merges changes with current preferences, preserves application
review decisions, and saves atomically through the configured settings path. Explicit CLI folder overrides reject
drive file changes rather than pretending to apply them.

Refresh drive list performs background Windows volume discovery independently of application scanning, pause,
model availability or the master application switch. Requests coalesce. Loading and failures are explicit;
a failed enumeration retains the last reported drives and saved choices. A disconnected saved application volume
remains listed so it can be deselected.

Whole-drive file indexing uses the existing file crawler. The optional NTFS component accelerates executable
discovery; it does not infer or embed file contents. File inference still requires the explicitly selected GPU/NPU.

## Validation

`tests/ui/mixed-ordering-contract.cjs` checks deterministic ordering, collisions, aliases, Unicode, preference/scoped
behavior, provider-local scores and file-order preservation. `tests/ui/mixed-ordering.cjs` exercises both production
pages with synthetic native replies, blocked/failed file helpers, weak exact filenames, native activation,
selection, light/dark themes and scaled windows.

`tests/ui/drive-picker.cjs` exercises actual Settings controls with synthetic native replies: loading, independent
file/application choices, save/revert, focus/refresh draft retention, errors, new/disconnected drives and navigation.
Portable Rust tests exercise atomic root deltas and failed inventory retention. Windows tests enumerate the hosted
system drive without installing the optional component. Swift tests exercise actual keyword retrieval, bare
category names, explicit filters and multilingual query hints.

Checks run in GitHub Actions because the chat has no usable local execution environment. Final workflow links and
screenshots are recorded in PR #11. Hosted browser fixtures do not establish installed-device latency, semantic
relevance or physical AMD/CUDA/NPU execution.
