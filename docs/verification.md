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
