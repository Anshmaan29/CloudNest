# Verification ledger — 2026-10-31

Status: native 0.3 storage increment verified; the full Storage milestone and product remain in progress.
The Phase 0 and 0.2 evidence below is historical. Current 0.3 evidence is recorded
in the final section; it supersedes test counts and packaging sizes.
Remaining profiling and release limitations are explicitly listed below.

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
