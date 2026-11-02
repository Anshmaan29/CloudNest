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

The latest full integrated local check passed **207 Swift, 146 Brain, 28 web,
23 browser-companion, 30 setup and 58 release-safety tests: 492 total**, with both
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

## Live large-file and resource evidence — 3 November 2026

A generated **512 MiB** file passed **18 live checks**: process death after an
acknowledged 8 MiB chunk, a real network interruption at 72 MiB, same-job recovery,
remote content/manifest health, full SHA-256 restore, managed recovery, put-back,
separate permanent cleanup and post-cleanup cloud health. Sampled peak CLI RSS was
51.48 MiB uploading and 31.48 MiB restoring. Unrelated catalog rows and Trash were
untouched. All large local test artifacts were removed after independent hashes.

The app recorded 542,081,024 bytes of observed free-space increase during managed
purge; external filesystem sampling differed slightly. These are systemwide
observations while other work was active, not exclusive attribution or guaranteed
savings for arbitrary APFS files.

The integrated Preview 0.5 native app, open on Hibernate Project with no native
transfer, sampled **138.52 MiB RSS** and **0.0% CPU** three times over six seconds.
`vmmap` reported physical footprint **66.7M**, peak **80.9M**. This is a short process
sample, not sustained energy, startup or system-idle certification. Concurrent
independent work was present. The arm64 native executable is 8,413,568 bytes and
ZIP 8,647,198 bytes. The DMG checksum and native resource/signature checks pass;
its signature is local ad-hoc, not Developer ID/notarization.

Native navigation, Smart Sweep, Model Parking and Hibernate Project controls were
inspected through the running app. Drive authorization appeared successfully.
This does not replace fresh-install, actual model-service, accessibility, sleep/wake,
minimum-macOS, Intel or independent-device acceptance.


Evidence boundary: the 512 MiB real-service run used the preserved earlier Storage
CLI, whose exact binary hash is retained privately. It proves that tested binary's
workflow and service behavior; it is not a claim that the final Preview 0.5 GUI
binary completed a second 512 MiB run. Preview 0.5's integrated engine has the
reported automated regression, compilation and native navigation checks.

Additional functional gates before 1.0: complete signed automatic updates and
account erasure; validate full original-project hibernation/recovery coverage
before enabling repository cleanup; complete outdated-fact alerts beyond existing
source/duplicate/conflict review; verify actual Ollama/LM Studio model workflows,
fresh chat exports, browser companion and final-binary large-transfer acceptance.
These are pending work, not items resolved by signing alone.


## Final reviewed Preview 0.5 checkpoint — 3 November 2026

Full `npm run check` passes **492 tests**: 207 Swift, 146 Brain, 28 web,
23 companion, 30 setup and 58 release-safety, plus both strict TypeScript checks.
Independent review identified and regression-tested model child-policy propagation,
late-reader refusal immediately before restore publication, per-operation UUID
ownership across navigation, and durable card-save retry identities. Card saves
verify a current live private head before announcing success. Catalog migration 4
stores only operation IDs and payload hashes with FULL SQLite synchronization;
legacy ordinary manifests remain readable, while model manifests use versions 3/4
so older readers refuse their unsupported safety policy.

The owner completed physical passkey enrollment. Browser sign-in survived reload
and a new tab without reimporting the owner credential. Local generated chat JSON
preview, explicit selection/edit, duplicate check and one Inbox-only submission
were observed in the authenticated browser. Provenance stayed visibly untrusted.
Rollback browser automation stalled at its confirmation; owner API rollback
rejected only the generated pending batch, with zero remaining pending proposals
for that batch and zero incomplete canonical writes. The temporary tab was closed
and a signed-in console reopened. Fresh personal-account exports remain unverified.

Twelve live graph/API checks used generated canonical memories: an actual persisted
relationship and a real scoped MCP read produced the matching graph edge, client
and event. Private node identity/content stayed excluded. Only owned QA memories
were soft-deleted and the temporary scoped client revoked; baseline tombstones
were unchanged. This is backend live-data coverage, not final cinematic rendering
or graphics profiling against personal memories.

Signed-update check/download/validation code and native Settings are integrated;
nine native tests and packaging regressions cover publisher signatures, bounded
redirects, compatibility, streaming integrity and unsigned-app rejection. No
publisher trust configuration is shipped, no installation is automatic, and no
real signed/notarized release delivery is claimed. Developer ID identities remain
unavailable on this Mac.

The final rebuilt app launched successfully with Drive authorization. With Settings
visible and native operations inactive, three six-second-window samples reported
RSS 129,424/123,424/123,424 KiB (settled 120.53 MiB), CPU 0.0% each. `vmmap` reported
physical footprint 58.8M and peak 85.2M. This is a short process sample, not sustained
energy/startup certification. Final native executable: 8,681,984 bytes; ZIP:
8,915,614 bytes; checksum-verified DMG: 2,838,877 bytes. Signing remains local ad-hoc.
