# Privacy and data retention — development preview

This document describes the current implementation and owner-managed deployment.
CloudNest is not a managed consumer service or a production 1.0 release. Review
[release readiness](release-readiness.md) before relying on unattended access.

## Where data lives

- **On your Mac:** a private local catalog holds selected paths, file identities,
  hashes, transfer progress, archive/recovery records and portable manifests.
  Settings hold approved/protected folders and opt-in policies. Google OAuth
  configuration, tokens and resumable upload capabilities use macOS Keychain.
  The native Brain owner credential is saved in Keychain after explicit import
  or connection setup; it is separate from the Mac's Google authorization.
- **In your Google account:** explicitly archived content and recovery manifests
  live in app-created Storage folders. Manifests contain original paths for
  recovery reference, including paths embedded in folder manifests. A separate
  CloudNest Brain vault holds portable Markdown memory revisions and signed
  commit receipts. Memory text, source and permission/version metadata are not
  encrypted by CloudNest before storage. Storage and Brain use separate,
  explicitly approved Google grants with the narrow `drive.file` scope.
- **In your Cloudflare account:** Workers process authenticated Brain requests.
  D1 stores plaintext searchable memory content, revision/index metadata,
  relationships, Inbox proposals, access/change audits, client scopes and
  operational recovery state. Selected archive metadata and restore intents
  are stored only after explicit publication/request actions. This deployment
  is no longer a disposable feasibility-only memory store.
- **In private configuration and backups:** the guided setup bundle contains
  server credentials, the owner credential and the independent vault signing
  key. Keep it outside Git, privately backed up and restricted to its owner.
  Server-side Google credentials and signing material are uploaded only through
  an explicitly approved Worker-secret setup. Losing the signing key prevents
  automatic trust of existing receipts during rebuild; do not replace it casually.

CloudNest does not provide end-to-end encryption. HTTPS and Keychain protect
specific transport/credential boundaries; Google, Cloudflare and authorized
account administrators remain part of the data trust boundary. Receipt signatures
protect approval/version evidence during recovery, not the secrecy of memory text.
Provider access, storage and retention policies apply independently.

## What is collected and shared

Storage scans only approved local folders. Event-driven stale marking and opt-in
scheduled recommendations do not authorize uploads or deletion. The app does not
automatically index unrelated Drive files or scan an entire home directory.
System paths, cloud placeholders, live databases and repositories remain excluded
from ordinary archiving. Separate developer backup tools require explicit review.

Brain memories come from owner actions, selected imports and reviewed proposals.
CloudNest does not automatically collect conversations from AI websites. AI clients
receive read-only, project-scoped access by default; an optional proposal permission
adds items to the Inbox. Private, unapproved, deleted or out-of-scope memories are
excluded from client retrieval. Context packs and handoffs are deliberate exports:
anything you copy into another assistant becomes subject to that provider's policy.

Archive publication sends reviewed names, sizes, checksums, Drive object IDs,
project/visibility and health/local-state metadata, not source paths, contents,
tokens or upload sessions. Visibility defaults to private. Filenames can themselves
be sensitive. Choosing approved visibility exposes metadata only to clients scoped
to that project; it does not change Google sharing or grant file-content access.
The Brain's separate Google grant cannot read the Mac Storage app's archives.
Graph responses use authorized records and real relationships/access events.

No CloudNest analytics, advertising, automatic crash-report upload or mandatory
model inference is implemented. Operational audit records are intentional security
records, not third-party telemetry. No paid model API or continuously running local
model is required. Normal storage/memory use does not keep a GPU renderer running.

## Controls and retention

You choose sources, uploads, restore destinations and cleanup. Uploads retain
originals. Files and eligible complete folders support a separately approved move
into managed local recovery, offline put-back, and a second explicit permanent
removal approval after fresh integrity checks. Interrupted deletion requires new
approval. Unknown metadata or uncertain verification blocks removal. Unrelated
Trash is never emptied. APFS snapshots/clones can retain bytes after managed
removal, so a logical file size is not a guaranteed free-space gain.

A remote restore request is queued intent. It supplies no local destination and
cannot start an unattended restore. The Mac owner must review a matching verified
manifest and select a permitted destination; existing content is not overwritten.
Unpublishing an archive removes its Brain catalog metadata and dismisses pending
requests. It does not delete the archive in Drive or on the Mac.

Memory deletion is a versioned soft delete. Deleted records are hidden from normal
retrieval and can be restored by the owner; prior revisions, canonical files and
audit history are retained. There is no irreversible memory-purge API or automatic
account-wide erasure/retention schedule. Revoking a client stops future access;
it cannot retract previously copied context or exports. Revoking Google access
stops future authorized API use but does not erase stored cloud files.

Memories can be exported as Markdown or JSON, and archive manifests remain portable.
Review exports and generated SQLite/PostgreSQL/project backup artifacts as private
data. They are not uploaded automatically. A memory export is not a complete backup
of operational audits, credentials or every D1 record. Preserve signing/configuration
backups separately. Removing the application does not remove cloud data, the local
catalog or recovery records; see [installation](installation.md) for deliberate
uninstall and [guided setup](brain-guided-setup.md) for credential handling.

## Public source and limits

Public checkpoints exclude credentials, deployment identifiers/endpoints, local
catalogs, private logs, screenshots and test content. The staged-source audit is
a guard alongside review, not a guarantee that every future change is safe.
Runtime Keychain contents and local catalogs are not packaged with the app.
Release binaries are stripped before local signing.

Bounded OS provenance evidence can be present in archive manifests. It is not
applied to restored files; macOS controls its live security marker. Unsupported
resource forks or extended metadata block cleanup rather than being discarded.
This is not a complete macOS metadata backup or a security certification. Account
consent lifetime, retention controls, hosted OAuth acceptance and release-device
checks still have the limits recorded in [release readiness](release-readiness.md).
