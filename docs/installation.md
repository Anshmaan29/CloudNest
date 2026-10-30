# Install the native preview

CloudNest 0.3 is a local preview for macOS 14 or newer. Current device acceptance
is on Apple Silicon only. It is ad-hoc signed, not Developer ID signed or
notarized, and must not be advertised as a public production release.

Build with `npm ci`, `npm run check`, and `npm run build:mac` from the repository.
`bash scripts/build-dmg.sh` creates a compressed disk image containing the app,
a drag-to-Applications shortcut and the preview notice. Open the DMG, copy
CloudNest into Applications, and launch the copied app. The ZIP also contains
the same native bundle. Do not modify macOS security settings for this preview.

The core app uses system frameworks. Node and Swift are build tools, not bundled
runtime requirements. There is no login helper or automatic updater yet.

## First use

1. Follow [Google setup](setup.md) to create your own Desktop OAuth configuration.
   Import its JSON in Settings; complete sign-in in your normal browser.
2. Choose a disposable local test folder outside a Git checkout. Set size/age
   filters for a recommendation scan, or choose Archive folder for a complete tree.
3. Archive, then restore into another empty location. Compare content before
   considering cleanup. The folder root manifest preserves hierarchy and empty
   directories and can restore without the original local catalog.
4. Use Archive Library to search file jobs, check cloud health or recover a
   restore-only file catalog from CloudNest's app-owned Drive manifests.
5. File cleanup requires two separate approvals: move into managed recovery,
   then permanently remove that copy after fresh verification. Folder cleanup
   is unavailable. Uploaded bytes are never a promise of SSD space saved.

The current Google connection is a self-hosted testing setup. A broadly
usable consumer onboarding flow requires a distributable OAuth client and
its required Google verification. Each install currently supplies its own
client; no credentials are embedded in the app or repository.

## Updates and uninstall

For a preview update, finish or pause work, quit CloudNest, and replace the app.
Keep Application Support state and Keychain items to resume transfers. Retain
portable manifests outside the app bundle. No background service starts on login.

To uninstall, put back any retained recovery copies through the app first,
export/save your manifests, optionally revoke Google access, quit, and remove
the application. Removing the app alone does not remove cloud archives, local
catalog data, Keychain items or managed recovery copies. CloudNest never silently
removes those during uninstall. Review `~/Library/Application Support/CloudNest/`
and Keychain service `org.cloudnest.os` yourself if intentionally erasing local
configuration. Preserve independent backups before removing recovery records.
