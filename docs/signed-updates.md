# Signed update foundation

CloudNest checks for updates only after an explicit click. It has no update
poller, privileged installer, automatic app replacement or Gatekeeper bypass.
The preview has no publisher key, signed public feed or Developer ID release;
its update UI must show **unavailable** until those release gates are met.

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

## Download and manual handoff

`ReleaseUpdate.check` verifies the feed; `stage` re-verifies it before downloading.
Network sessions are ephemeral, without cookies, credential storage or cache.
Requests have a 30-second request timeout and a 30-second feed / ten-minute
artifact resource deadline. Transfers are streamed through serial URLSession
delegate chunks into exclusive mode-0600 files in a mode-0700 private job.
SHA-256 and exact signed size must match before the artifact is renamed out of
`.partial`. The signed envelope is retained alongside it. No recursive deletion
of unknown staging members occurs, and no interrupted job resumes automatically.

The view can reveal the verified archive in Finder. The user extracts or mounts
it manually and selects the resulting app for **Validate extracted app**.
Before reporting a successful handoff, CloudNest rechecks the staged artifact
hash and manifest, checks the app's bundle ID/version/build, validates all signed
architectures with an Apple Developer ID Application requirement pinned to the
configured Team ID, and requires a successful Gatekeeper assessment specifically
reporting `Notarized Developer ID`. Ad-hoc signatures, another team, missing
notarization, disabled/unavailable assessment tools and mismatched metadata fail
closed. Nothing is installed, executed, copied into Applications or replaced.
Validation is a point-in-time check; normal macOS checks still apply during the
user's subsequent manual installation.

## Verification and remaining gates

Run `bash scripts/swift.sh test --filter update`. Synthetic ephemeral signing keys
exist only in test memory. Tests cover version ordering, signed feeds, tampering,
wrong keys, malformed config, compatibility/expiry/size, allowed and denied
redirects, header stripping, streamed private downloads, wrong bytes, protected
staging and unsigned-app rejection. These tests do not establish a working
public release feed or prove a real notarized app passes validation.

Required before claiming automatic updates complete: provision and protect the
real publisher key, obtain Developer ID membership/signing/notarization, publish
and test the actual GitHub release chain, test a signed older-to-newer release on
fresh Macs, then independently review any future replacement/relaunch/rollback
implementation. Key rotation must ship through an already trusted release or a
separately reviewed trust-recovery process; this module offers no unsigned
remote key replacement.

Official references: [CryptoKit signing keys](https://developer.apple.com/documentation/cryptokit/curve25519/signing/publickey),
[static code validation](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
