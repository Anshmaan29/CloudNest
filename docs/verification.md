# Verification ledger — 2026-10-31

Current status: development preview with verified native Storage and a deployed
canonical Brain. The final checkpoint section records current test counts, live
acceptance and remaining release gates. Earlier sections preserve historical
build evidence; their status statements and resource samples are not current
integrated-build claims.

## Automated evidence

- 26 Swift tests passed for the historical 0.2 checkpoint. They cover interrupted chunks,
  authoritative remote-offset recovery after recreating the coordinator/catalog,
  a lost final acknowledgement without duplicate upload, empty files, changed
  sources, missing remote SHA-256, corrupt manifests/downloads, hard-link
  counting, path traversal, protected paths, symlink rejection and restore
  overwrite refusal. Added tests cover two-step cleanup, changed recovery data,
  interrupted cleanup reconciliation, open-file refusal, database directory
  protection, FSEvents, bounded catalog pagination, manifest import limits and
  streamed download size/HTTP/redirect handling. Storage fault tests use an
  explicit remote test double; live Google checks are recorded below.
- 11 Worker tests passed in the local Workers runtime with real D1/FTS5 and
  the official MCP SDK client over HTTP. They cover authenticated retrieval,
  private/Inbox/expiry/project isolation, rejected origins and protocols,
  invalid/expired/revoked credentials, malformed and oversized requests,
  unavailable write tools, literal search input, FTS correction/deletion,
  bounded responses and fail-closed auditing.
- TypeScript strict type checking passed. npm dependency audit reported zero
  known vulnerabilities at installation. Lockfile included.
- Credential generator tested: mode-0700 directory, mode-0600 token file,
  no token in stdout, rejection of paths inside the repository (including
  names starting with two dots).
- Native release build and ad-hoc code-signature verification passed. The
  CLI help ran from the packaged CLI binary. Native app window, Settings,
  OAuth import/sign-in controls and real filesystem capacity were inspected
  through macOS accessibility and a rendered screenshot.
- The supplied plan was preserved unchanged in local private working files.
  The public `plan.md` generalizes account-specific storage capacity.

The full-Xcode default SwiftPM builder in the installed preview toolchain
failed its output-path handling. `scripts/swift.sh` selects the native
builder and supplies Command Line Tools Testing framework/plugin paths.
The CLI product is `cloudnest-cli` internally, avoiding a case-insensitive
filesystem collision with `CloudNest`. No test frameworks are linked into
the shipped application; `otool -L` showed system frameworks only.

## Measured resources

One development machine: Apple Silicon, 16 GiB RAM, macOS 27.2 (26B123),
Swift 6.4, release optimization. Two disposable archive jobs, no 3D or login helper.
These are single-run observations, not a supported-hardware performance claim.

| Measurement | Observation | Method / limitation |
|---|---:|---|
| Idle physical footprint | 66.3 MiB; peak 79.6 MiB | `vmmap -summary`, Storage preview, approved-folder watcher active |
| Idle RSS | 90.1 MiB at the final sampled idle moment; earlier samples varied | `ps`; shared frameworks and paging affect RSS |
| Idle CPU | 0.0% at sampled idle moments | `ps`; no long-duration energy trace yet |
| Current 0.2.0 app bundle allocation | 1,396 KiB | `du -sk`; uses system SwiftUI/AppKit/CryptoKit |
| Current 0.2.0 compressed app | 371,649 bytes | `stat`; arm64 ZIP; toolchain not distributed |
| 256 MiB archive + restore | 1.09 s pipeline, 1.43 s process wall time | Disk-backed test transport, cached local disk, **not Drive/network throughput** |
| Transfer benchmark maximum RSS | 20,103,168 bytes (19.2 MiB) | `/usr/bin/time -l` on release `cloudnest-bench` |
| Transfer benchmark peak footprint | 13,943,336 bytes (13.3 MiB) | Same process; no SwiftUI or real URLSession upload |
| 512 MiB archive + restore | 2.25 s pipeline; 18.1 MiB maximum RSS | Same disk-backed transport; doubled input stayed memory-bounded |
| Live resumed Drive upload maximum RSS | 52,838,400 bytes (50.4 MiB) | 48 MiB file; release CLI, URLSession, `/usr/bin/time -l` |
| Live Drive restore maximum RSS | 29,130,752 bytes (27.8 MiB) | 12 MiB file; 1.71 s wall time |
| First-window startup latency | Pending | Not inferred from process launch time |

