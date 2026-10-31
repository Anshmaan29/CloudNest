# CloudNest OS — Final Build Plan

**Vision:** A free-first, open-source macOS system that (1) safely frees SSD space using a user-owned **Google Drive** account and (2) provides a **shared, user-controlled memory** across AI assistants. Both modules work independently. **iPhone app and Obsidian are optional.**

## 1. The product

| Module | Main features |
|---|---|
| **CloudNest Storage** | Native menu-bar dashboard; SSD/folder scanner; true reclaimable-space estimate; large/old/duplicate file discovery; one-click archive; resumable uploads; SHA-256 verification; safe, approved cleanup; file catalog; original-location restore; Finder quick actions; offline catalog; archive health checks. |
| **Developer Mode** | Project Hibernation; Git state + manifest; exclude `node_modules`, `.venv` and caches; optional Docker image exports and **consistent** volume/database backups; ML dataset/model archive; dependency rebuild guidance. Never live-offload active repos, Docker disks or databases. |
| **CloudNest Brain** | Long-term facts, preferences, project decisions and notes; source/provenance; memory inbox for approvals; full-text search; compact context packs; deduplication; corrections/conflict review; expiry for temporary facts; access controls; import/export as Markdown/JSON. Inspired by Mem0's memory-management approach, without depending on its hosted API. |
| **Universal AI Bridge** | Secure remote MCP tools for supported clients (e.g. Claude/coding assistants); copy/paste context packs and a browser side panel for incompatible consumer chats; optional API-based multi-model Chat Hub later. **Not every AI website permits automatic integration.** |
| **Remote Console** | Responsive web dashboard for memory/search, archive catalog and download links, connection health and restore requests. Available when Mac is off; restore to the Mac executes when it comes online. No native iPhone app required. |
| **Security & Recovery** | Least-privilege Google OAuth; separate per-client permissions; macOS Keychain; encrypted traffic; read-only AI access by default; reviewed writes; protected folders; audit log; manifests and test restores; optional encrypted private vault. |

## 2. Signature feature — Cinematic 3D Memory Universe

A **real interactive WebGL knowledge graph**, not a looping decorative animation, inspired by the two supplied videos:

- **Galaxy Mode:** deep-black background, thousands of softly glowing red/pink/violet particles, clustered constellations, fine connection lines, floating labels and holographic detail cards (the dense first reference).
- **Orbit Mode:** one luminous **CloudNest Brain** sphere at the center, with ChatGPT / Claude / Gemini / DeepSeek / Kimi / other client nodes orbiting it and animated connection arcs (the second reference). Display provider logos only where permitted.
- **Meaningful nodes:** memories, projects, decisions, topics, sources, archived files and connected AI clients. **Meaningful edges:** `belongs_to`, `references`, `supersedes`, `created_from`, `retrieved_by`—backed by real saved relationships/events.
- **Interactions:** orbit/zoom/pan; search-to-focus; cluster and filter by project/provider/time; click to inspect sources, edit approved memories or open an archive; memory timeline; live pulses **only for actual authorized save/read events**.
- **Visual feel:** sci-fi command center with depth-of-field glow, restrained particles, smooth camera travel and a bottom telemetry strip. Adjustable animation quality and **2D/list fallback** for accessibility and battery life.
- **Privacy:** only authorized node metadata is rendered; private memories never appear to restricted clients. The graph is a visualization of the Brain, **not** a claim that all LLM apps are automatically connected.

**Implementation:** Three.js + `3d-force-graph` (or custom force layout), fed by a graph API built from the memory index and approved provenance records. Build functional search and retrieval **before** the cinematic rendering.

## 3. Architecture

```text
Mac (SwiftUI + background helper)
  ├─ SSD analysis → safe archive queue → Google Drive API → cloud archives
  ├─ SQLite local catalog → Finder access via official Drive for desktop
  └─ local search / restore / project snapshots
                      ↕ authenticated metadata sync
Cloudflare Worker (HTTPS API + remote MCP + web console)
  ├─ D1: memory index, graph relationships, archive catalog, audit log
  ├─ Google Drive: canonical Markdown Brain vault + file manifests
  ├─ Search: FTS first, optional embeddings/vector search later
  └─ 3D Graph UI ↔ approved memories / real connector events
                      ↕
AI clients: native MCP when supported | browser/context bridge otherwise
```

**Implementation stack:** Swift 6 / SwiftUI, SQLite, FileManager + FSEvents, CryptoKit, Google Drive API v3 with resumable uploads, Google OAuth + Keychain; Cloudflare Workers (TypeScript), D1, Remote MCP, simple web console; Three.js for the graph. Keep storage and Brain deployments independent so an outage in one doesn't disable the other.

