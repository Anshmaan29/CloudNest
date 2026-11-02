# Release readiness

**Security release blocker:** whole-workspace credential exposure was confirmed.
Containment, fresh credential recovery and live signing-key activation are verified.
Removal of previously uploaded ZIP copies remains unverified.
See the [incident record](security-incident.md).

CloudNest has working native Storage and an independently deployed canonical
Brain. The current distribution is Preview 0.5, not a production 1.0 release. Passing
local tests and one owner-managed deployment do not establish every provider,
device, account-lifetime or distribution requirement. Historical measurements
remain in the [verification ledger](verification.md).

## Current implementation and evidence

The latest integrated local check passed **192 Swift, 146 Brain, 22 web,
23 browser-companion, 30 setup and 56 release-safety tests: 469 total**, with both
strict TypeScript checks passing. Actual Touch ID enrollment, fresh provider
exports and installed-extension/browser-provider acceptance remain open. Earlier
completed suite results remain in the verification ledger. No credential values
or private fixture contents are published.

| Area | Implemented | Verification boundary |
| --- | --- | --- |
| File storage | Persistent resumable upload, remote verification, managed recovery and exclusive restore | Live Google interruption/restore proofs and local fault tests passed |
| Folder storage | Complete-group cleanup, durable interruption state, offline put-back, remote group reconstruction | Generated live upload/health/stage/put-back/removal/restore passed, including hidden/empty members and matching hashes |
| Native workflows | Recommendations, policies, Activity, Recovery Center, menu/palette, Finder Services, opt-in notifications/login | Latest asynchronous publication/status/retry UI release build passes; reviewed publication and independently verified queued restore pass. Final window inspection after the destination picker was unavailable to UI automation; Finder/login/sleep/device acceptance remain open |
| Canonical Brain | Separate Drive Markdown vault, signed receipts, D1 index, versioned CRUD/history/Inbox, import/export/reindex | Approved deployment/separate Google grant/all six migrations; 17 live canonical checks and 33 live reindex checks passed; four existing live heads unchanged and no Drive writes during rebuild |
| Native Brain | Explicit owner connection import and Keychain credential storage, authenticated memory access | Actual canonical memory was fetched and shown in the native app |
| MCP | Scoped Bearer clients and public-client PKCE OAuth with refresh/replay/revocation | Installed Codex CLI retrieval passed 13 checks including two reads; official SDK passed 24 live hosted HTTPS OAuth checks. Other consumer-client UIs remain separate gates |
| Archive metadata bridge | Fresh-health reviewed publication, private default, project-scoped retrieval and queued restore intent | Native reviewed private publication passed. Queued restore passed 13 independent checks: selected empty destination, exact restored content/inventory and completed server acknowledgment; completion toast not captured |
| Console / Universe | Authenticated console, context/handoff, Galaxy/Orbit/list, real graph API and bounded PNG export | Galaxy/Orbit browser rendering and PNG downloads passed with synthetic QA data; real-owner-data browser acceptance and graphics profiling remain separate |
| Project capsules | Selected source snapshot, exclusions, Git metadata, hashes and recovery checklist | Generated Git/workspace and ordinary archive/restore tests passed; originals remain untouched |
| Docker images | Bounded image export/import through an explicitly selected running local daemon | Fake CLI tests and actual disposable image export/remove/import passed; original image ID and content matched |
| SQLite snapshots | Explicit read-only online backup, WAL consistency, verification and new-folder restore; native controls wired | External-writer SQLite proofs and regression tests passed; no personal database was used |
| PostgreSQL backups | Explicit local-container logical dump, verification and trusted restore into a generated new database; native controls wired | Actual isolated PostgreSQL dump/restore verified 200 rows, six constraints, four indexes, a large object, view, function and sequence; four invalid writes rejected |
| Distribution | Native app/ZIP/DMG resource allowlists and audited committed-source packaging | Local ad-hoc signing only; Developer ID, notarization, Intel and fresh-device QA remain open |

The live canonical checks covered creation/read, correction, stale-version conflict,
private/project MCP isolation, Inbox approval, context, handoff, export, soft deletion
and restoration. These checks establish an actual cloud-backed workflow; they do
not establish irreversible erasure, continuous availability or all AI clients.
A real canonical reindex separately passed 33 checks, preserving all four live
heads without writing to Drive. No existing tombstones were present, so that
run does not prove preservation of a populated tombstone set.

