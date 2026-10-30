# Privacy and data retention — preview draft

This document describes the current source implementation. It is not a claim
that a managed CloudNest service or public consumer release exists.

## Where data lives

- **On your Mac:** chosen folder paths, file identities, hashes, transfer offsets,
  archive/recovery history and portable manifests live in a private Application
  Support directory. UserDefaults stores scan rules and protected folders.
  OAuth client configuration, tokens and resumable upload capabilities use
  device-bound macOS Keychain storage. No credentials belong in manifests.
- **In your Google account:** explicitly archived file content and recovery
  manifests are uploaded to app-created CloudNest Storage folders. File manifests
  contain original paths for recovery reference. Folder root manifests embed
  file manifests, so those paths are also present in the folder metadata.
  Standard Google account access and retention policies apply.
- **In your self-hosted Cloudflare account:** the current feasibility Worker/D1
  stores disposable test memories and access audit events. It is not yet a
  canonical personal memory vault; do not store personal information there.

Storage runs independently of Cloudflare. The native app does not automatically
scan all Drive content or read an entire home folder. Scanning is user initiated.
Protected/cloud/database/repository content is excluded conservatively. No
analytics, advertisements, model inference, crash-report upload or background
GPU renderer is implemented in the app.

## Controls and deletion

You choose folders, destinations, uploads and cleanup. Uploads retain originals.
Moving an original into managed recovery retains all local bytes. Permanent
removal requires a second approval and fresh local/cloud integrity checks.
Unrelated Trash items are never emptied. Folder archives have no cleanup action.
Revocation stops future Google access but does not erase cloud files.

Application removal does not delete archives or recovery information. You can
save the JSON manifests and use supported Google interfaces to access your
files. Automatic account-wide data deletion, audit-retention controls and a
complete export of the future Brain vault are not implemented; these are
release blockers. See [installation](installation.md) for deliberate uninstall.

## Public source and releases

Source checkpoints exclude credentials, account endpoints, cloud identifiers,
local catalogs, screenshots and private test data. The public-source audit
checks the Git index without printing suspected secret values. It is a guard,
not a substitute for human review. Release binaries are stripped before signing.
No personal data is embedded into the distributable application.

The optional bounded OS provenance marker is included in new recovery manifests
as exact metadata evidence. It is not applied to restored files; macOS controls
the live security marker. Unsupported user attributes/resource forks block local
cleanup rather than being silently discarded. Older manifests without the marker
remain readable for restore, but may no longer qualify for cleanup. The app's
source and Git history contain no runtime marker values from your files.
