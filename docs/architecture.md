# Current architecture

Storage is one native SwiftUI application and shared Swift core. SQLite owns
archive state and indexed headers; Keychain owns credentials and transfer
capabilities. One transfer and bounded streaming keep memory predictable.
Recovery is a journaled, separately approved operation. Folder member manifests,
root manifests and metadata evidence must agree before cleanup. Protected paths,
leases, no-follow descriptors and no-overwrite installation apply independently
of the Brain service.

Recommendations, FSEvents stale marking and user opt-in scheduling are event
based. Optional login startup uses `SMAppService.mainApp` rather than a second
resident process. macOS reports registration/approval state; enabling is explicit.
The native app never loads a permanent renderer or model.

Brain is a separate Worker and D1 database. Canonical immutable Markdown and
independently signed commit receipts live in app-owned Google Drive folders.
D1 holds the rebuildable index, revision cache, intents, review state, audit and
scoped grants. Pending writes suppress stale retrieval. Import and reindex jobs
are bounded and recoverable. Owner bearer and per-client permissions are distinct.

The console's ordinary UI is HTML/CSS/TypeScript. Three.js is a separate dynamic
chunk. Graph metadata is filtered on the server; recorded access is distinct
from merely configured authorization. Context and handoffs exclude private
records and never send themselves to another provider. The marketing website
is deferred.

See [security](security.md), [Brain API](brain-api.md), [MCP OAuth](mcp-oauth.md)
and [Memory Universe](memory-universe.md) for current operational contracts.
The following Phase 0 notes are retained as historical architecture evidence.

# Phase 0 design and safety boundary

The native Swift executable and CLI share one core library. SQLite owns the job state;
Keychain owns OAuth credentials and resumable session capabilities. Only manually chosen
folders are scanned. Hashing reads 1 MiB blocks; Drive sends 8 MiB chunks, sequentially.
No login helper, background polling or WebGL renderer runs. The optional
approved-folder watcher only marks changes without performing scans.
Storage has no dependency on the Brain Worker.

Archive state: queued → uploading → uploaded → verified. A job becomes verified only
after independent Drive metadata matches SHA-256 and size and a recovery manifest is
uploaded and independently verified. Source identity and hash are checked again before
the final state. Every acknowledged offset is durable. On restart, ask Drive for its
actual offset rather than trusting the local offset. Expired sessions leave originals
intact and restart with the persisted preallocated ID, making create retry-safe.

Phase 0 deliberately exposes no removal operation. Uploaded bytes are never labelled
reclaimed. Later cleanup requires a separate reviewed workflow, a fresh remote check,
source revalidation and explicit approval. Allocated blocks are an estimate: APFS clones,
compression and snapshots prevent treating their sum as guaranteed reclaimable space.

Restore treats every manifest as untrusted. It never uses the manifest's originalPath
as an implicit destination. A user-selected existing destination folder is required;
the basename is validated, a private sibling temporary file is hashed, then installed
with exclusive no-overwrite semantics. Symlink components and protected paths are denied.
There is no remote command execution or remote local-file deletion endpoint.

Brain feasibility: a stateless, JSON-response Streamable HTTP endpoint, an explicit
2025-11-25 compatibility implementation, a D1/FTS5 read-only index and per-client hashed
bearer credentials with project grants, expiry and revocation. No OAuth discovery is
claimed for this feasibility endpoint. Clients requiring interactive OAuth cannot yet
connect. Private and unapproved content is filtered in SQL before retrieval and audit.
No AI input can change credentials or authorization. No write tools exist in Phase 0.

The index is not a canonical vault yet. Local test records are labelled test fixtures.
Do not store real memories until Drive-backed canonical writes, revision conflicts,
rebuild and deletion propagation are implemented in Phase 2. Production deployment and
the external AI acceptance gate remain pending explicit account setup and live checks.