Profiling first caught an actual defect: Foundation autoreleased read buffers
accumulated despite small read sizes. The initial 256 MiB benchmark peaked
at 1,260,650,496 bytes RSS. Per-block autorelease pools reduced that same
workflow to 20,103,168 bytes. Chunking alone was not sufficient evidence of
bounded memory. Keep the benchmark when changing file I/O.

Reproduce, using a disposable source outside any Git checkout and a new
benchmark destination outside the checkout:

```sh
bash scripts/swift.sh build -c release
/usr/bin/time -l mac/.build/arm64-apple-macosx/release/cloudnest-bench \
  /path/to/disposable-256MiB.bin /path/to/new-benchmark-directory
```

The benchmark has a separate disk-backed transport. It archives, verifies,
restores, and retains the source; it never connects to Google. The production
native application does not contain this test transport.

## Live acceptance ledger

| Gate | Status |
|---|---|
| Google Desktop OAuth JSON imported | Passed in native app; configuration stored in Keychain |
| Real Google browser authorization | Passed; user reported success, app showed **Drive authorized** |
| Token refresh + revoke | Pending; current connection retained for live tests |
| Disposable Drive file upload and remote SHA-256/size | Passed, 12 MiB and 48 MiB files |
| Recovery manifest uploaded and independently verified | Passed for both files |
| Real interrupted Drive upload/restart | Passed: CLI terminated at 8,388,608 acknowledged bytes; 48 MiB job resumed and verified |
| Byte-identical live restore and overwrite refusal | Passed; both files independently hashed after restore; existing destination refused |
| Drive for desktop Stream mode | Passed: user screenshot shows Stream files selected |
| Cloudflare Worker deployed with HTTPS authentication | Passed on the owner-configured HTTPS endpoint; strict origin and bearer checks |
| External AI retrieves a saved memory through MCP | Passed: Codex CLI 0.165.0, existing ChatGPT login, invocation-only read-only grant; search + read confirmed in D1 audit |
| Mac-off remote retrieval | Worker/D1 independent of Mac established; physical Mac-off test on another device still pending |
| Actual SSD reclaim | Passed on the disposable 12 MiB file: observed filesystem free-space increase **12,578,816 bytes**; file then restored from Drive |

## Remaining product scope

Phase 1 is not complete. The file-focused Storage preview implements size and
modified-age rules, opt-in content duplicates, persisted protected folders,
event-driven stale marking, live per-chunk queue updates, integrity-checked
archive and restore, portable manifest import, and two-step approved cleanup.
Queue memory is bounded to 500 displayed jobs; dashboard totals aggregate the
whole catalog in SQLite and direct ID lookup addresses older jobs.

Cleanup testing moved the disposable original into private recovery, put it
back without overwrite, moved it again, permanently removed that exact managed
payload after fresh checks, measured the free-space delta, and restored it from
Drive. No unrelated file or Trash item was touched. The native UI includes
separate approval alerts; the CLI requires separate explicit approval flags.

Folder-level archive/restore, full catalog rebuild/search, advanced health,
low-battery/network/quota policy handling, and a login helper remain pending.
Presets are dry-run recommendation rules; there are no autonomous operations.
The system folder picker could not receive pointer input through automation.
The user completed it manually and provided a screenshot confirming two real
disposable files and their 62.9 MB allocation estimate in the native scanner.
Live transfers, cleanup and restore were verified through the same core in the
CLI. Remaining native transfer/recovery click-through QA is not claimed complete.

The D1 database is a feasibility index with disposable fixtures. Canonical
Drive Markdown transactions, Inbox/review, conflict recovery, deletion
propagation across Drive/index, browser console, Continue in Another AI,
provider-specific OAuth connections, graph API, 3D, Finder actions and developer
features are later milestones. There are no decorative fake graph nodes or
invented connection-health events.

Public distribution/notarization, Intel hardware, macOS 14 runtime behavior,
sleep/wake on real transfers, long-duration energy profiling, larger catalogs,
full OAuth recovery UI, rate limits and quota/battery/network policies remain
to be validated or implemented. Local tests and an ad-hoc signature do not
prove those release gates.

Live test hashes: 12 MiB `c06c5507898c91bb6985915f7cf803015e6bdaffa75575f2b04235949a97ada5`; 48 MiB `71e9caf5ecd6e4134756127fb21014f1b28328b2599de49fc2547ceb4c82b6bf`.
The 48 MiB source was retained. The disposable 12 MiB source was later used in
the separately approved cleanup test and restored with matching content.
Temporary Codex proof grant was revoked after the test.

## Direct restore streaming update

