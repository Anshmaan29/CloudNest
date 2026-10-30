# CloudNest OS

A native macOS storage utility and an independent, portable AI memory system.
Swift 6 + SwiftUI. Cloudflare Workers + D1. No Electron, model API, local LLM,
container or always-on server is required to run the core application.

**Current delivery: working Storage preview; Phase 0 core feasibility passed.**
This is a verified increment, not the complete six-phase product. The public
[plan.md](plan.md) generalizes account-specific details from the supplied plan. Archiving retains originals. The Storage
preview also has an explicit two-step, verified local reclaim workflow.

## Run the native application

macOS 14+, Swift 6 toolchain. Build on your Mac's architecture:

```sh
npm run build:mac
open build/CloudNest.app
```

The app includes the real SSD dashboard, folder picker/scanner, Google desktop
OAuth, upload/verify, persisted queue, retry/resume and verified restore actions.
The menu-bar utility exposes folder scanning and disk availability. One FSEvents
stream marks the selected folder stale without rescanning. No resident helper,
polling task or WebGL renderer runs. The app does not start on login.

The local ad-hoc signed application needs no paid Apple Developer membership.
It is not notarized for public distribution. The build ZIP follows your host
architecture; Intel builds have not been tested here.

## Connect your accounts

Follow [Account setup](docs/setup.md) for Google project **cloudnest-os**, a
**Desktop App** OAuth client, and Worker **cloudnest-brain**. Sign-in is done
in your browser. Tokens, OAuth configuration and upload session URLs go to
macOS Keychain, never the catalog, manifests or repository.

Start with disposable files. Choose an approved folder, adjust minimum size and
modified-age rules, archive a file, and restore it into a different empty folder.
Safe/Balanced/Aggressive presets are dry-run rules, never autonomous actions.
Duplicate hashing is opt-in and limited to a 2 GB read budget. Protected folders
persist across launches. Repositories and database storage remain excluded.

After testing restore, **Reclaim…** re-verifies Drive and moves one original
into a private `.cloudnest-recovery` folder on its original volume. This move
frees no space. **Put back** reverses it without overwrite. **Remove copy…**
requires a second explicit approval and fresh cloud/local integrity checks. It
removes only that managed payload, never another file or Trash item. Open files
and uncertain file-use checks block cleanup. Free-space increases are measured
filesystem deltas, affected by APFS and concurrent disk activity. They are not
file-size promises or a current net-space balance after later restores.

Use **Restore from manifest…** if the original catalog is lost. Restores stream
directly into a private staging file at the selected destination, with no full
temporary SSD download, then verify SHA-256 before exclusive installation.

## CLI

```sh
build/cloudnest login /outside/repository/desktop-oauth.json
build/cloudnest scan /approved/folder
build/cloudnest archive /approved/folder /approved/folder/disposable.bin
build/cloudnest jobs
build/cloudnest resume JOB-UUID
build/cloudnest stage-cleanup JOB-UUID --approve-local-move
build/cloudnest put-back JOB-UUID
build/cloudnest remove-recovery JOB-UUID --approve-permanent-removal
build/cloudnest restore /path/to/manifest.json /existing/restore/folder
build/cloudnest revoke
```

Do not choose a Git checkout as an archive source. Project hibernation is a
later milestone. Every repository is conservatively excluded in Phase 0.

Catalog and local recovery manifests live in
`~/Library/Application Support/CloudNest/`. Drive uses separate app-created
`CloudNest Storage/Archives` and `CloudNest Storage/_manifests` folders.
Human-readable manifests use ISO 8601 dates, SHA-256, size and Drive file IDs.
They contain the original path for reference, never as an implicit restore target.

## Verify

```sh
npm ci
npm run check
```

The Mac build has no third-party runtime dependencies. Node dependencies are
development/test tools only; the Worker has no npm runtime dependencies.
The Worker suite runs a real local Workers runtime, D1/FTS5 and the official MCP
SDK client. Storage tests use an explicit fault-injecting remote test double;
they do not prove Google Drive works live. See [Verification](docs/verification.md).

## Brain feasibility

`brain/worker/index.ts` exposes authenticated, project-scoped, read-only
`memory_search`, `memory_read`, `memory_recent` and `project_context` over
stateless Streamable HTTP. It implements the 2025-11-25 compatibility protocol.
An unknown, expired or revoked client cannot retrieve memories. Private,
Inbox and expired items are excluded server-side. Audit writes precede returns.

This proof accepts preconfigured bearer credentials. It does **not** implement
an OAuth authorization server/discovery or claim that consumer AI applications
can connect. Codex CLI 0.165.0 retrieved the disposable memory through the deployed HTTPS
endpoint; both tool calls were confirmed in D1 audit. Its temporary grant was
revoked afterward. Other providers and consumer chat websites are unverified. Canonical Drive-backed
memory writes, Inbox review, revision conflicts, rebuild, export console and
3D visualization are not implemented yet. Do not store personal memories in
the feasibility index. Use disposable records only.

## Next milestones

1. Phase 0 passed: real Drive upload/interruption/restore, Stream mode
   confirmation, deployed authenticated MCP and real Codex retrieval.
2. Complete Storage MVP: folder-level archive/restore, catalog rebuild/search,
   advanced archive health, battery/network/quota policies and larger catalog
   workflows. File-level upload, recovery, approved cleanup, duplicates and
   event-driven stale marking are implemented and tested.
3. Brain MVP: canonical Markdown vault, versioned writes, Inbox, rebuildable
   D1 index, export, browser console and handoff packs.
4. Proven AI connections and real-data Galaxy/Orbit with lazy-loaded Three.js.
5. Developer mode, protected automation, profiling and public release.

The milestone gate is intentional. Later phases will not be presented as
complete before their prerequisites pass. No unrelated files, cloud caches
or Trash contents are touched. The native app is version 0.2.0; the Brain
feasibility server remains version 0.1.0. Storage remains independent of Cloudflare.

See [Architecture](docs/architecture.md), [Security](docs/security.md) and
[Official references](docs/references.md). MIT licensed.
