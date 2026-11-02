# CloudNest 1.0.0-rc.1 readiness matrix

Last reviewed: 2026-11-03. Continues Preview 0.5 (`82387a8`).

**Public 1.0 release: BLOCKED.** A runnable engineering candidate is built, but
Developer ID/notarization, public Google onboarding and several physical-device
acceptance gates remain. Do not describe the ad-hoc DMG as publicly distributable.
No Gatekeeper bypass is part of installation or testing.

PASS means the evidence named in that row passed, within its stated boundary.
FAIL means an implementation gap remains. BLOCKED means the required real
account, certificate, hardware or external acceptance evidence is unavailable.
Passing a fixture does not turn a blocked real-service gate into PASS.

## Functional completeness

| Requirement | Status | Actual evidence / remaining boundary |
| --- | --- | --- |
| Native app builds and starts | PASS | Candidate release bundle compiled and launched on the development Apple Silicon Mac |
| Independent Storage / Brain | PASS | Storage uses direct Google API and local SQLite; remote Brain deployed separately; no local LLM/Brain dependency |
| File upload, resume and remote integrity | PASS | Local fault suite plus prior real 512 MiB process/network interruption and Drive SHA-256 acceptance |
| Folder archive, health and restore | PASS | Existing live generated-folder proofs; final native regressions preserve hidden/empty members, exclusive restores and group verification |
| Catalog reconstruction | PASS | Portable file/folder manifest recovery and canonical index rebuild verified; recovered entries never gain deletion authority |
| Safe cleanup, put-back and measured reclaim | PASS | Separate explicit approvals; live generated stage/put-back/purge evidence; observed filesystem delta is distinct from logical/allocated estimates |
| Sleep/wake, OS restart, real quota exhaustion | BLOCKED | Fault/restart-state simulations pass; final physical sleep/wake/restart and actual exhausted Drive-account acceptance not performed |
| Finder actions and scheduled recommendations | BLOCKED | Functional Services/review controls and scheduling tests exist; Finder registration/login/real scheduling on installed candidate not accepted on a clean Mac |
| Hibernation Git-state restore | PASS | Generated source→archive→restore tests preserve refs, HEAD, stash history, staged index-only blobs and working state without hooks, checkout or overwrite |
| Hibernation instructions and Brain card | PASS | Dependency instructions and verified archive references; actual canonical private card writer and retry semantics; Git history excluded from card |
| Hibernation original-project cleanup | FAIL | Deliberately disabled when excluded private files/config prevent full original coverage; snapshot recovery is not permission to delete an entire project |
| Real Ollama Model Parking | PASS | Real GGUF inference before parking, verified Drive archive/restore, identical six-file hashes, inference afterward; active runtime refused |
| Real LM Studio Model Parking | BLOCKED | Vendor tooling did not establish safe independent data isolation; personal settings/models were not modified |
| Smart Sweep safety and recovery | PASS | Generated dependency/cache checks, dry run, explicit staging/purge, regeneration instructions and exclusive put-back tests |
| ChatGPT/Claude/Gemini imports | PASS | User-authorized generated format fixtures; duplicates, privacy filtering, provenance, Inbox-only proposals and rollback tested. Gemini supports bounded My Activity JSON prompts, not full HTML/thread reconstruction |
| Canonical memory CRUD, Inbox, history, exports | PASS | Existing live canonical/reindex evidence plus current Worker/D1 regressions; no private conversations committed |
| Memory deletion and recovery | PASS | Versioned tombstones remove normal retrieval and retain explicit owner recovery; selective irreversible per-memory purge is not implemented |
| Whole-account permanent erasure | PASS | Generated Drive/D1 recovery, auth revocation, late-write trigger fences, bounded resume and content-free receipt tests; no live owner account purge |
| Erasure against concurrent external Drive edits | BLOCKED | Metadata is rechecked but provider conditional DELETE fencing is unproven; no cross-editor snapshot guarantee |
| Audit retention | PASS | Explicit cutoff/count/digest review, bounded 200-row batches; canonical memory history is separate; no automatic prune |
| Credential/key recovery | PASS | Owner recovery bundle, Google renewal preflight, key rotation and trusted checkpoint preservation; existing live recovery evidence |
| Every native/console control and state | BLOCKED | Native/console builds, focused UI tests and prior workflows pass; exhaustive final manual control/accessibility/offline/error acceptance remains open |

## Remote access and integrations

| Requirement | Status | Actual evidence / remaining boundary |
| --- | --- | --- |
| Console sessions, expiry, logout and revocation | PASS | Real owner Touch ID enrollment and persisted sign-in; session/CSRF/revocation regression suite |
| iPhone Safari sign-in | PASS | Owner reports successful passkey sign-in on iPhone 14 Pro Max |
| Brain access while Mac physically off | BLOCKED | Separate-phone sign-in is verified, but physical shutdown/read acceptance still needs the final owner step |
| Fresh actual external AI MCP read | PASS | Installed Codex CLI 0.165.0, existing ChatGPT authentication, actual memory_read and exact generated marker; temporary grant revoked afterward |
| Claude consumer / Desktop | BLOCKED | No final actual consumer-interface read. Installed Claude CLI uses API-key auth; no billable generation was invoked |
| ChatGPT consumer MCP | BLOCKED | Protocol/OAuth checks are not actual consumer connection evidence; account interface/eligibility still needs acceptance |
| Gemini CLI | BLOCKED | Actual official 0.66.0 CLI returned UNSUPPORTED_CLIENT at free OAuth setup before MCP; no paid API fallback |
| Cursor | BLOCKED | Actual installed-client acceptance unavailable; documentation/config support is not compatibility proof |
| Manual context packs and handoffs | PASS | Structured editable packs, approved-memory selection and provider-independent copy flow; no paid API needed |
| Installed Chrome companion pairing/search | PASS | Actual unpacked Chrome extension installed; owner reports project-scoped file import, host approval and generated memory search success |
| Installed companion draft insertion/capture | BLOCKED | Browser policy prevents automated extension-page control; owner draft-insertion acceptance pending; selected-text live capture not yet accepted |
| Edge / other AI website editors | BLOCKED | Targeted adapter tests pass; actual installed browser/provider matrix remains open |
| Scope/private/Inbox isolation | PASS | Exact project, visibility, expiration, revoked credentials, exact extension-origin and unauthorized graph regressions; no owner credential in companion |
| Managed multi-user hosting | BLOCKED | Intentionally out of release scope; this deployment remains single-user, not a public tenant service |