Google Brain consent is now observed **In production**. Fresh owner consent and
a safe grant renewal completed successfully: the owner identity and vault signing
key were preserved, with only the refresh grant rotated. This resolves the earlier
Testing/publication/fresh-consent gate for the observed setup; it is not a promise
that a grant cannot expire or be revoked. It does not establish public Google
verification, every account's consent experience or product production readiness.

Source distribution follows the [audited packaging procedure](source-release-safety.md).
An index/history audit does not retroactively certify older workspace ZIP files.

## Remaining account and release gates

- Monitor grant validity and maintain a deliberate renewal/recovery procedure.
  The observed Google Brain setup is now In production with fresh consent;
  provider revocation/expiration still applies. Preserve the owner identity and
  independent vault signing key through any future renewal.
- Verify the desired consumer AI clients individually. Live hosted official-SDK
  OAuth and installed-Codex retrieval now pass, but do not establish the account
  requirements or UI support of Claude, ChatGPT, Gemini, DeepSeek or Kimi.
- Verify remote Brain access from a second device while the Mac is physically
  powered off. A remote Worker and a stopped native process are not that test.
- Complete browser acceptance with real authorized owner data, accessibility,
  reduced motion and configured graph budgets. Synthetic Galaxy/Orbit PNG
  rendering/download checks passed and are not live-private-data coverage.
- Build and verify the latest native UI changes: asynchronous publication review,
  independent Drive status and inline failure/retry. The earlier native publication
  and queued restore passed; that evidence does not prove the new release bundle.
- Measure the final integrated native app's idle/peak memory, CPU, startup,
  distribution and transfer use. Report physical footprint and RSS separately.
  Under 100 MB remains an engineering target. The short Preview 0.5 sample
  reported 59.4M physical footprint and 115.23 MiB RSS with three 0.0% CPU samples;
  it predates the latest refresh/sheet changes and is not the final profile.
- Test Finder registration, login opt-in/revocation, notifications, sleep/wake,
  restart and cancellation on release hardware. Do not enable OS features without
  owner opt-in. Test Intel, the minimum supported macOS and a fresh device.
- Complete public signing and notarization only when the owner supplies the
  required identity. No paid subscription is mandatory for local development.
- Repeat optional Docker/PostgreSQL checks on the supported release-device matrix.
  The generated local round trip passed 42 checks; no personal databases or unrelated Docker objects were changed.
- Review retention/purge, credential renewal/key rotation and recovery procedures
  before a public production release. Existing soft deletion retains history;
  no irreversible deletion or automatic account-wide purge is claimed.

Default background behavior remains conservative: no automatic upload or cleanup.
Scheduled recommendations are opt-in within approved folders. Storage remains
usable when Cloudflare is unavailable. The marketing website remains deferred.

## Latest verified recovery and onboarding checkpoint — 2 November 2026

Live incident recovery preserved four original tombstone heads and eleven historical
revisions through signing-key rotation and canonical rebuild. New-key receipts were
verified against actual Drive bytes; retired credentials were rejected. See the
incident record for scope and remaining archive-copy removal.

The eight-step native onboarding now persists progress and requires a verified
archive/restore round trip before completion. Six new focused tests passed within
166 Swift tests. Public OAuth metadata packaging passed 55 release-safety tests;
it accepts only a public client ID and schema version. A reusable public OAuth
client and Google release verification are still operator prerequisites, not
credentials supplied by this repository. Live first-run UI acceptance remains open.

## Preview 0.5 integrated product additions

Smart Sweep, Model Parking and Hibernate Project are wired into native navigation
and the command palette. Model purpose persists in queue records and portable
manifests; archive success awaits actual remote verification. Project cards are
explicitly saved private through the existing Brain authorization, with conflict
checks and idempotent retries. Original repository cleanup is intentionally unavailable
because the reviewed snapshot excludes Git history and credentials.

The Brain console supports owner passkeys, expiring sessions, logout, credential
inventory/revocation and recovery authorization. Selected chat export excerpts have
local previews, editable Inbox proposals, duplicate checks and batch rollback.
The optional MV3 companion is implemented and tested; loading it in real Chrome/Edge
and approving its exact Brain host remain device gates. No marketplace release is claimed.

Automatic update installation remains unimplemented and is a release gate alongside
Developer ID signing/notarization. No unsigned update channel or Gatekeeper bypass
has been introduced. Account erasure and the full supported-device matrix also
remain required before a production 1.0 claim.
