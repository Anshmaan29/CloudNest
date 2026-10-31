# Release readiness

CloudNest has working native Storage and an independently deployed canonical
Brain. It remains a development preview, not a production 1.0 release. Passing
local tests and one owner-managed deployment do not establish every provider,
device, account-lifetime or distribution requirement. Historical measurements
remain in the [verification ledger](verification.md).

## Current implementation and evidence

The latest integrated runs passed **160 Swift, 89 Brain, 9 web and 21 guided-setup
tests**, plus strict TypeScript checks. Test counts describe those runs, not a
promise about later commits. Live evidence uses generated records and private
logs; no credentials, endpoints or fixture contents are published.

| Area | Implemented | Verification boundary |
| --- | --- | --- |
| File storage | Persistent resumable upload, remote verification, managed recovery and exclusive restore | Live Google interruption/restore proofs and local fault tests passed |
| Folder storage | Complete-group cleanup, durable interruption state, offline put-back, remote group reconstruction | Generated live upload/health/stage/put-back/removal/restore passed, including hidden/empty members and matching hashes |
| Native workflows | Recommendations, policies, Activity, Recovery Center, menu/palette, Finder Services, opt-in notifications/login | Native builds and workflow tests pass; final Finder registration, login, sleep/wake and device acceptance remain open |
| Canonical Brain | Separate Drive Markdown vault, signed receipts, D1 index, versioned CRUD/history/Inbox, import/export/reindex | Approved Worker deployment with a separate Google grant and all six migrations; 17 live canonical checks passed |
| Native Brain | Explicit owner connection import and Keychain credential storage, authenticated memory access | Actual canonical memory was fetched and shown in the native app |
| MCP | Scoped Bearer clients and public-client PKCE OAuth with refresh/replay/revocation | Installed Codex CLI retrieved a newly saved canonical memory: 13 checks, including two read-tool calls; hosted OAuth browser/client flow remains unverified beyond local official-SDK tests |
| Archive metadata bridge | Fresh-health reviewed publication, private default, project-scoped retrieval and queued restore intent | Implemented/tested code with Mac-side matching and destination review; live publication-to-restoration acceptance remains a separate check |
| Console / Universe | Authenticated console, context/handoff, Galaxy/Orbit/list, real graph API and bounded PNG export | Canonical API acceptance passed; current real-data graph rendering and PNG export still need browser acceptance and graphics profiling |
| Project capsules | Selected source snapshot, exclusions, Git metadata, hashes and recovery checklist | Generated Git/workspace and ordinary archive/restore tests passed; originals remain untouched |
| Docker images | Bounded image export/import through an explicitly selected running local daemon | Fake CLI failure/argument/cancellation tests passed; selected real disposable image round trip pending |
| SQLite snapshots | Explicit read-only online backup, WAL consistency, verification and new-folder restore; native controls wired | External-writer SQLite proofs and regression tests passed; no personal database was used |
| PostgreSQL backups | Explicit local-container logical dump, verification and trusted restore into a generated new database; native controls wired | Fake CLI safety/failure tests passed; real disposable-container round trip and application-level validation pending |
| Distribution | Native app/ZIP/DMG builds and staged-source privacy guard | Local ad-hoc signing only; Developer ID, notarization, Intel and fresh-device QA remain open |

The live canonical checks covered creation/read, correction, stale-version conflict,
private/project MCP isolation, Inbox approval, context, handoff, export, soft deletion
and restoration. These checks establish an actual cloud-backed workflow; they do
not establish irreversible erasure, continuous availability or all AI clients.

## Remaining account and release gates

- Review Google consent publication and complete fresh consent when appropriate.
  Testing refresh grants can expire after seven days. Current successful access
  does not establish long-term unattended grant availability. Preserve the
  independent vault signing key when renewing authorization.
- Complete an actual hosted MCP OAuth consent/refresh connection. Local SDK
  coverage and a real scoped-Bearer Codex proof are distinct evidence. Consumer
  Claude, ChatGPT, Gemini, DeepSeek and Kimi support must be checked individually.
- Verify remote Brain access from a second device while the Mac is physically
  powered off. A remote Worker and a stopped native process are not that test.
- Complete current browser acceptance for real Galaxy/Orbit data and PNG export,
  accessibility/reduced motion and configured node/graphics budgets.
- Verify reviewed archive metadata publication and a real queued request through
  the Mac's destination approval and successful restore/acknowledgment.
- Measure the final integrated native app's idle/peak memory, CPU, startup,
  distribution and transfer use. Report physical footprint and RSS separately.
  Under 100 MB remains an engineering target; older samples are not final profiles.
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
