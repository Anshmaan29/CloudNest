> Current native version is 0.3.0. The Phase 0 design below is historical. Its
> no-removal boundary was superseded by the tested, two-step local recovery
> workflow documented in README and security.md. There is still no automatic
> deletion, Brain write API or remote local-restore endpoint.

The current native Storage app and CLI share the verified core. Folder jobs
link to persistent file transfers, retain originals, verify a portable v2 root
manifest and restore through one staged atomic no-overwrite installation.
Folder summaries and catalog pages are bounded. SQLite searchable metadata
updates transactionally with job state. App-owned remote file manifests can
rebuild separate restore-only records without granting local cleanup rights.
Quota and archive health are fetched on demand. One FSEvents watcher only marks
the chosen scan stale; scans remain user initiated. The website and browser
console are deferred. Canonical Brain writes and visualization remain pending.

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
