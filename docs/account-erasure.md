# Brain deletion, audit retention and account erasure

Individual memory deletion creates an immutable canonical tombstone. The memory
is excluded from normal search/MCP/graph retrieval; earlier revisions remain in
owner history and can be restored through the reviewed recovery workflow. This is
recoverable deletion, not irreversible removal of every historical copy.

Whole-account erasure permanently removes active-service Brain data. There is no
selective permanent-memory purge endpoint: removing selected revisions from an
existing signed checkpoint without a complete replacement protocol would weaken
history/rebuild integrity. To permanently remove all Brain history, use the
whole-account workflow below. Storage archives and their local Mac catalog remain
independent and are never deleted by Brain account erasure.

## Owner workflow

1. Export the data you want to keep before starting. Independently saved exports,
   prior backups, assistant context packs and copies held by other people cannot
   be recalled by CloudNest.
2. Open **Privacy, retention and erasure recovery** in the console. This collapsed
   panel remains available when ordinary sign-in is unavailable. Import the current
   owner recovery connection JSON locally. It must belong to this exact HTTPS
   Brain origin; the token remains in tab memory and is not put in a URL, DOM
   password field, log, browser storage or source repository.
3. Choose **Prepare account-erasure inventory**. This freezes ordinary Brain
   reads/writes until cancellation or completion; it does not delete canonical
   content. Inspect the recognized canonical-object count, byte count and count
   of preserved unrelated objects. The inventory includes trashed canonical
   objects too. Unknown objects and the Brain root folder are preserved rather
   than recursively deleted.
4. Before approval, **Cancel preapproval review** releases maintenance without
   deleting canonical objects. After reviewing, type **ERASE CLOUDNEST BRAIN** and
   choose **Approve permanent account erasure**. This is irreversible. Browser
   credentials, managed clients and OAuth tokens/clients are removed immediately;
   this deployment is permanently disabled for normal use.
5. Choose **Continue permanent erasure**. The open page runs sequential bounded
   steps: at most five immutable, reviewed files are deleted per backend request,
   then a fresh folder inventory checks for remaining canonical objects. Closing,
   pausing or losing the page does not discard the server job. Import the owner
   recovery file again and choose **Load privacy status** to resume the same job.
   Browser/AI credentials cannot resume erasure; this is deliberately a
   Recovery-Bearer-only endpoint.
6. A changed object stops deletion of that object. **Review changed or newly added
   objects** refreshes the inventory and requires a new explicit approval; it
   does not undo prior deletions or silently broaden consent. If an object was
   moved out of the reviewed vault or its ownership changed, restore its binding
   or remove that exact item yourself through Drive before resuming. Do not grant
   broad Drive permissions or delete unrelated objects to work around the error.
7. Download the minimal completion receipt, then complete the credential/provider
   cleanup below. Ordinary use cannot silently recreate the erased account. A new
   Brain requires a deliberately reviewed fresh setup/database.

The backend uses Google Drive's documented [`files.delete`](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/delete),
which permanently deletes an owned file rather than using Trash. It checks the
configured app-created root, the current Google account's ownership/deletion
capability, private canonical markers, exact frozen ID/size/hash and parents before
each delete, and verifies a subsequent 404. It sends a conditional ETag when one
is supplied, but does not claim an external-editor race is fully fenced by the
Drive v3 delete contract. Stop other editors from changing the vault during
approval/erasure. No recursive folder deletion or account-wide Trash operation is
used. A lost deletion acknowledgement is recovered by rechecking the same ID.

## Retention and exact boundaries

During erasure, the private operational inventory contains Drive IDs, immutable
metadata and progress, never canonical bodies. On completion it is removed.
Current memories, revisions, tombstones, search/FTS index, proposals, conversation
provenance, import state, archive-publication metadata, restore requests, audit
records and authentication/authorization rows are removed from the application's
D1 tables. The retained completion row contains only a random operation UUID,
state, dates, counts and byte counts; folder IDs, content hashes, request cursors,
client IDs and memory IDs are scrubbed. One disabled-account flag prevents normal
service and reindex resurrection. The empty root and unrelated Drive items remain.

