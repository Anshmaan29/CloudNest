# CloudNest 0.3 — native Storage preview

Continues the verified 0.2 codebase. Adds persistent nested-folder archive and
atomic restore, hidden/empty directory preservation, Archive Library search and
pages, cloud health checks, actual quota reads/preflight and restore-only remote
file catalog recovery. Scan/transfer cancellation, process-level job locks and
shared CLI/native folder protection improve safety. Unknown extended metadata
blocks cleanup; new manifests retain exact bounded OS provenance evidence.

Includes a generated native icon and optional drag-to-Applications DMG, plus a
public-source privacy check in CI. No website, browser console or graph shell
was added. Existing Google and Cloudflare integrations remain separate.

This release is a local ad-hoc preview, not production-ready or notarized.
Folder originals are retained. A portable root manifest is required for folder
reconstruction. See release-readiness.md and verification.md for remaining gates
and the distinction between local tests, live cloud checks and measurements.
