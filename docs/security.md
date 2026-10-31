# Security boundaries

CloudNest is a development preview with tested safety controls, not a security
certification or a production 1.0 release. [Release readiness](release-readiness.md)
separates implemented behavior, live evidence and remaining device/account gates.
[Privacy](privacy.md) describes plaintext storage and retained history.

## Local storage and cleanup

Scanning requires an approved source. Ordinary archiving excludes system and
protected paths, repositories, live database files/directories, VM disks, Photos
libraries, app bundles, cloud placeholders and symbolic links. Hard links are
counted once per scan; APFS clones/snapshots prevent guaranteed reclaim estimates.
Recommendations and opt-in schedules do not authorize uploads or deletion.

The catalog resides in an owner-private directory. Database opening rejects
unsafe links/ownership before migration, and protects SQLite sidecars against
unsafe substitutions. OAuth client configuration, tokens, resumable upload
capabilities and the native Brain owner credential use Keychain. Secrets are
not stored in archive manifests. Private connection imports require an explicit
owner-selected file; Brain setup never extracts the Mac's Google refresh token.

Uploads stream through bounded jobs and verify remote content and recovery
manifests before cleanup becomes available. Moving an original into managed
recovery retains its local bytes. Permanent removal requires separate approval,
fresh cloud verification and local identity/hash/inventory/metadata checks.
Whole-folder cleanup checks the root manifest and every remote child, then
removes only owned, manifested members through anchored descriptors. It never
recursively removes a user tree or empties unrelated Trash. Offline put-back
refuses conflicts; partial removal cannot be represented as a complete put-back.

Cleanup uses the built-in `lsof` with a five-second bound to detect another
process holding a file open. Uncertain results refuse cleanup. This is a
conservative guard, not a guarantee that another process cannot open the file
afterward. Unexpected members, changed metadata or uncertain verification retain
data for review. Source text and remote metadata cannot grant cleanup authority.

Mutations use nonblocking per-job advisory leases shared by the app and CLI,
released on process death. Lock files are not unlinked to avoid split lock inodes.
Reconciliation reloads leased jobs and never resumes deletion automatically;
a fresh explicit approval is required. Folder roots and child jobs have their
own lease boundaries. Already-running older previews do not honor new locks;
quit old instances before updating. The CLI reads the native protected-folder
preference domain. Storage remains independent of Cloudflare availability.

## Restore and catalog recovery

No-follow directory walks and anchored file descriptors prevent path traversal
through substituted links. Downloads reject redirects/excess bytes and stream
to private staging files with manifest size/SHA-256 checks. File installation is
exclusive; complete-folder restore also validates ambiguous case/Unicode paths,
final target protection, full inventory and every staged hash before exclusive
rename. Existing files are never silently overwritten. Failure cleanup removes
only known matching staging members; altered or unexpected data stays for review.

Remote catalog recovery lists bounded pages from verified app-owned manifest
folders and checks markers before downloads. Both file records and complete
folder groups can be rebuilt with verified content/manifests. Recovered entries
are restore-only: an untrusted original path cannot authorize local cleanup.
Capacity requests reuse the narrow Google scope and do not request account
name/email for the dashboard. Drive requests use supported Google HTTPS hosts
and refuse redirects; credentials are sent in headers or form bodies.

Data forks are not complete macOS metadata backups. Unknown extended attributes
and resource forks block cleanup. Bounded OS provenance evidence must match its
verified manifest; legacy records lacking required evidence remain restorable
but cannot authorize unsafe cleanup. Restore leaves Apple's live security marker
under OS control. Original permissions, ACLs, Finder tags and full extended
metadata restoration are not claimed.

## Canonical Brain and credentials

Canonical immutable memory revisions are Markdown in a separate app-marked Drive
vault. Independent signed commit receipts bind approval/version metadata and are
checked during rebuild. The signing key is distinct from the owner credential,
kept in private Worker secrets/configuration and must be backed up. Signatures
do not encrypt content or protect against an already compromised authorized
Worker/account. D1 holds plaintext searchable content, revision/index metadata,
relationships, audits, scoped grants and operational recovery state. There is
no end-to-end encryption claim.

Drive writes and D1 are not one atomic transaction. Durable intents, preallocated
identities, version/conflict checks and recovery operations expose incomplete
writes instead of silently choosing a latest timestamp. Missing/invalid receipts,
conflicting branches or incomplete chains quarantine affected records during
rebuild. Imports do not trust approval flags and create private records for
review. Corrections/deletion are versioned; soft-deleted records disappear from
normal retrieval but prior revisions/audit history remain. There is no irreversible
purge API or automatic account-wide retention schedule.