This is active-service/application-level deletion. Cloudflare D1 Time Travel,
provider retention, database freelists, Google operational backups, independently
exported databases and local recovery bundles are outside the Worker API's
physical-erasure control. Delete owner-controlled exports/backups separately if
that is your intent, and follow the providers' current retention procedures. Do
not claim forensic overwrite or immediate deletion from provider backups. Never
restore an old database backup into an enabled deployment without reapplying its
erasure decision and credential revocations.

## Access-audit retention without deleting memories

The same privacy panel previews access logs older than a chosen age. A fixed UTC
cutoff, maximum reviewed audit ID, count and digest bind the approval. Type
**DELETE OLD ACCESS LOGS** to approve; **Continue audit cleanup** removes at most
200 matching records per backend request. New/backdated records with IDs above
the reviewed high-water mark are excluded. Canonical content, tombstones and
revision history are never pruned by this operation. An unapproved review can be
cancelled. There is no background pruning or cron task. Content-free plan receipts
remain for retry/audit until whole-account erasure clears them.

## Credential and provider deprovisioning

Only after a verified completion receipt:

- Export/download the receipt if desired. No credential values are included.
- Remove the dedicated Brain Worker's Google refresh/client secret, owner verifier,
  signing keys and any static MCP credential configuration using the Cloudflare
  account's authenticated management tools. The Worker intentionally has no
  Cloudflare management token capable of deleting its own secrets.
- Retire the corresponding prepared setup manifests so a later deployment cannot
  re-upload old credentials or accidentally re-enable an obsolete backup. Remove
  owner-controlled recovery connection copies/Keychain Brain entries when no
  longer needed. Do not touch the independent Storage Keychain grant/catalog.
- Revoke the dedicated Brain Google grant through the owning Google account if
  desired. First verify that its Google project is separate from Storage: Google
  revocation can affect other grants in the same project. Never blindly revoke a
  shared project or the Mac Storage grant.
- Decide separately whether to delete the disabled Worker/database and any
  provider backups. Do not treat deleting a Worker as proof its canonical Drive
  records or retained backups were erased.

No live personal account erasure, provider deletion or credential revocation was
performed while implementing these features. Automated destructive tests use
only generated fixtures and a fake Drive service.

## Integration contract

Apply `0010_account_erasure.sql` before deploying these routes. It creates
INSERT/UPDATE fences on ordinary application tables whenever `erasure_lock` or
`account_erased` exists. Erasure job/inventory tables are exempt; the erasure
implementation uses DELETE for ordinary rows. Virtual/shadow FTS tables are not
fenced because deleting `memories` must update FTS. Future application tables need
the same trigger coverage and erasure-table registration.

After existing HTTPS/host/Origin checks, before the normal owner/session gate and
availability checks, call `handleAccountErasure(request,env,path)`. It independently
requires the current owner recovery Bearer. Before every ordinary REST/MCP/OAuth
operation, call `assertErasureAvailable(env)` for helpful 503/410 errors. SQL
triggers supply the atomic barrier against older in-flight writes. Preparation
atomically refuses pending canonical intents, unfinished imports and reindex/key
rotation maintenance. Canonical writes already hold durable intents before any
Drive upload, so deletion cannot race a new unclaimed canonical writer.

Account routes under `/api/v1`: `GET /account-erasure`, `POST
/account-erasure/prepare {requestId}`, then `POST /account-erasure/:id/{scan,
approve,resume,rescan,cancel}`. Only approval accepts `{digest,confirmation}`;
other steps require `{}`.

After the ordinary owner authorization/CSRF and availability gates, call
`handleAuditRetention(request,env,path)`. Routes: `GET /audit-retention`, `POST
/audit-retention/preview {requestId,days}`, then `POST
/audit-retention/:id/{approve,step,cancel}`. Approval accepts `{digest,confirmation}`;
other steps require `{}`. Its own SQL guards and database fences prevent late
privacy writes after account erasure begins.
