# Workspace archive incident — 1 November 2026

Status: **containment verified; credential recovery and live signing-key activation in progress.** This blocks a production release.

A whole-working-folder ZIP included operational files under `work/`: two copies of the active Brain secret bundle, the raw owner credential, private evidence and prior test credentials. Keeping those setup files inside the working folder was unsafe for a whole-folder export. New operational credentials and recovery state are stored in owner-private Application Support directories outside the workspace.

## Verified scope

- The reported carrier was inspected without extracting or printing credential values. Exact comparisons confirmed the active Brain client secret, refresh grant, owner credential and signing key.
- Seven other CloudNest distributions had no matches for the registered secret values. The inspected reachable Git history also had no matches. These checks are scoped evidence, not a universal claim that every possible secret or remote copy was discovered.
- Additional exposed hosted test tokens were identified. Current Mac Storage credentials were distinct; current Codex credential values had no exact matches in the carrier. No Cloudflare raw credential structures were found; its encrypted credential cache was outside the archive and was not decrypted.
- The local carrier was moved into a private quarantine with its original bytes and checksum preserved. Removal from any service where it was previously uploaded is not verified.

## Confirmed containment

- Replaced the Worker owner verifier. The retired raw owner credential returns HTTP 401; the replacement authenticates.
- Cleared static MCP credentials and revoked pre-incident managed/OAuth grants. Existing AI clients require explicit reconnection after recovery.
- Revoked the affected Google project grant and verified rejection of retired credentials. The owner reset the dedicated Brain client secret; its replacement was validated and deployed. The separate Mac Storage configuration was not replaced.
- Froze canonical writes and preserved a private recovery snapshot of the operational D1 tables before rotation.

## Recovery implementation

Owner-only, bounded, restart-safe rotation snapshots trusted D1 heads and every historical revision, compares exact canonical bytes, and signs new historical checkpoints plus a complete root under a fresh key. The compromised key is never retained as a verification fallback. Missing, changed or incomplete history stops activation. Persistent locks, request leases and atomic publication prevent stale requests from releasing another operation's maintenance state.

Rebuild also respects surviving trusted revision/head watermarks, including private and deleted updates after rotation. Simultaneous loss of the independent watermark and a newer canonical prefix cannot be inferred from older surviving data; recover from a trusted independent backup in that case. See [key rotation](vault-key-rotation.md).

Packaging now exports only a clean committed Git snapshot and audits bounded filenames/content before publication. Native app, ZIP and DMG staging have explicit member allowlists. Index and complete-history checks run in CI; see [safe distribution](source-release-safety.md).

## Open owner and verification actions

- Complete fresh same-account Google consent and verify canonical reads after grant renewal.
- Complete and verify live fresh-key activation, then retire the staging secret and refresh the independent recovery bundle.
- Finish the native Keychain credential replacement through the owner-approved macOS permission prompt.
- Remove old uploaded copies through the service where they were shared. Local quarantine does not recall remote copies.
- Public release remains blocked until incident recovery is verified and the broader release checklist passes.
