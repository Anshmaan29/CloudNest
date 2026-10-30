# Security boundaries

No automatic file deletion exists. Permanent removal is limited to a separately
approved, CloudNest-managed recovery payload after fresh cloud and local checks. Scanning, hashing and uploads require an
explicit local source. All repositories, live database extensions, VM disks,
Photos libraries, app bundles, cloud folders, symbolic links and protected
system directories are excluded. Hard links are counted once per scan;
APFS clone/snapshot effects prevent guaranteed reclaim estimates.

The catalog is inside a mode-0700 application support folder. OAuth tokens,
client configuration and resumable upload capability URLs use a device-bound
Keychain class. Production Drive requests are restricted to Google's HTTPS
API host; redirects are not followed. Tokens are sent in headers or form
bodies and never logged. Revoke access from CloudNest or Google Account
Permissions. Revocation can invalidate all grants for the configured project.

File descriptors are opened using no-follow directory walks. Restore stages
data through anchored directory descriptors, uses mode-0600 files, streams
and hashes before an atomic `linkat` installation, and refuses overwrite.
Failed/cancelled restore attempts remove only their own temporary staging data.
Manifests are untrusted and basenames cannot contain path separators.
There is no remote local-restore execution endpoint in Phase 0.

MCP grants are SHA-256 digests of random 256-bit tokens with explicit project
allowlists, expiry and revocation. Private, unapproved and expired records
are excluded by SQL on each request, including direct ID reads and context
packs. Search is prepared SQL plus quoted FTS words. Request bodies and
returned context are bounded. Auditing must commit before data is returned.
Origins are explicitly allowed; no browser CORS wildcard is enabled.

This is a feasibility server with preconfigured bearer grants, not a complete
OAuth authorization server. Before real personal data is admitted, implement
canonical Drive transactions and recovery, OAuth where clients require it,
deployment rate limits, audit retention, durable grant management and a
credential rotation/recovery UI. No confidential vault content belongs in
the current rebuildable test index. Prompt text is never an authorization input.

No secrets are included in source, CI or packaged application. `.gitignore`
excludes local environment files, client JSON patterns, SQLite state and build
artifacts. Never copy downloaded OAuth files into the source tree. The token
generator rejects output paths inside this repository. Dependency lockfiles
are committed; npm dependencies are developer tools, not native app libraries.

Cleanup also checks for another process holding the selected file open using
the built-in `lsof`, with a five-second bound. An uncertain result blocks
cleanup. This is a conservative guard, not a guarantee that another process
cannot open a file after the check. Known database directories and extensions
are excluded independently. Active repositories require the future developer
workflow. Recovery uses exclusive same-volume renames, exact UUID payload
names and no recursive removal. Interrupted cleanup never resumes deletion
without a fresh local approval.

Restore downloads use a serial URLSession data delegate, write directly to an
anchored destination descriptor, reject redirects and excess bytes, and verify
the manifest hash before installation. Cancellation cancels the network task
and failed staging data is removed. There is no full temporary SSD copy.

## Native 0.3 storage extension

File mutations acquire a shared, nonblocking per-job advisory lock across the
app and CLI. Locks release on process death; lock files are never unlinked to
avoid creating separate live lock inodes. Reconciliation skips actively leased
jobs and reloads state after acquiring a lease. Folder runs use a separate root
job lease while each child uses its own lease. CLI reads the app's protected
folder preference domain. Already-running older previews do not honor these
new cooperative locks; quit the old app before updating.

Folder archives never remove originals. Their member files cannot be reclaimed
individually. Folder restore rejects ambiguous Unicode/case paths, validates
final target protection before installation, verifies the complete staged tree
and every file again, then uses an atomic exclusive rename. Failed cleanup of
staging removes only known matching objects; altered or unexpected staging data
is retained for review. A portable root manifest is required to rebuild groups.

Data forks are not a complete macOS metadata backup. Before local cleanup,
unknown extended attributes and resource forks cause a refusal. The bounded
OS provenance marker is recorded exactly in the verified manifest and must
match before removal. Legacy jobs lacking that evidence cannot authorize
cleanup of a file that has the marker; create a new archive instead. Restore
leaves Apple's live marker under operating-system control; the original bytes
remain in the portable manifest. Original permissions, ACLs, Finder tags and
extended metadata restoration are not claimed.

Remote file catalog recovery reads only the app-owned manifest folder's child
metadata, checks its private marker locally before downloading any content,
then verifies both manifest and referenced file. Recovered records are separate
restore-only entries. They cannot grant authority to delete a local path from
an untrusted originalPath. Google capacity checks reuse drive.file and request
only quota fields. No account name or email is requested for the dashboard.