## Universe, UX and performance

| Requirement | Status | Actual evidence / remaining boundary |
| --- | --- | --- |
| Real authorized graph relationships/activity | PASS | Backend-issued relationships and authorized access events; earlier live generated graph checks and current authorization tests |
| Galaxy/Orbit renderer and accessible fallback | PASS | Lazy-loaded renderer, list mode, quality limits, reduced motion and hide/dispose lifecycle tests; existing rendered checks |
| Final real-memory visual/GPU acceptance | BLOCKED | Cinematic quality and CPU/GPU behavior on final candidate across devices still require measured browser/device acceptance |
| First-run wizard and protected folders | PASS | Eight-step resumable native guide, safety preferences, approved-folder selection and reviewed first archive/restore controls |
| Public Google one-click onboarding | BLOCKED | Publisher-owned public Desktop OAuth client/branding policy acceptance not available; BYOC remains advanced setup. No personal client ID embedded |
| Self-hosted Brain setup | PASS | Existing free-tier deployment, prepared-bundle automation, explicit local owner connection import and recovery procedures |
| Final native idle process sample | PASS | Four samples over nine seconds: 0% CPU; settled RSS 126,064 KiB (123.11 MiB); vmmap physical footprint 61.2M, peak 74.2M. Short process sample, not whole-system energy |
| Bounded sustained transfer memory | PASS | Existing real 512 MiB test: upload peak RSS 51.48 MiB, restore 31.48 MiB; streamed bounded-chunk implementation retained. These are earlier CLI measurements, not final GUI peak claims |
| Startup latency, battery and sustained energy | BLOCKED | Final reproducible cold-start, battery and sustained energy measurements not completed; UI automation wall time is not startup timing |
| Distribution-size target | PASS | Audited native ZIP/DMG substantially below 200 MB; final byte sizes recorded in verification ledger |
| Fresh install / OS upgrade / macOS device matrix | BLOCKED | Development Mac launch is not clean-install, upgrade, Intel or supported-minimum-macOS acceptance |

## Security and distribution

| Requirement | Status | Actual evidence / remaining boundary |
| --- | --- | --- |
| Credential incident containment/recovery | PASS | Exposed local carrier quarantined; owner/grant/key rotations and old-credential rejection privately verified; history retained |
| Removal of any distributed unsafe ZIP copies | BLOCKED | Owner clarified carrier was the working project ZIP; independent removal from any previously uploaded copy is unverified |
| Independent security review | PASS | Separate agents reviewed Git recovery, erasure/origin routing and updater; no confirmed high/critical finding within that scope. Targeted generated checks passed; this is not a full third-party penetration audit |
| Final automated suite | PASS | 563 checks: 226 native, 180 Brain, 36 web, 26 companion, 30 setup, 65 release safety/publisher; both strict TypeScript checks |
| Real Docker/PostgreSQL | PASS | Current Core: 42 generated checks, Docker image round trip and PostgreSQL 16 restore, source/inventory preservation, no pulls/ports; Desktop stopped afterward. PostgreSQL 18 fixture startup not validated |
| Secret/private-data artifact audit | PASS | Resource and source allowlists, blocked private files, history/pattern audits; final known-value scan recorded separately in ledger |
| Export/account deletion documentation | PASS | Portable Markdown/JSON/manifests, recovery and retention/erasure procedures; independent copies and provider backups are outside application purge |
| Signed update implementation and rollback | PASS | Strict bound ZIP, pinned identity/notary/version/build checks, native helper, atomic exchange, health ACK and crash/recovery fixtures; 11 install fixtures and independent updater review |
| Actual signed older→newer update | BLOCKED | No Developer ID/notarized release or publisher trust feed available; positive acceptance cannot use ad-hoc fixtures |
| Developer ID signing / Apple notarization | BLOCKED | Owner explicitly has no Apple Developer membership/certificate; no private keys requested or Gatekeeper workaround |
| Candidate DMG technical packaging | PASS | Resource audit, strict local signature verification and disk-image verification; ad-hoc development candidate only |
| Reproducible exact-commit CI | BLOCKED | Workflow implemented; final pushed checkpoint result must be recorded after completion, not inferred from earlier successful CI |
| Public 1.0 distribution | BLOCKED | Requires signing, public OAuth and essential device/provider/recovery acceptance above; candidate artifacts are not a production-ready claim |

See [verification](verification.md), [installation](installation.md),
[security incident](security-incident.md), [account erasure](account-erasure.md),
[signed updates](signed-updates.md), [privacy](privacy.md) and
[release notes](release-notes.md). No billing, teams, Windows, OneDrive, native
phone application, foundation model or marketing site was added.