The 0.2.0 release writes Google download chunks straight to an anchored private
staging file at the selected destination. A full temporary SSD copy is no
longer used. Redirects, excessive lengths, truncated streams and failed hashes
are rejected. Cancellation cancels the network task. The completed file is
installed with exclusive no-overwrite semantics. The earlier benchmark table
is historical evidence for earlier iterations. The current direct-stream
12 MiB live restore passed with a matching hash at **33,292,288 bytes maximum
RSS (31.8 MiB)** and **20,595,432 bytes peak footprint (19.6 MiB)**. Its
21.03 s wall time includes credential/network delays and is not a throughput
claim. The destination held one staging payload, not a second temporary SSD
copy. Keychain calls now run on a utility task, and the disk dashboard updates
before waiting for credentials.

## Public checkpoint privacy

The public source excludes credentials, personal endpoints, database/account IDs,
local catalogs, screenshots and test payloads. Deployment configuration is kept
in an ignored local file; the tracked configuration uses an inert example ID.
The original private specification remains local, while the public plan
generalizes the owner-specific storage capacity. Commit attribution uses the
repository owner’s public GitHub noreply address. Release app debug symbols are
stripped before signing; neither runtime Keychain state nor local catalogs are
inside the app bundle.

## Native 0.3 checkpoint

65 Swift tests passed in the final full local run (3.195 s test runtime).
The unchanged Brain passed all 11 local Workers/D1/MCP SDK tests and strict
TypeScript checks. Additional storage coverage includes nested/empty/hidden
folder members, 510-member archives, interruption/restart, root-manifest lost
acknowledgement, case/Unicode collisions, final target protection, full staged
tree/hash revalidation, unexpected staging data retention, search/pagination,
legacy catalog migration, recovery beyond 500 jobs and restore-only imports.

Five lease tests cover contention and real subprocess death. Six metadata
safety tests cover exact archived provenance, legacy omission, bounds and
unsupported attributes added before or after staging. A transient conservative
cleanup refusal occurred in an intermediate local run; targeted reruns and the
final full run passed. Such uncertainty remains fail-closed rather than being
ignored to make cleanup succeed.

### Real service and native acceptance

- A new generated 12 MiB nested folder, including hidden/empty files and an
  empty nested directory, uploaded to Google Drive. Its CLI process was
  terminated after an acknowledged partial transfer. A new process resumed
  the persistent folder job and verified all file and root manifests.
- CLI folder restore produced matching file hashes and directory inventory;
  retry into the existing target refused overwrite. All originals remain.
- Native Archive Library search found the generated payload. Its Check health
  action verified the live file and recovery manifest. Native Restore folder
  selected a new destination through NSOpenPanel, completed, and independently
  matched the original file hashes and empty/nested directory inventory.
- Real quota retrieval succeeded with the existing narrow scope. Account
  capacity and raw provider identifiers are retained only in private logs.
- Real catalog recovery initially failed with HTTP 400 on a key-only custom
  property query. The query was fixed to list direct children of the verified
  app-owned manifest folder, validating private markers locally before content
  downloads. The corrected live run imported five verified restore-only file
  records with zero rejects. This reconstructs file records, not folder groups.
- A new final-binary file upload verified the provenance-bearing manifest,
  restored matching content, moved into managed recovery and was put back.
  That generated original was retained; no new permanent cleanup was performed.
- The DMG mounted read-only. Its ad-hoc code signature, exact binary identity
  against the built app and Applications shortcut were verified. This is not
  notarization or a fresh-install test on another Mac.

### Current resource sample

Final 0.3 release app, six generated file jobs, one folder summary and five
recovered records; native app idle. Same development Mac as the earlier table.

| Measurement | Observation | Limit |
|---|---:|---|
| Physical footprint | 56.1 MiB; peak 69.0 MiB | Single `vmmap -summary` sample |
| RSS | 130,960 KiB (127.9 MiB) | Mapped/shared framework residency differs from physical footprint; under-100-MB RSS is not established |
| Idle CPU | 0.0% | Sample only, no sustained energy claim |
| App bundle allocation | 2,780 KiB | Includes the new generated app icon |
| Compressed ZIP | 846,564 bytes | Apple Silicon local preview |
| Compressed DMG | 1,251,710 bytes | Preview, not notarized |

Earlier streaming benchmarks remain historical measurements, not new throughput
claims. First-window latency, long-duration energy use, larger live catalogs,
Intel/macOS 14 device acceptance and broad sleep/network fault testing remain
pending. Folder cleanup, complete macOS metadata backup and the full Brain are
not complete. Website and browser console work is explicitly deferred.