**Drive layout:** `CloudNest Storage/{Videos,Projects,Docker Backups,Datasets,Archives,_manifests}` and `CloudNest Brain/{Inbox,Profile,Projects,Decisions,Knowledge,File References,Private,_system}`. Obsidian may open exported/synced Markdown but is **not required** or a synchronization dependency.

## 4. Non-negotiable storage safety

`Discover → Snapshot/hash → Resumable upload → Verify remote SHA-256 + size → Commit catalog → User-approved local cleanup → Testable restore`

- Re-check that the local source did not change. Handle interrupted uploads, power loss, quota exhaustion, and naming conflicts. Never overwrite a restore destination silently.
- **Moving files to Trash does not free SSD space**; report *uploaded*, *in recovery*, and *actually reclaimed* separately. Permanently remove only CloudNest-managed eligible files after explicit approval; never empty unrelated Trash.
- Avoid cloud placeholders, app bundles, Photos libraries, system folders, symlinks and running Docker/database files. Don't touch Google Drive's internal cache or build a replacement filesystem.
- A cloud archive is **not** a complete backup strategy: preserve independent backups of irreplaceable data and periodically verify restoration.

## 5. Memory rules and AI compatibility

- **Canonical memory** is portable Markdown in Drive; D1 is a rebuildable searchable index. Save a source, timestamp, permissions and revision history with each item.
- AI tools expose `memory_search`, `memory_read`, `memory_propose`, `project_context`, and read-only `files_find`. Proposals go to **Inbox**, not directly into permanent memory. No LLM can directly delete archives or overwrite memories.
- A worker-hosted Brain remains accessible with the Mac switched off. Avoid storing passwords, credentials, private IDs, or unapproved transcripts. Keep confidential material outside the searchable index.
- Support **three bridges**: (A) MCP for eligible assistants, (B) explicit context packs/browser side panel for consumer chats, (C) optional multi-model API Chat Hub (model API costs may apply). Do **not** promise silent sync with every AI or assume ChatGPT Plus/Gemini consumer features have universal connector access.
- Start with keyword search; only introduce embedding search or Mem0-style automated extraction if measured retrieval quality justifies it. Respect account/API quotas and evolving provider policies.

## 6. Delivery milestones (in order)

1. **Proof of feasibility:** Test Drive stream mode; upload/hash/restore a disposable folder; deploy one authenticated MCP `memory_search` endpoint; verify at least one client can call it.
2. **Storage MVP:** Scanner, archive queue, integrity verification, metadata catalog, explicit reclaim, one-click restore, crash recovery, storage dashboard. **First real user value.**
3. **Brain MVP:** Markdown vault, D1 full-text search, user-approved memory inbox, web console, context packs, access controls and audit trail.
4. **3D Memory Universe + AI bridges:** Two graph modes, real-time event visualizations, filtering/search, MCP clients and reliable manual bridge. Keep non-3D fallback.
5. **Developer + intelligence:** Project Hibernation, safe Docker backups, advanced rules/health checks, cross-project linked knowledge, optional semantic search and API Chat Hub.
6. **Public release:** Installer/setup guide, safe defaults, automated tests, clear self-host steps, MIT license (subject to dependency license checks).

## 7. Acceptance criteria

- Recover real SSD space and restore archived files byte-for-byte after interrupted upload/restart; protected paths remain untouched.
- Find an archived project remotely while the Mac is off; restore it once Mac reconnects.
- Save an **approved** memory from one supported client and retrieve it from another; incompatible apps still work through a context pack.
- Search the same memories in the web console **and** navigate their real relationships in the 3D graph; private nodes remain invisible to unauthorized clients.
- No mandatory paid model API, dedicated server, Apple Developer membership, Obsidian, or iPhone app for the personal MVP. Free cloud tiers are **usage-limited**, not guaranteed unlimited.

**Priority:** Reliability and ownership first → useful cross-AI memory second → cinematic visualization third. The 3D experience is a signature feature, but never at the expense of file safety or memory accuracy.

## Current delivery instructions

Continue the existing verified codebase. Complete storage reliability before
personal Brain writes, then supported connections, native UI polish, real graph
data, developer features and release hardening. The current completion directive includes the remote Brain Console and a
user-initiated browser companion. The marketing website remains deferred.
Commit stable, verified checkpoints to the existing repository after privacy
review. Never publish account configuration, credentials, catalogs or personal data.
A public release requires Developer ID signing, notarization and fresh-install
acceptance; a local ad-hoc preview must not be labelled production-ready.
