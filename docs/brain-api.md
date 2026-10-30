# Brain owner API contract

All `/api/v1/*` requests require HTTPS (loopback HTTP for local tests only),
`Authorization: Bearer <owner token>` and an allowed browser origin when Origin
is present. Only its SHA-256 digest is configured in `OWNER_TOKEN_SHA256`.
Owner credentials never go to AI clients. JSON mutations need Content-Type
application/json. Errors are `{error:string}` with HTTP 400/401/403/409/429/503.
No token belongs in URLs, localStorage, source, logs or public configuration.

Canonical mode requires `BRAIN_ENABLED=true` and dedicated, explicitly authorized
server-side Google secrets. The existing Mac's token must not be copied silently.
Missing configuration returns 503; the old read-only feasibility MCP remains
available when canonical mode is disabled.

`MemoryRecord`: `{id, project, title, body, source, category, visibility,
operationId, requestHash, revision, parentRevision, version, createdAt, updatedAt, expiresAt, relationships,
confidence, deleted}`. visibility is approved/private; confidence is one of
user-confirmed/imported (AI proposals remain unapproved Inbox). relationships
are `{target:string,type:'references'|'belongs_to'|'supersedes'|'related'}`.
Canonical records are immutable Markdown revisions with separate HMAC-signed, verified immutable commit receipts; deleting writes a recoverable tombstone. Historical content remains in Drive until an explicit future permanent-erasure workflow is implemented.

Routes (API prefix `/api/v1`):

- GET `/status`: `{configured:boolean, canonical:boolean, pending:number}`.
- GET `/memories?query=&project=&cursor=&limit=20`: `{memories:MemoryRecord[],cursor:string|null}`; owner includes private, excludes deleted/expired.
- POST `/memories`: body `{id?:UUID,project,title,body,source,category?,visibility?,expiresAt?,relationships?,confidence?}`. Response `{memory:MemoryRecord}`.
- GET `/deleted?cursor=&limit=20`: `{memories:MemoryRecord[],cursor:string|null}` owner recovery list containing tombstones only.
- GET `/memories/:id`: `{memory:MemoryRecord}` (404 absent/deleted).
- PATCH `/memories/:id`: body includes `expectedRevision:UUID` plus editable memory fields. Response `{memory:MemoryRecord}`; 409 for stale/incomplete writes.
- DELETE `/memories/:id`: JSON `{expectedRevision:UUID}`. Response `{memory:MemoryRecord}` tombstone; stale reads suppressed before Drive writes.
- GET `/memories/:id/history`: `{revisions:MemoryRecord[],cursor:number|null}` ten records per page; query `beforeVersion=<cursor>` and use returned numeric `cursor` to read older pages.
- POST `/memories/:id/restore`: `{expectedRevision:UUID,revision:UUID}` makes a new revision from an earlier record. Response `{memory:MemoryRecord}`.
- GET `/inbox`: `{proposals:Proposal[]}`. Proposal `{id,clientId,project,title,body,source,category,createdAt,status}`.
- POST `/inbox/:id/approve`: optional edited memory fields + `{visibility?:'approved'|'private'}`. Response `{memory:MemoryRecord}`.
- POST `/inbox/:id/reject`: `{}`. Response `{rejected:true}`.
- GET `/export?cursor=&limit=20`: `{memories:MemoryRecord[],markdown:{id:string,text:string}[],cursor:string|null}`; includes tombstones for portable state export.
- POST `/import`: `{memories:MemoryInput[]}` max20 records and 512 KiB per batch; creates new IDs with confidence imported and private visibility. Source-file visibility is never treated as permission; approve each imported fact explicitly after review. Internal relationship IDs remap together; unresolved external references are retained and reported. Response `{memories:MemoryRecord[],complete:boolean,cursor:string|null,processed:number,total:number,unresolvedReferences:[]}`. Two records are processed per request; repeat POST with `{cursor}` until complete. Tombstones remain deleted. A failed step retries the same durable IDs; never silently overwrites.
- POST `/reindex`: `{}` starts a rebuild. Response `{indexed:number,conflicts:string[],scanned:number,complete:boolean,cursor:string|null}`. Repeat POST `{cursor}` until complete; each step downloads at most20 marked objects. GET status includes `reindexJob` for resuming after reload. Missing blobs/receipts, incomplete chains and conflicting branches quarantine the entire affected memory instead of resurrecting an older approved version. The rebuild budget is 100000 directory objects / 10000 revisions. Index replacement is atomic and the previous index stays hidden during maintenance. No latest-timestamp-wins.
- GET `/context?project=&query=`: `{text:string,memories:MemoryRecord[]}` bounded approved owner-selected context (private excluded).
- POST `/handoff`: `{project,task,objective?,progress?,unresolved?,nextAction?,references?:string[]}`. Response `{text:string,memories:MemoryRecord[]}`; editable manual handoff, not automatic chat synchronization.
- GET `/graph?project=&limit=200`: `{nodes:GraphNode[],edges:GraphEdge[],events:[],clients:[]}` real approved metadata only (no bodies), up to600 nodes / 2000 visible edges, plus actual authorized retrieval audit events. Clients appear here only if they actually retrieved visible memories. `truncated`, `nodeBudget` and `edgeBudget` describe limits. No fabricated activity.
- GET `/suggestions?project=`: `{duplicates:[],possibleConflicts:[]}` deterministic exact-body/same-title suggestions requiring manual review, not numerical confidence or semantic certainty.
- GET `/clients`: `{clients:[]}` configured grants, scopes, expiry, revocation and actual lastSeen audit time. No credential hashes/tokens returned.
- POST `/clients`: `{id,projects,permissions?:["propose"],expiresAt}` creates an independently revocable grant expiring within90 days; returns `{client,token,warning}`. Raw token is shown once and only its SHA-256 is stored.
- POST `/clients/:id/revoke`: `{}` -> `{revoked:true}` for static or managed grants.
- GET `/audit`: `{events:[]}` bounded last100 access/modification records, never query or token text.
- GET `/operations`: `{operations:[{operationId,memoryId,createdAt}]}` incomplete writes (no credentials).
- POST `/operations/:operationId/resume`: `{}` resumes the same immutable, preallocated-ID write. Response `{memory:MemoryRecord}`.