## Integrated storage and Brain checkpoint — 2026-10-31

The earlier entries above describe their original builds, not all current code.
New integrated automated checks passed: 120 Swift workflow/security tests, 77
Brain tests in real local Workers/D1, 16 guided-setup tests, 7 graph budget/frame
tests, and strict backend/frontend TypeScript. These counts will grow when the
remaining independent modules are integrated.

A new generated Google Drive folder proof passed upload, complete health check,
managed move, offline put-back, a second approved move, separately approved
permanent cleanup, and restore. Logical content was 12,582,993 bytes in three
files, including a hidden member and an empty directory. Restored SHA-256 values
matched. Observed free-space increase during removal was 12,464,128 bytes;
this is an observed filesystem delta, not exclusive attribution or an APFS
file-size guarantee. The full sequence took 93.903 seconds including fresh
provider round trips. No real personal file was removed.

A release-mode synthetic catalog benchmark inserted 10,000 rows in 1.197 seconds;
two 50-row pages plus a literal-name count took 2.394 ms; aggregate totals took
10.906 ms. Maximum RSS was 18,268,160 bytes and peak footprint 12,419,552 bytes.
This is an isolated catalog benchmark, not the native GUI or Google transport.

The signing setup helper originally emitted the wrong vault-key encoding.
Integration review corrected it before real grant preparation and added a test
against the actual backend validator. Browser QA found and corrected WebKit
animation-frame receiver binding; Galaxy then rendered saved fixture edges.
The Google transport in that local browser environment is explicitly fake;
live canonical Brain acceptance is recorded separately when completed.

Parallel filesystem tests exposed a genuine Spotlight reader. Generated test
containers now use the documented `.noindex` convention. The production
file-use guard was preserved, and the external-reader refusal test still passes.


## Canonical Brain and native safety checkpoint — 2026-10-31

This current entry supersedes earlier feasibility-only status and test counts.
Historical sections above retain the evidence and limitations of their original
builds; their incomplete-feature statements are not current product status.
CloudNest remains a development preview, not a production 1.0 release.

The latest integrated runs passed **160 Swift, 89 Brain, 9 web and 21 guided-setup
tests**, with strict TypeScript checks. Native code includes verified whole-folder
recovery/cleanup, archive metadata and local destination review, plus optional
SQLite and PostgreSQL backup interfaces. SQLite restore regression coverage rejects
a different valid same-size destination database instead of accepting a new hash.
Native snapshot progress is coalesced before UI scheduling with a job-generation
guard. No personal source database was used in these checks.

### Live canonical service and an actual AI client

An explicitly approved Worker deployment uses a dedicated Google authorization,
independent of Mac Storage credentials, and all six D1 migrations. Seventeen live
checks passed: canonical create/read, correction, stale-version conflict rejection,
private/project MCP isolation, Inbox proposal approval, compact context, editable
handoff, export, soft deletion and restoration. The proof exercised the real
Drive-backed service rather than only a fake transport or local index.

The installed Codex CLI then retrieved a newly created canonical memory through
MCP. Its 13 acceptance checks, including two read-tool calls, passed. This is an
actual external-client retrieval, separate from official-SDK local OAuth tests;
it does not prove a hosted OAuth browser/client flow or another provider's UI.
The native app imported the reviewed owner connection, saved its credential in
Keychain and displayed an authenticated fetch of an actual canonical memory.

Evidence is retained privately. Public documentation includes counts and workflow
outcomes only, not memory text, tokens, account identifiers, service endpoints,
private paths or raw result JSON. No paid model API was required for the Brain
architecture or manual context/handoff workflows.

### Current implementation and remaining acceptance

Archive metadata is private by default and explicitly published after fresh health
review. Project-scoped MCP metadata tools and durable remote restore requests are
implemented. Local restoration requires matching verified metadata and a Mac-side
destination review; remote requests do not authorize unattended execution. Live
publication-to-restore acceptance remains separate from implemented-code tests.

The graph API returns real authorized records/relationships/events. Galaxy/Orbit,
list fallback and bounded PNG export are implemented, but current real-data
rendering/export browser acceptance and graphics profiling remain pending.
SQLite external-writer/WAL consistency proofs passed with generated databases.
PostgreSQL safety/failure tests use a fake Docker executable; a real disposable
container round trip and application-level restore validation remain pending.

Google Testing grant lifetime, consent publication/fresh consent, hosted MCP OAuth,
a second-device check with the Mac physically off, Finder/login/sleep acceptance,
Developer ID/notarization, Intel/fresh-device QA and final integrated resource
profiling remain open. Earlier resource samples are historical, not measurements
of this integrated build. See [release readiness](release-readiness.md).


