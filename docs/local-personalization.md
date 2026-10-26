# Local relevance personalization

Result personalization is enabled by default. General settings can turn it off for consistent
provider ordering or clear its history. Turning it off stops collection and use; it retains history
until Clear relevance history is chosen.

Successful accepted file/code opens, app launches and Windows settings activation add a small local
signal. Useful result in a selected result's details records explicit feedback. These signals never
change a match class or semantic score. They may promote a result by at most two positions within its
existing match class and provider section. Exact names and aliases retain precedence over purpose
suggestions. Empty application/settings browsing remains alphabetical. Explicit placement preferences,
file filters and the strong/weaker file boundary still apply.

Signals are captured for a native session and generation, including its lexical/semantic phases and
pagination. Recording feedback does not reorder the current generation. Existing stable-ID selection
continues to determine what Enter opens during delayed refinements.

The independently versioned relevance-history.json lives under the configured base index. Custom
index/settings isolation follows the existing base-index resolver. At most 5,000 entries survive for
90 days. Stored keys are SHA-256 digests of stable result identities; query text, names, raw file paths
and content are not stored. Hashing does not anonymize a predictable identity. The file stays local,
and no interaction data is sent to description providers or update servers.

History is loaded once, kept in memory and written atomically on a separate owner. Interaction
writes are coalesced; a crash can lose the latest unflushed signals. Clear waits for its atomic write
on a background thread before reporting success. A damaged or incompatible disposable history starts
empty without touching settings, annotations or vectors.

Useful-result actions require a recent native-issued result receipt, expire after ten minutes and
deduplicate repeated submission of that receipt. Repeated accepted opens within two seconds do not
multiply the signal. Search views receive only bounded signals and receipt tokens.

Native file/code opening rechecks the file on a background thread before dispatch. A missing or
inaccessible file reports a readable error and retains the panel; a stale availability hint cannot
silently open a different target.

Hosted native/browser tests establish ordering, bounds, persistence and UI behavior. They do not
establish that personalization improves semantic relevance. Real held-out corpus and physical
Windows accessibility/accelerator validation remain separate gates.