The guided setup obtains a separate explicit Google `drive.file` grant, keeps
credentials outside Git in mode-700 directories/mode-600 files, and uploads
secrets only after concrete owner deployment confirmation. Public configuration
keeps canonical mode disabled and contains no deployment identifiers. Revocation
stops future API access, not stored-data retention, and Google project-level
revocation can affect other grants. Testing grant lifetime, fresh consent,
publication settings and credential/key rotation remain operational release gates.

## Server authorization and AI clients

Owner APIs require the independent owner credential. Read-only AI grants enforce
project scopes, approval, privacy, expiry and revocation on the server for search,
ID reads, context and archive metadata. Prompt text is untrusted content and
never an authorization input. Optional `memory_propose` permission adds Inbox
items only; no AI edit/delete/archive-removal tool is exposed. Conversations are
not automatically harvested from AI sites. Context/handoff copies are deliberate
exports to another provider.

Scoped Bearer credentials and public-client PKCE OAuth are implemented. OAuth
requires explicit owner consent, expiring authorization/access credentials,
rotating refresh and replay revocation; grants are inspectable/revocable. Search
uses prepared SQL and quoted FTS terms. Bodies/results/graph budgets are bounded.
Authorization audits must commit before retrieval data is returned. Browser
origins are allowlisted without wildcard CORS. The console keeps credentials in
tab memory and clears them on lock/reload; exports still require owner care.

Live canonical checks and installed-Codex retrieval have passed. Hosted OAuth
browser/client acceptance remains distinct from the official SDK's local tests.
No universal automatic connection or every-provider account compatibility is
claimed. See [AI connections](ai-connections.md) and [MCP OAuth](mcp-oauth.md).

## Archive metadata and remote restore intent

Publishing archive metadata requires a fresh successful health check and explicit
owner review. Visibility defaults to private. Only approved records in an AI
client's project scopes can be retrieved through read-only metadata tools. Names,
sizes, checksums, object IDs and reported state may be shared; source paths,
contents, upload capabilities and tokens are not published. Viewer links do not
change Google sharing. The separate Brain grant cannot independently read the
Mac Storage app's archives. Private nodes are filtered before graph budgets;
edges and pulses represent saved relationships and actual authorized events.

A remote request queues intent only. The Mac fetches it through an owner action,
requires a matching verified local manifest and asks for a permitted destination.
The normal exclusive restore checks still apply; missing local recovery metadata
requires catalog reconstruction. Acknowledgment follows successful restoration;
lost connectivity can leave the request pending and does not authorize a new
unattended operation. Unpublish removes Brain metadata/dismisses pending intent,
never a Drive or local archive. See [archive console](archive-console.md).

## Developer backup boundaries

Selected project capsules create new snapshots without running Git hooks/filters
or moving the original repository. Exclusions and recovery instructions are
explicit; this is not authority to offload active repositories. Docker image
export/import uses an explicitly selected existing local daemon, fixed commands
and bounded streaming. It never starts Docker, removes images or copies raw live
VM disks/volumes/database directories.

SQLite snapshots use the read-only SQLite backup API, existing safe WAL sidecars
and bounded page/verification work. They do not checkpoint/repair the source or
change its permissions. The approved payload's exact hash/size is rechecked on
restore, which publishes only into a new folder. External-writer proofs use
generated databases; arbitrary application formats require their own export.

PostgreSQL uses an explicitly selected running local Docker container, immutable
container identity, a fixed Unix socket, fixed OS user, restricted environment
and no collected passwords. Custom logical dumps are bounded, hashed and parsed
with `pg_restore --list`. Restore requires explicit trust and creates only a
fresh generated database before single-transaction restoration. Archive SQL
executes with the chosen role and can affect resources beyond that database;
this is not a SQL sandbox. Failures retain the new database and private recovery
records. Stopping a Docker client does not prove server-side work stopped.
Real disposable-container acceptance remains pending. Neither database module
grants cleanup authority over its original source. See [SQLite](database-backups.md)
and [PostgreSQL](postgres-backups.md) for exact limits.

## Source, distribution and remaining work

Credentials, private configuration/logs, OAuth JSON, catalogs and local evidence
are excluded from public checkpoints and app packaging. Staged-source auditing
supports review; it is not an independent security audit. Lockfiles are committed
and the native app has no third-party runtime package dependency. There is no
CloudNest telemetry, mandatory paid model or persistent local LLM.

Final resource profiling, Finder/login/sleep tests, real optional-container tests,
second-device access with the Mac physically off, public signing/notarization,
Intel/fresh-device QA, retention/purge and renewal/rotation procedures remain
release work. Current local ad-hoc binaries are not notarized public releases.
