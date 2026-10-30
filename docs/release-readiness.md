# Release readiness

CloudNest remains a verified local preview. The complete product is not
production-ready. The native Storage increment is version 0.3; the independent
read-only Brain feasibility service remains 0.1. Website and web console work
is explicitly deferred by the user.

## Available in this increment

- Native SSD dashboard, approved-folder scanner, bounded duplicate hashing,
  progress/cancellation, protected folders and event-driven stale marking.
- Verified resumable file uploads, portable manifests, direct streamed restore,
  two-step approved file recovery/removal and observed free-space accounting.
- Persistent folder uploads with nested/empty directories, portable root
  manifests, retry/resume and atomic no-overwrite folder restoration.
- Bounded Archive Library search and state filters, on-demand cloud integrity
  metadata checks, account quota preflight and restore-only remote file catalog
  recovery. Recovered records never grant local cleanup authority.
- Reproducible native bundle, original generated icon, ZIP and optional
  drag-to-Applications DMG with explicit preview status.

## Blockers and deferred work

1. **Storage:** folder-wide safe cleanup, remote folder-group discovery,
   extended attributes/permissions/hard-link preservation, resume of partially
   restored folders, disk-space preflight, network/battery constraints, scheduled
   recommendations, larger catalog profiling and broader crash/sleep/offline QA.
   Folder archives have a 10,000-entry/64-level budget. Per-file original paths
   are present in remote manifests and must be treated as private metadata.
2. **Brain:** canonical Drive Markdown vault, writes/revisions/conflicts,
   Inbox approval, private memory rules, export/import and index rebuild. No
   personal data should be admitted to the existing feasibility index.
3. **Connections:** interactive MCP OAuth/discovery for clients requiring it,
   broader provider validation, manual context bridge and cross-AI handoff UI.
4. **Native product:** guided nontechnical account onboarding, complete keyboard
   and accessibility audit, Finder actions, notifications, activity/restore
   history, transfer policies and all remaining functional destinations.
5. **Visualization/developer tools:** real graph APIs, Memory Universe, project
   hibernation and consistent Docker/database backup workflows are pending.
6. **Public distribution:** Developer ID identity, Apple notarization, verified
   updates, fresh-install tests on supported systems, OAuth publishing review,
   long-duration energy measurement, retention/deletion controls and legal review
   of release privacy wording. No paid membership or service has been purchased.

No website/console/3D shell is supplied as a substitute for these missing
capabilities. See [verification](verification.md) for measured evidence rather
than inferring acceptance from a successful build or an ad-hoc signature.
