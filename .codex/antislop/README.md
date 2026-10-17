# Anti Slop installation

This repository vendors all six Anti Slop skills from
[v3.2.21](https://github.com/miqdadbadjuber/anti-slop/releases/tag/v3.2.21),
commit `77e1920ad5e540816ccec3b2142128d95ef12bcb`, under the upstream MIT license in [LICENSE](LICENSE).

The layout follows the Codex project target in upstream
[`cli/lib/install.mjs`](https://github.com/miqdadbadjuber/anti-slop/blob/77e1920ad5e540816ccec3b2142128d95ef12bcb/cli/lib/install.mjs):
copy each selected skill folder to `.codex/skills/`, then write one marked pointer
block in the root `AGENTS.md`. The pointer block was generated from that release's
`pointerBlock` function. Upstream skill files and their bundled Python tools are
copied without modification.

This installation used the published GitHub release. A ZIP path on a user's
Windows machine was not accessible to the cloud task and was not inspected.

## Contents and use

- `antislop`: core filter and delivery checks.
- `antislop-ui`: interface design.
- `antislop-copywriting`: prose and product copy.
- `antislop-human`: accessibility and contrast.
- `antislop-layoutmobile`: responsive layout.
- `antislop-code`: code-comment hygiene.

The skills are ordinary tracked files. Cloud tasks can read them through
`AGENTS.md` without a plugin installation, Node package, network download, or MCP
configuration. The Python contrast checker uses the standard library:

```sh
python3 .codex/skills/antislop-human/contrast-check.py --selftest
```

The bundled `contrast-mcp.py` is retained as an upstream file; this change does
not register or start an MCP server.

Start a new Codex task on a checkout containing this commit for normal skill
discovery. An existing task can read the installed files directly. Skills are
instructions, not an automatic CI enforcement mechanism.

Upstream resolves its usage mode from an explicit session choice, then a saved
global preference, and otherwise asks. No global preference was created by this
installation. To choose a mode for one task, say "Use antislop during for this
session" or "Use antislop after for this session."

## Verify

[source.json](source.json) records the immutable source commit and Git blob SHA-1
for every copied file, including the license. Compare the checkout's files with
the corresponding upstream blobs; Git hashes the blob header as well as its
bytes, so these are Git object IDs rather than plain file SHA-1 checksums.

Check that `AGENTS.md` contains exactly one `antislop:start` / `antislop:end`
pair and that all six referenced `SKILL.md` paths exist. The core `VERSION`
must agree with the recorded release. Run the contrast self-test when Python is
available. Do not report it as executed merely because file hashes match.

## Update

Updates are explicit and reviewed. From the repository root, run
`npx antislop-ai@<chosen-version>` and choose all six skills, **This project**,
**Codex**, and **Overwrite them**. Use a pinned version, inspect the release, and
review the resulting diff. The upstream `--update` command also searches global
installations; use the project-scoped installer for a repository-only update.

Refresh this directory's upstream license and `source.json` from the same
release/commit. Preserve WinDigUp guidance outside the marked pointer block.
Verify the copied files, version, pointer paths, and contrast checker before
committing. Do not duplicate the skills under another agent folder.

## Remove

Remove the six `antislop*` directories under `.codex/skills/`, the marked
pointer block and Anti Slop-specific paragraph in `AGENTS.md`, and this
`.codex/antislop/` directory. Preserve unrelated agent instructions and skills.
