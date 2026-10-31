# Archive metadata in the companion console

The Mac can explicitly publish selected verified archive metadata to the Brain's
D1 catalog. Storage continues working when this service is unavailable. Publishing
does not move a file, free local space, change Google sharing or grant another
OAuth application access to archived data.

## Owner workflow and permissions

Run a fresh successful archive health check, review the filename and project,
then publish. The default visibility is **private**. Choosing **approved** allows
read-only Brain clients authorized for that project to retrieve the metadata.
Names themselves can contain private information: approve deliberately. Updates
are explicit metadata refreshes, not automatic Drive indexing.

Only archive UUID, filename, kind, byte count, optional checksum/file count, Drive
object identifiers, health-check timestamp and last Mac-reported local state are
accepted. Full source paths, file contents, health-detail text, upload sessions and
tokens are not accepted or sent by the Core bridge. Health reports must match the
job UUID, be healthy and be at most five minutes old. Publication is refused if
that evidence becomes stale while the owner is reviewing it.

Local state is historical metadata, not a live filesystem check. The factories
report `recovery`/`removed` only for those explicit journal stages, and otherwise
use `unknown`. They do not assume that an original still exists because it was
once cataloged. The remote service cannot independently verify a Storage archive:
its dedicated Brain Google grant cannot read files created by the separate Mac
Storage OAuth app. It neither proxies file contents nor broadens that grant.

Drive URLs contain a validated object identifier only. Opening one still requires
Google sign-in and Drive authorization. No sharing permission or signed/public
capability link is created. Files use `https://drive.google.com/file/d/ID/view`.
A genuinely identified Drive folder can use `/drive/folders/ID`. Current CloudNest
folder archives consist of separately stored members and a portable root manifest;
the Mac therefore publishes `driveTarget: "manifest"` and links the actual manifest
file. It never invents a Drive folder ID. Folder SHA-256 covers the encoded root
manifest, and `fileCount` comes from the complete verified local job.

## Owner REST contract

Apply append-only migration `0006_archive_catalog.sql` after the earlier migrations.
All routes require the dedicated owner bearer credential, enforce request limits,
use `Cache-Control: no-store`, and commit authorization audits before returning
metadata. These metadata routes work independently of the canonical Brain Google
connection; canonical memory routes retain their existing configuration checks.

- `POST /api/v1/archives/publish` accepts `{project, visibility?, archives}` with
  1–20 distinct records and a 64 KiB request budget. Visibility defaults to
  `private`. Each record contains `id`, `name`, `kind`, `bytes`, optional `sha256`,
  `driveFileId`, `manifestFileId`, optional `driveTarget`/`fileCount`, `checkedAt`
  and `localState`. Returns `{archives}` with server-generated viewer links and
  `publishedAt`. A later explicit publication replaces metadata for that UUID.
- `GET /api/v1/archives?query=&project=&cursor=&limit=` returns
  `{archives, cursor}`. Search is a literal filename substring; UUID pagination is
  deterministic and limited to 100 rows. Owner reads include private records.
- `GET /api/v1/archives/:id` returns `{archive}`.
- `DELETE /api/v1/archives/:id` unpublishes metadata and dismisses its pending
  restore intent. It never deletes a Drive object or local file.

Restore requests are durable intent only:

- `POST /api/v1/restore-requests` accepts only `{archiveId}` and returns
  `{request: {id, archiveId, status: "pending", createdAt, acknowledgedAt: null}}`.
  The owner can queue a private archive. Unknown publications are refused.
  Repeated requests return the existing pending request; at most 100 are pending.
- `GET /api/v1/restore-requests` returns `{requests}` containing at most 100 pending
  requests. No destination or unattended operation is included.
- `POST /api/v1/restore-requests/:id/ack` accepts
  `{status: "completed" | "dismissed"}`. An identical acknowledgment is idempotent;
  changing a terminal status is refused.

The Mac must fetch this queue only through an explicit owner action, review the
matching local archive, ask for a destination, and use existing checked restore
operations. A missing local catalog requires a supported catalog rebuild first;
never guess original paths from remote metadata. Mark completed only after the
restore succeeds. Losing connectivity before acknowledgment leaves the request
pending; it does not authorize another unattended restore. A request may be queued
while the Mac is off, without implying that restoration has started.

## MCP and graph

Configured canonical MCP endpoints advertise read-only `files_find {query?,project?}`
and `files_status {id}`. Responses contain `{archives}` only, with no file contents.
Approved visibility and the client's authorized projects are applied in SQL before
the result budget. A private, missing or cross-project UUID returns no records.
Every returned archive is audited; an audit failure suppresses the response. The
MCP endpoint exposes no publication, unpublish or restore-request mutation tools.

The owner graph shares its existing total node budget between approved memories
and approved archive metadata. Archive nodes have `nodeKind: "archive"`, real
archive UUIDs, the published metadata and explicit manifest/file targets. An edge
appears only for an actual saved relationship from a visible memory to a visible
archive UUID. No inferred connections or simulated access events are added. Events
come from actual authorized retrieval audit records. Identifier collisions with
memory records fail closed, and private nodes are filtered before the budget.

## Native Core integration and verification

`BrainArchivePublication.verifiedFile` and `.verifiedFolder` require the corresponding
healthy report. The folder factory requires a full job/manifest, not a list summary.
`BrainArchiveCatalog` reads only the atomic Keychain `brain-owner-connection`
`{origin,token}` pair; it never reads Mac Google credentials. It accepts HTTPS or
strict loopback HTTP, refuses redirects, isolates cookies/credential storage, and
bounds responses to 512 KiB. Publication and queue functions have no background
hooks and must be called only after explicit owner actions. Returned Drive viewer
links are checked again on the Mac.

Local tests use generated credentials, fake storage objects, Miniflare D1 and
loopback HTTP servers. They cover private defaults, project isolation before
budgets, strict links, no external Drive calls, queue limits/deduplication,
acknowledgment conflicts, audit rollback, real graph references, freshness checks,
path-free payloads, response bounds and cross-origin redirect denial. No live user
archive, Keychain record, Google token or cloud deployment is inspected by tests.
Live publication and a real queued restore remain release checks. UI integration,
owner deployment and migration application are separate from this backend change.