## Live authorization, recovery and Preview 0.4 checkpoint — 2026-11-01

This entry updates the gates in the preceding checkpoints without rewriting their
historical evidence. The product remains **Preview 0.4, not production 1.0**.
The integrated check completed successfully: **160 Swift, 89 Brain, 9 graph and
30 guided-setup tests, totaling 288**, with both strict TypeScript checks passing.

### Google renewal and hosted MCP OAuth

Google Brain consent was observed **In production**, and fresh owner consent
completed. The safe grant renewal exited successfully, preserving the existing
owner identity and vault signing key and rotating only the refresh grant. This
resolves the earlier observed Testing/publication/fresh-consent gate. It does
not imply Google public verification, perpetual authorization or universal
account availability; grants can still be revoked or expire under provider rules.

The official MCP SDK passed **24 of 24 live checks** against the hosted HTTPS
OAuth path. This is live deployed-service OAuth evidence, separate from earlier
local SDK tests. The prior installed-Codex CLI acceptance remains **13 of 13
checks**, including two read-tool calls on a newly saved canonical memory.
Neither proof establishes the consumer UI/account support of every AI provider.

### Canonical rebuild, native publication and graph exports

A real canonical reindex passed **33 of 33 checks**. All four existing live memory
heads remained unchanged; there were no existing tombstones in that dataset.
The rebuild performed no Drive writes. D1 index/recovery operations are distinct
from Drive mutation, and an empty existing tombstone set is not live evidence
for a populated tombstone recovery case.

Actual native archive publication passed recipient review, a fresh successful
Drive health check and private project selection. Remote queued restoration then
passed **13 of 13 independent checks**. The owner selected an empty generated
local destination parent; existing data was not overwritten. All three restored
files, totaling 12,582,993 bytes, matched SHA-256 and size against both the portable
manifest and the original proof. Inventory matched exactly: two directories,
one hidden file, one empty directory and no unexpected members.

The owner pending-requests response no longer contained the request. A read-only
exact-request database check confirmed completed status and an acknowledgment
timestamp. This acceptance uses independently verified filesystem/server truth;
the post-dialog completion toast was not visually captured. Normal local manifest
and destination safeguards remained in force.

The latest native UI source adds asynchronous publication review, independent
Drive status and inline failure/retry. Its release build remains pending; the
passed workflow above is not a claim about that not-yet-built bundle.

Browser QA rendered Galaxy and Orbit and downloaded PNG exports successfully
using synthetic QA data. The private exported images remain in ignored evidence,
not in public source. These are actual rendering/download checks, not a claim
that private owner memories were visualized or that all graphics budgets have
been profiled. Real authorized owner-data browser acceptance remains separate.

### Short native resource sample before the latest UI changes

The running native bundle identified itself as 0.4.0/build 4. Read-only sampling
of that process took 7.28 seconds, without profiler UI interaction. Overview had
just been opened before sampling; navigation during the sample was not separately
controlled. Three CPU/RSS samples were taken three seconds apart.

| Measurement | Observation | Scope / limitation |
| --- | --- | --- |
| Physical footprint | 59.4M as reported by `vmmap` | One summary sample; separate from RSS |
| Lifetime peak physical footprint | 71.3M as reported by `vmmap` | Peak since that process launched |
| RSS | 118,000 KiB / 115.23 MiB in all three samples | Exceeds 100 MiB; mapped/shared residency differs from footprint |
| CPU | 0.0% in all three samples | Cumulative CPU time unchanged at 0.64 s; no sustained energy claim |
| App allocated size | 6,696 KiB | Bundle filesystem allocation, not exclusive SSD attribution |
| Compressed ZIP | 1,853,288 bytes | Apple Silicon local preview package |
| First window | 1.689 s observed by UI automation | Warm cache and automation overhead included; neither cold start nor data-ready latency |

This sample predates the small refresh/sheet changes now being finalized. It is
not a final-current-binary resource profile or evidence that the full under-100-MB
goal is met. Final idle/peak/transfer profiling, startup/data-ready timing and
longer-duration CPU/energy checks remain pending.

### Remaining release gates

The physical-Mac-off second-device test, consumer-client compatibility,
Finder/login/notification/sleep acceptance, Intel/minimum-macOS/fresh-device QA,
Developer ID signing/notarization and real disposable Docker/PostgreSQL round
trips remain pending. The latest native UI release build and final resource
profiling must be recorded separately when actually complete. Memory
retention/purge and ongoing credential/key recovery procedures remain release
work. Evidence stays private: no credentials, service origins, account/record IDs,
personal persistent paths or fixture contents are included here.

