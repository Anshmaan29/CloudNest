# Signed updates and recovery

CloudNest checks and installs updates only after an explicit click. A minimal
unprivileged helper waits for CloudNest to quit, verifies the offered application,
exchanges the application atomically and waits for a private launch acknowledgment.
There is no update poller or Gatekeeper bypass. The bundled UI shows **unavailable**
until a real publisher key, pinned Developer ID team and signed public feed exist.
Generated fixture tests exercise the installer; they do not establish actual
Developer ID signing, notarization or successful distribution.

## Public build configuration

The optional, code-signed app resource is `CloudNestReleasePublisher.json`, with
exactly these four fields:

```json
{
  "schemaVersion": 1,
  "publicKey": "BASE64_ED25519_PUBLIC_KEY",
  "teamID": "APPLE_TEAM_ID",
  "feedURL": "https://github.com/Anshmaan29/CloudNest/releases/latest/download/cloudnest-update.json"
}
```

The public key must decode to exactly 32 bytes. The Team ID must be the owner's
actual ten-character Developer ID team. These example placeholders deliberately
fail validation. Never bundle an Ed25519 private key, Apple credentials, OAuth
credentials or publishing token. Publisher configuration staging and its strict
packaging allowlist belong to release engineering; the app never downloads a
replacement trust key from an unsigned endpoint.

`ReleaseUpdateConfiguration.bundled(in:)` returns nil when the resource is absent
and throws on malformed, extra-field or symlinked resources.
`ReleaseUpdateView(configuration:installedVersion:)` is a native Settings panel;
pass a reviewed configuration explicitly. A missing configuration disables checks
and explains the release gate.

## Signed feed

The GitHub release asset contains an envelope with exactly `payload` and
`signature`, both canonical base64 strings. Sign the **exact UTF-8 payload JSON
bytes** with Ed25519; the signature is 64 bytes. Payload JSON must have precisely
these fields:

```json
{
  "schemaVersion": 1,
  "version": "1.0.0",
  "build": "10",
  "minimumMacOS": "14.0",
  "architectures": ["arm64", "x86_64"],
  "assetURL": "https://github.com/Anshmaan29/CloudNest/releases/download/v1.0.0/CloudNest.zip",
  "bytes": 123456,
  "sha256": "LOWERCASE_SHA256_OF_EXACT_DOWNLOAD",
  "publishedAt": "2026-11-03T00:00:00Z",
  "expiresAt": "2026-12-03T00:00:00Z"
}
```

This example is a format description, not a live or valid feed. Use the actual
artifact size, SHA-256, version, numeric build and timestamps. Feed validity is
at most 90 days; future publication beyond five minutes and expired feeds are
refused. Stable and prerelease semantic versions compare correctly; build
metadata does not make an equal release newer. An offer must be strictly newer
than the installed version, support this process architecture and meet the
minimum macOS requirement. The envelope is limited to 64 KiB, payload to 32 KiB
and artifact to 200 MiB.

GitHub delivery supports at most three HTTPS redirects. Repository requests must
remain under this repository's exact release download paths. The final CDN host
is exactly `release-assets.githubusercontent.com`, with the production release
asset path shape. Other repositories/hosts, HTTP downgrade, userinfo, custom
ports, loops and further CDN redirects are refused. A fresh GET is constructed
at each hop: Authorization, cookies and other forwarded headers are discarded.
CDN signed query parameters are used transiently for delivery and never logged.
No release publishing token is sent. An unexpected future GitHub delivery shape
fails closed and needs a reviewed application update.

## Download, installation and acknowledgment

`ReleaseUpdate.check` verifies the feed; `stage` re-verifies it before downloading.
Ephemeral sessions omit cookies, credentials and caches. Streaming downloads have
request/resource deadlines and write exclusive mode-0600 files in a mode-0700 job.
Exact SHA-256 and signed size must match before the `.partial` rename. The signed
envelope remains beside the artifact. Interrupted downloads do not resume or
remove unknown files automatically.

Automatic installation accepts only the repository's audited, uncompressed ZIP
format. DMGs remain manual installers. Extraction rechecks the signed artifact,
rejects traversal, links, special files, duplicates, extra ZIP structures and any
unapproved bundle member. Only the native executable, helper, icon, Info.plist,
code signature, optional public client/publisher metadata and stapled ticket are
allowed. The newly extracted app is thus bound to the exact signed ZIP; arbitrary
user-selected applications are never installed through this path.

A candidate must have the exact bundle ID, signed version and numeric build,
pinned Developer ID Application team and a successful assessment reporting
`Notarized Developer ID`. All architectures and nested code are validated.
The new build number must increase. `CloudNestReleaseVersion` binds prereleases
such as `1.0.0-rc.1`; its numeric core must equal the Apple short version `1.0.0`.
Legacy installations fall back to `CFBundleShortVersionString`. The public
publisher configuration must remain identical; unsigned remote key changes are
not accepted.

