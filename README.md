# CloudNest OS

A native personal-cloud utility and an independent AI memory vault.
Swift 6 + SwiftUI, Google Drive, Cloudflare Workers and D1. No Electron,
mandatory model API, local LLM, or always-running Mac is required for the Brain.

This repository contains working implementations, with release gates tracked in
[release readiness](docs/release-readiness.md) and measured evidence in the
[verification ledger](docs/verification.md). Public signing and real-provider
checks must not be inferred from a passing local test suite.

## Native Storage

- SSD dashboard and ranked Free Up Space recommendations from approved folders.
  Age and size are heuristics, never proof that a file is inactive.
- Resumable, persistent file and complete-folder uploads. Every content object
  and recovery manifest must match remote size and SHA-256 before cleanup.
- Separate approvals to move originals into managed local recovery and to
  permanently remove verified managed copies. Put back works offline. Interrupted
  folder removal never resumes deletion without a fresh approval.
- Streamed, verified restores with exclusive installation and no overwrite.
  Portable manifests and restore-only catalog reconstruction work after catalog loss.
- Searchable Archive Library, on-demand health/quota checks, paged Recovery Center,
  durable Activity, protected folders, event-driven stale marking, opt-in scheduled
  recommendations, power/network policies, upload pacing and safe transient retries.
- Menu bar, keyboard palette, reviewed drag/drop, Finder Services declarations,
  notifications and opt-in macOS login startup. No replacement filesystem or
  access to Google Drive's private cache.

Cleanup remains conservative. Unknown extended metadata, links, active databases,
repositories, cloud placeholders and system paths are protected. New folder
archives record the evidence needed for approved cleanup; legacy root manifests
remain restorable but cannot authorize destructive cleanup. APFS clones,
snapshots and concurrent disk activity affect observed free-space increases.

## Brain and AI connections

Canonical memory revisions are portable Markdown in a separate app-created
Google Drive vault. Independently signed commit receipts protect approval
metadata during index rebuild. D1 contains the searchable index, revisions,
relationships, audit and recovery state. Preserve the private vault signing key.

Owner-authorized create/edit/correct/delete/restore operations use immutable
revisions and conflict checks. AI proposals stay in a review Inbox. Imports
create private records and durable resumable jobs; imported approval flags are
never trusted. Keyword/project search, history, JSON/Markdown exports, context
packs, reviewed merges and editable **Continue in Another AI** handoffs are implemented.

Remote MCP uses HTTPS, project-scoped read access and optional Inbox proposals.
PKCE OAuth has explicit owner consent, expiring credentials, rotating refresh,
replay revocation and inspectable grants. Preconfigured scoped Bearer clients
also work. Provider capabilities and verified connections are distinguished in
[AI connections](docs/ai-connections.md); unsupported chat websites can use
copied context packs without a paid model API.

The functional browser console includes search, Inbox, editing, revision and
deleted-memory recovery, import/rebuild recovery, exports, client management,
audit, and the Memory Universe. Credentials stay in tab memory and clear on
lock/reload. The marketing website remains deferred.

Galaxy and Orbit render backend-provided relationships and recorded accesses.
Three.js loads only on entering 3D; hidden/unfocused views pause and closed
views dispose their renderer. Low/Balanced/Cinematic presets, bounded nodes,
project/category/source/date filters, keyboard selection, reduced motion and an
accessible list are available. Empty data never produces invented activity.

## Developer backups

Project Time Capsule copies a selected Git workspace into a verified portable
snapshot, excluding credentials, Git internals and regenerable dependencies.
It records exclusions, Git state and a recovery checklist, without running
repository hooks or filters. Original repositories remain untouched.

Optional Docker image export/import uses an existing local daemon only after
an explicit action. It verifies immutable image identity, bounded streaming and
manifests. It does not start Docker, remove images, or copy live VM disks,
volumes or database directories. See [developer](docs/developer.md) and
[Docker](docs/docker.md) safety and verification limits.

## Build and run

macOS 14+, Swift 6; Node is needed for cloud development and verification.
The native app has no third-party runtime packages. Three.js is a web-only
runtime dependency; the Worker has no npm runtime SDK dependency.

```sh
npm ci
npm run check
npm run build:mac
open build/CloudNest.app
```

The build creates a local ad-hoc signed app and ZIP. Optional `bash
scripts/build-dmg.sh` creates a drag-to-Applications DMG. These are not evidence
of Developer ID signing, notarization, Intel compatibility or fresh-device QA.
See [installation](docs/installation.md).

Import your Desktop OAuth JSON in native Settings and sign in to Google.
Credentials and resumable session capabilities stay in Keychain. Start with a
disposable folder, verify upload and restore, then separately review cleanup.
Google Drive for desktop Stream mode supplies Finder access independently.

For the independent Brain, follow [private guided setup](docs/brain-guided-setup.md).
It obtains a separate, explicit Google grant, preserves signing keys, targets
existing free-tier resources, and never copies the Mac's Google refresh token.
Testing-mode Google grants can expire after seven days; consent publication and
long-term account availability must be checked before relying on unattended use.

```sh
npm run build:console
npm run dev:brain
```

Cloud configuration defaults to disabled canonical mode and placeholder resource
IDs. No credentials, account endpoints, personal catalogs, uploaded references,
or downloaded OAuth JSON belong in Git. `npm run audit:source` checks staged
source before public checkpoints.

The CLI exposes the same safety core; run `build/cloudnest` for commands.
[Native workflows](docs/native-workflows.md), [Brain API](docs/brain-api.md),
[MCP OAuth](docs/mcp-oauth.md), [security](docs/security.md), and
[architecture](docs/architecture.md) document operational behavior and limits.