## P0 incident containment and recovery checkpoint — 2026-11-01

This is a security checkpoint, not completion of P0 or a production release.
A whole-workspace archive exposed active Brain operational credentials and private
evidence. The local carrier was quarantined with its bytes/checksum preserved.
Seven other inspected CloudNest distributions had no registered credential matches;
the preincident reachable Git history also had no exact matches. Scope and caveats
are recorded in [the incident report](security-incident.md).

The integrated check passed **363 tests: 160 Swift, 112 Brain, 9 graph, 30 setup
and 52 release-security tests**, plus both strict TypeScript checks. An independent
review reproduced five focused security regressions and found the reported
publication-fencing/history-rollback issues closed. Exact checkpoint `cc12248`
passed both backend and macOS GitHub CI jobs.

Live containment checks confirmed all four exposed hosted MCP credentials return
401, the retired owner credential returns 401, the replacement owner authenticates,
canonical maintenance remains frozen, and no memory writes are pending. Static
clients were cleared and preincident managed/OAuth grants revoked. Google grant
revocation was accepted and the retired client credentials rejected. The owner
reset the dedicated Brain client secret; its replacement was validated/deployed.
The separate Mac Storage credentials were not replaced.

Before fresh-key anchoring, all **4 heads and 11 historical revision payloads**
matched independent preincident cleanup receipts. This includes all four tombstones
and seven earlier revisions; creation receipts also matched. No payload/chain drift
was found in that complete snapshot. This does not prove absence of all attacker
activity or recall previously disclosed copies.

The additive rotation migration and rotation-capable Worker were deployed.
Rotation tests cover complete trusted history, exact canonical bytes, replacement
checkpoints/root, lost acknowledgments, private/tombstone rollback, surviving head
watermarks and stale request fencing. **Live signing-key activation has not yet
completed**: fresh same-account Google consent and the owner-approved native
Keychain repair remain pending. Canonical maintenance stays frozen until recovery
can be verified. Removal of remotely uploaded ZIP copies is also not verified.


## P0 completed recovery / P1 real backups — 2 November 2026

This entry supersedes the earlier pending live-rotation and Docker/PostgreSQL gates.
The private finalization proof verifies fresh same-account Google consent, native
Keychain owner replacement/read-back, primary signing-key promotion and staging-key
removal. A generated private memory's actual Drive receipt verifies under the new
key and fails under the retired key. Only this fixture was soft-deleted.

Canonical rebuild preserved the four original tombstone heads and all eleven
historical revisions, with archive/restore-request metadata unchanged and zero
pending writes. Total heads/revisions after the owned fixture are five/thirteen.
The retired owner and four exposed MCP credentials return 401. An independently
validated private recovery backup was refreshed. Old setup manifests were retired;
operational pointers now use recovered bundles outside the workspace. Remote ZIP
copy removal remains unverified, and no absence-of-attacker claim is made.

Actual Docker/PostgreSQL disposable acceptance passed **42 checks, zero failures**:
image export/remove/import restored its exact image ID and content; PostgreSQL
restore preserved 200 rows, six constraints, four indexes, one large object, a view,
function and sequence, with four invalid writes rejected. The source database
remained unchanged. No image downloads or host ports were used. Original inventory
of 30 image entries, 35 containers and 34 volumes was preserved; only owned fixture
objects were removed. Docker Desktop was returned to its initially stopped state.
The private acceptance summary is retained outside source control.

The eight-step native onboarding checkpoint passed six new regression tests and
all 166 Swift tests in its isolated build. Public client-resource packaging passed
55 security tests; downloaded OAuth secrets and endpoint overrides are rejected.
Live first-run device acceptance and public OAuth provisioning remain open.


## Preview 0.5 integrated checkpoint — 3 November 2026

The integrated local check passed **469 tests**: 192 Swift, 146 Brain, 22 web,
23 companion, 30 setup and 56 release-security. Both strict TypeScript checks pass.
The native build compiles onboarding, Smart Sweep, Model Parking and Project
Hibernation together. Model-purpose round trips cover reopened queues, portable
manifests, real open-file refusal, verified restore and separately staged recovery.

Production REST routing tests verify anonymous bootstrap without memory access,
owner/session authorization, exact Origin checks, CSRF rejection, no invalid-Bearer
fallback and rejection of browser cookies at MCP. The deployed passkey console
returns a secure bootstrap cookie; anonymous REST remains 401. Actual device
passkey enrollment has not been performed.

