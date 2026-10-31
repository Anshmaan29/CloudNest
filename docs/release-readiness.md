# Release readiness

CloudNest is being assembled toward 1.0. A working implementation and passing
local suite are not the same as a production release. The following are current
verification boundaries; historical 0.3 results remain in verification.md.

| Area | Implemented | Verification boundary |
| --- | --- | --- |
| File storage | Resumable upload, verification, recovery, exclusive restore | Prior live Google interruption/restore proofs retained; fault tests run locally |
| Folder storage | Complete-group cleanup, durable interruption state, recovery headers, remote group reconstruction | New live 12 MiB upload/health/stage/put-back/removal/restore passed; hidden/empty members and hashes matched |
| Native workflows | Recommendations, policies, Activity, Recovery Center, setup, palette, Finder Services, opt-in notifications/login | Builds and workflow tests pass; OS registration and restart/sleep QA require device checks |
| Brain | Drive revisions/receipts, D1 index, CRUD/history/Inbox, import/export/reindex | Real local Workers/D1 and fault-injecting Google transport; dedicated live grant prepared, deployment acceptance pending |
| MCP | Scoped Bearer and public-client PKCE OAuth, refresh/replay/revocation | Prior actual Codex Bearer proof; current official SDK OAuth/refresh proof local; hosted provider UI checks remain separate |
| Console / Universe | Authenticated management, context/handoff, Galaxy/Orbit, list fallback | Local browser uses synthetic canonical API fixtures; Galaxy rendered; broader graphics profiling pending |
| Project capsules | Source/cache exclusions, Git metadata, hashes, recovery instructions | Real selected fixture Git repositories and ordinary folder archive/restore tests |
| Docker images | Bounded verified export/import, explicit local daemon only | Fake CLI failure/argument/cancellation tests; no selected real disposable image tested |
| Distribution | Reproducible app/ZIP/DMG with source privacy guard | Ad-hoc signing; Developer ID, notarization, Intel and fresh-device verification remain open |

## Remaining account and release gates

- Complete live canonical Google/Worker workflows, including correction/deletion,
  denied scoped reads and recovery; preserve the signing key and separate grants.
- Confirm the intended Google consent publication settings. Testing refresh grants
  are time-limited; successful sign-in does not establish permanent availability.
- Verify one actual AI client against canonical saved memories. Do not equate an
  SDK test or a generic MCP claim with each provider's consumer app support.
- Validate remote access on a second device with the Mac physically powered off.
  Testing with the native application stopped is useful but is a different test.
- Measure final native idle/peak memory, CPU, startup, distribution and transfer
  use, plus configured graph budgets. The under-100-MB goal is a target, not an
  RSS claim; physical footprint and RSS must be reported separately.
- Test Finder registration, login opt-in/revocation, sleep/wake and cancellation
  on release hardware. Never enable notifications/login items without opt-in.
- Complete public signing/notarization when the owner supplies the required
  identity. No paid subscription has been purchased or made mandatory for local use.
- Verify optional Docker/database backup workflows on explicitly selected
  disposable targets. Unsupported live disk/volume copies have no fake controls.

Default background behavior remains conservative: no automatic upload or
cleanup. Scheduled recommendation scans are opt-in and stay within approved
folders. Storage remains independent of Cloudflare availability.