Use a UUID `Idempotency-Key` header for POST/PATCH/DELETE writes and retain it
for retries. Pending writes are hidden from normal retrieval until recovered.
Google writes and D1 are not an atomic distributed transaction: durable intents
and immutable IDs make this failure explicit and recoverable.

AI MCP grants remain read-only by default. Only a grant explicitly containing
`permissions:["propose"]` exposes `memory_propose`; proposals never enter the
approved search index until an owner approves. No AI edit/delete tool exists.

## Deployment and genuine acceptance gate

Apply both numbered D1 migrations before enabling canonical mode. Keep
BRAIN_ENABLED=false in public templates. Dedicated Google server authorization
must request drive.file. Set an independent random 256-bit hex VAULT_SIGNING_KEY, the Google client ID,
confidential client secret and refresh token only through private Worker secrets after the owner explicitly
authorizes that server-side connection. A configured secret's shape is not a
claim of a live Google acceptance test. The public health response deliberately
keeps readyForPersonalData false until release acceptance is recorded.

The server discovers a separate app-marked CloudNest Brain folder, creates
immutable UUID-named Markdown/receipt files there and validates the folder's
marker again before writes. It never scans the Storage archive or unrelated
Drive directories. Preallocated IDs are persisted before any upload. Redirects
are not followed; source/header credentials are never forwarded elsewhere.
Google failures preserve durable write intents. Reads of affected memories
remain suppressed until explicit recovery succeeds.

All response bodies are bounded to2 MiB. Memory list pages cap20, export pages
cap5, Inbox cap20, history cap10. Unicode content remains complete in owner edit
responses; context packs explicitly label body excerpts. Rate limits apply to
authenticated owner/client requests and are independent of provider free-tier
quotas. No paid model inference, runtime SDK or always-running Mac is required.

Reindex staging is operational recovery data; original revision content and
soft-deleted history remain portable in Drive. Full irreversible account erasure,
atomic multi-memory merge, selective conversation-export parsers, and interactive
MCP OAuth/discovery are not implemented by these routes. Unsupported clients
can use the explicit context/handoff text, not automatic website synchronization.

Approval receipts are signed by VAULT_SIGNING_KEY, not just self-checksummed.
A Drive editor cannot forge approved/private metadata by editing both a memory
and its checksum file. Rebuild rejects invalid signatures before index
replacement. Keep this independent key backed up privately; key loss requires
explicit reapproval/import of portable records rather than blindly trusting
file metadata. Key rotation with retained historical verification keys is not
yet exposed; do not replace the key on an existing vault without a migration.