Selective conversation import and native private-card callbacks are integrated;
format/rollback tests use synthetic exports and generated projects. Full Git
history recovery and original repository cleanup are not claimed. Extension tests
include cancellation, ambiguous writes, explicit consent and clearing old project
drafts after re-pairing. Actual Chrome/Edge/provider UI verification remains open.


### Final Preview 0.5 checks and measurements

The latest owner-connection import adds six passing web security tests (web now
28, current tested suite coverage 475). Local import enforces an exact HTTPS Brain
origin and strict bounded schema, makes no network request itself, and clears
private token state on consumption/lock. Production browser authentication and
conversation-import routes were deployed using recovered credentials; live smoke
checks enforce anonymous 401 on protected REST and successful authorized access.
Physical passkey creation/Touch ID is still an owner/device acceptance gate.

The generated 512 MiB live transfer passed 18 checks, including actual process
termination, actual network loss, same-job resume, remote verification, complete
restore/hash, recovery stage/put-back/separate purge and final archive health.
Peak sampled upload/restore RSS: 51.48/31.48 MiB. Managed purge recorded 542,081,024
bytes of observed free-space increase; this systemwide observation is not exclusive
attribution. Generated local large files were removed only after final hash and
identity checks. No Trash or unrelated files/catalog rows changed.

The integrated native arm64 release builds and its resource allowlist passes.
Short native process samples with Hibernate Project visible: RSS 141,840 KiB
(138.52 MiB), CPU 0.0% in three samples across six seconds. `vmmap` reports physical
footprint 66.7M, peak 80.9M. This is not a sustained energy/startup measurement;
independent tasks were active. Executable 8,413,568 bytes; ZIP 8,647,198 bytes.
DMG creation/checksum verification and local signature checks passed. Signing is
ad-hoc; Developer ID, notarization and secure automatic update installation remain
release blockers. No Gatekeeper bypass is provided.


Evidence boundary: the 512 MiB real-service run used the preserved earlier Storage
CLI, whose exact binary hash is retained privately. It proves that tested binary's
workflow and service behavior; it is not a claim that the final Preview 0.5 GUI
binary completed a second 512 MiB run. Preview 0.5's integrated engine has the
reported automated regression, compilation and native navigation checks.


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

## 1.0 completion — scoped browser pairing, 2026-11-03

- The unchanged Preview 0.5 baseline was rerun: all 492 checks passed.
- Browser companion now accepts a strictly validated local scoped-client JSON
  file. The credential remains module-private until explicit Connect; owner
  recovery files, extra fields, late reads and disconnect races are rejected.
  All 26 companion checks passed.
- Managed clients can authorize one exact Chrome/Edge extension origin. D1
  migration 0011 is additive. Origin preflights require an active unexpired grant;
  other extension IDs and revoked grants are rejected. Full Brain baseline (146)
  and strict checks passed, then both new origin regressions passed (34 OAuth
  tests in that focused run).
- Chrome loaded the actual unpacked extension. Installation is verified;
  authenticated actions on AI websites are still pending and are not implied by
  unit or origin tests.

## 1.0 integration checkpoint — 2026-11-03

- Integrated Git recovery, permanent account erasure and audited signed-update
  installation. The integrated automated run passed **553 checks**: 226 native,
  171 Brain, 35 web, 26 companion, 30 setup and 65 release-safety/publisher checks;
  strict TypeScript checks also passed. This precedes the Gemini importer merge.
- Production routing rejects ordinary REST, passkey, OAuth and MCP access during
  erasure review and after permanent disable; recovery Bearer status remains
  available. New routing regression covers both states. No live owner account
  was erased. Provider-side conditional-delete concurrency remains unproven.
- Real Ollama 0.40.13 imported and ran a disposable public GGUF, then stopped.
  CloudNest uploaded and verified its portable store on Drive, restored all six
  files with identical SHA-256 values, and Ollama generated tokens from the
  restored store. The running vendor process correctly blocked parking.
  A vendor-created local symlink was first rejected, then materialized only in
  this generated fixture. New manifests-v2 support fixes the observed layout.
  No personal models were accessed. Test runtimes were stopped afterward.
- LM Studio real-runtime acceptance is BLOCKED: its documented tooling did not
  establish an independently isolated user-data location. No personal pointer,
  settings, model catalog or daemon was modified to work around this.
