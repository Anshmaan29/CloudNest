# Release readiness

CloudNest has working native Storage and an independently deployed canonical
Brain. The current distribution is Preview 0.4, not a production 1.0 release. Passing
local tests and one owner-managed deployment do not establish every provider,
device, account-lifetime or distribution requirement. Historical measurements
remain in the [verification ledger](verification.md).

## Current implementation and evidence

The integrated check passed **160 Swift, 89 Brain, 9 graph and 30 guided-setup
tests: 288 total**, with both strict TypeScript checks passing. Earlier completed
suite results remain in the verification ledger. Live evidence uses
generated records and private logs; no credentials, endpoints or fixture contents
are published.

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
| Docker images | Bounded image export/import through an explicitly selected running local daemon | Fake CLI failure/argument/cancellation tests passed; selected real disposable image round trip pending |
| SQLite snapshots | Explicit read-only online backup, WAL consistency, verification and new-folder restore; native controls wired | External-writer SQLite proofs and regression tests passed; no personal database was used |
| PostgreSQL backups | Explicit local-container logical dump, verification and trusted restore into a generated new database; native controls wired | Fake CLI safety/failure tests passed; real disposable-container round trip and application-level validation pending |
| Distribution | Native app/ZIP/DMG builds and staged-source privacy guard | Local ad-hoc signing only; Developer ID, notarization, Intel and fresh-device QA remain open |

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
  Under 100 MB remains an engineering target. The short Preview 0.4 sample
  reported 59.4M physical footprint and 115.23 MiB RSS with three 0.0% CPU samples;
  it predates the latest refresh/sheet changes and is not the final profile.
- Test Finder registration, login opt-in/revocation, notifications, sleep/wake,
  restart and cancellation on release hardware. Do not enable OS features without
  owner opt-in. Test Intel, the minimum supported macOS and a fresh device.
- Complete public signing and notarization only when the owner supplies the
  required identity. No paid subscription is mandatory for local development.
- Verify optional Docker/PostgreSQL workflows on explicitly approved disposable
  targets. Never substitute raw live volume/VM/database-directory copying.
- Review retention/purge, credential renewal/key rotation and recovery procedures
  before a public production release. Existing soft deletion retains history;
  no irreversible deletion or automatic account-wide purge is claimed.

Default background behavior remains conservative: no automatic upload or cleanup.
Scheduled recommendations are opt-in within approved folders. Storage remains
usable when Cloudflare is unavailable. The marketing website remains deferred.