Only a writable, user-owned `CloudNest.app` in `/Applications` or `~/Applications`
is supported. The app acquires its existing exclusive operation lease before
preparing a private same-volume transaction. The helper has no elevated privilege
and does not kill applications. It waits for the exact original PID/UID/kernel
start identity to exit, checks no other CloudNest is running, rechecks signatures,
notarization and complete bundle hashes, then uses an atomic filesystem exchange.
A shared per-installation lock serializes distinct transaction directories.

The new application receives only a private acknowledgment-file path. Its random
challenge stays inside mode-0700 / mode-0600 transaction files, never a URL or
command argument. After startup health checks, the app validates its own exact
bundle, live helper identity and transaction and writes its acknowledgment. The
helper requires the matching challenge, bundle digest and live new PID/start
identity. The old app is retained privately; user files, memories and credentials
are never part of the exchange.

The parent application must wire these contracts:

```swift
ReleasePublisherSettingsView(acquireInstallation: {
    model.acquireExternalOperation(section: "Settings")
})
// Only after safe startup health checks, with no incompatible migration:
try ReleaseUpdateInstaller.acknowledge(
    arguments: CommandLine.arguments, currentApp: Bundle.main.bundleURL)
```

The returned operation lease must remain held until quit/helper exit. Packaging
must embed and sign `Contents/Helpers/CloudNestUpdateHelper` before signing the
outer application. No fixture verifier is exposed as a public runtime option.

## Failure and recovery

If launch fails and the replacement is not running, the helper re-verifies the
known previous bundle, exchanges it back and relaunches it. If the replacement
is running but does not acknowledge, both copies remain and the state becomes
`needsRecovery`: nothing is swapped underneath a live process. Settings lists
verified interrupted transactions, offers retry when the old/new pairing matches,
and offers explicit rollback when the current/backup pairing matches. Both
choices verify again and require a user-initiated quit. PID reuse is rejected;
renaming a live helper into the backup does not change its process identity.

Rollback restores application code only. It cannot undo catalog or vault schema
migrations. A release must preserve compatibility with its predecessor, and
startup must acknowledge only after safe health checks. Unsupported schemas must
fail before a destructive migration. Database migration rollback remains a
separate release acceptance gate; this installer never copies old user data over
new data. Completed backups are retained, so the user must allow disk space for
the download and both app copies. Partial preparation without a complete plan is
left untouched; it is never interpreted as a valid recovery job or silently
removed. Unknown or tampered transactions cannot trigger replacement.

## Publisher procedure

1. Obtain an actual Apple Developer ID Application identity and store notarization
   authorization using Apple's Keychain profile procedure. No Apple password,
   publishing token or private key belongs in the repository or app bundle.
2. Build the release with the reviewed public publisher resource. Run
   `CLOUDNEST_DEVELOPER_ID_APPLICATION='Developer ID Application: …' bash scripts/notarize-release.sh APP NEW_ZIP KEYCHAIN_PROFILE`.
   The script audits before upload, signs the nested helper and outer app with
   hardened runtime, submits with `notarytool`, staples and validates the app,
   assesses Gatekeeper, and recreates/audits the final distribution ZIP. ZIP files
   cannot themselves be stapled. Never sign a feed for the pre-stapling ZIP.
3. Prepare the exact manifest above using whole-second UTC timestamps, final ZIP
   byte count and SHA-256. Keep a mode-0600 Ed25519 PKCS8 PEM key in the owned
   mode-0700 `~/Library/Application Support/CloudNest/ReleaseSigning` directory,
   outside the workspace. Symlink paths, hardlinks and permissive modes fail.
4. Run `node scripts/sign-update-feed.mjs MANIFEST_JSON AUDITED_ZIP PRIVATE_KEY NEW_FEED_JSON`.
   This streams and verifies the artifact, writes a new envelope exclusively,
   and prints only the public publisher key. Verify this public key matches the
   resource before publishing the final ZIP and `cloudnest-update.json`.
5. Test an actual older-to-newer signed release, failed startup recovery and a
   fresh supported Mac before declaring public update readiness. Trust-key
   rotation requires a separately reviewed trusted-release/recovery procedure.

## Evidence and external gates

Run `bash scripts/test-mac.sh` and `node --test scripts/sign-update-feed.test.mjs`.
Generated fixtures cover signed feed and ZIP tampering, private staging,
traversal/symlink/unknown-member refusal, exact RC metadata, atomic exchange,
challenge mismatch, verified rollback, interrupted-exchange recovery, process
identity and concurrent transaction exclusion. Tests never replace or execute a
real installed application. The signer tests verify independent Ed25519 checking
and refusal of unsafe private inputs. The notarization script is syntax-checked
and its missing-identity refusal is tested.

**BLOCKED without owner certificates/services:** actual Developer ID signing,
notarization, a public signed update feed, installed signed helper/launch acceptance,
and clean-device older-to-newer / migration-compatible rollback acceptance.
Do not label these tests as proof of notarization or public release readiness.

Official references: [Apple static code validation](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[Node Ed25519 signing](https://nodejs.org/api/crypto.html#cryptosignalgorithm-data-key-callback).