- Upload folder privacy now uses fresh Drive metadata, rejects shared/unowned/
  trashed/shared-drive/unknown folders, and is checked before hibernation resume.
  Sharing can still be changed by the Drive owner after this point-in-time check.
- The native bundle now includes the separately signed update helper on the
  resource allowlist; oversized staple tickets and missing helpers are rejected.
  Native install controls acquire the shared operation lease. Startup sends a
  one-time health acknowledgment after successful local status/recovery checks,
  independently of the network sign-in result.
- Release metadata is 1.0.0-rc.1, with numeric Apple bundle version 1.0.0/build
  10001. This identifies candidate engineering work, not public readiness.
  Developer ID, notarization and actual signed-update acceptance are BLOCKED:
  the owner confirms no Apple Developer membership/certificate is available.

## Final 1.0 candidate verification — 2026-11-03

- Final integrated source at `8a4387c` passed **563 checks**: 226 native (225 plus
  one isolated deadline test), 180 Brain, 36 web, 26 companion, 30 setup and 65
  release-safety/publisher tests. Both strict TypeScript checks passed. The
  separately signed native helper and release bundle built successfully, then
  the candidate app launched and loaded its existing catalog on this Mac.
- Independent read-only reviews of Git recovery, erasure/Origin routing and the
  signed updater found no confirmed high/critical issue in their scope. Separate
  generated reviewer runs passed 22 erasure/audit checks, three Origin checks
  and 20 updater checks. This is a scoped engineering review, not a claim of
  comprehensive third-party penetration testing.
- A fresh installed Codex CLI 0.165.0 used existing ChatGPT authentication, made
  an actual remote memory_read and returned the generated marker. No API key
  was used. The short-lived, read-only single-project grant was revoked and the
  credential was absent from its captured output. This proves that interface,
  not ChatGPT consumer MCP, Claude, Cursor or universal provider compatibility.
- Actual Gemini CLI 0.66.0 failed before MCP at Google's free OAuth setup with
  UNSUPPORTED_CLIENT. Both temporary grants were verified revoked; isolated
  credential copies removed. No paid/API-key fallback or global-setting changes.
- Owner reports actual Chrome scoped-file pairing, exact host permission approval
  and successful generated-memory search. Owner subsequently reports generated context inserted into a temporary ChatGPT
  draft and cleared, with no message sent. This was manual acceptance because
  browser security blocks automated extension-page control. No private chats
  were read or submitted.
- Owner reports iPhone 14 Pro Max Safari passkey sign-in success. This is genuine
  separate-device authentication, but does not yet prove the Mac was physically
  off during retrieval.
- Real disposable current-Core Docker/PostgreSQL 16 acceptance passed 42 checks:
  image save/verify/remove/import/content, 200 restored rows, six constraints,
  four indexes, a large object and four invalid-write rejections. Generated
  source database and exact existing Docker inventory stayed unchanged. No
  image pulls, published ports or host mounts; Desktop returned stopped.
  PostgreSQL 18 fixture startup failed before backup and is not claimed tested.
- Final app idle sample on the Overview view: four process samples over nine
  seconds, CPU 0% each; settled RSS 126,064 KiB (123.11 MiB). vmmap physical
  footprint 61.2M, peak 74.2M. These are short measurements; battery, sustained
  energy, startup latency and final graph GPU acceptance remain unmeasured.
- Temporary official vendor tools used for disposable model tests were removed
  afterward (approximately 3.8 GB of owned test tooling). No personal model or
  LM Studio setting was deleted or altered.

- Final private-value source comparison passed for 216 tracked files and the
  new commit history; full public-pattern history audit passed across 129
  reachable commits (512 distinct Git entries). No matched values were printed.
  Candidate Settings UI shows 1.0.0-rc.1 and explains why signed updates remain
  unavailable. Distribution byte sizes and the final CI result follow in the
  external candidate report after immutable packaging.

- Final candidate mounted read-only and matched the built application byte for
  byte across all five allowlisted members. Applications link, executable helper
  and Gatekeeper notice were verified; volume ejected afterward. Active private
  credentials, downloaded client identifiers/secrets and the local home path were
  absent from every mounted app member. Native ZIP: **13,195,421 bytes**;
  compressed DMG: **4,245,391 bytes**. The DMG checksum passed hdiutil verification.
- The live server independently recorded the companion access. Its authorized
  generated project graph contained one actual memory node and four actual
  access events, including the companion client. Its temporary QA grant was
  then revoked and its local pairing file removed. The iPhone owner passkey
  session and the generated phone-test memory remain available for the final
  physical Mac-off read. No personal memory was deleted.
