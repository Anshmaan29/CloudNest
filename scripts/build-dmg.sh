#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d build/CloudNest.app ]; then bash scripts/build-mac.sh; fi
# Native drag-to-Applications package. The app remains a local ad-hoc preview
# until the owner supplies a Developer ID identity and notarization credentials.
codesign --verify --strict build/CloudNest.app
node scripts/audit-native-bundle.mjs build/CloudNest.app
stage="$(mktemp -d "$PWD/build/.dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto build/CloudNest.app "$stage/CloudNest.app"
node scripts/audit-native-bundle.mjs "$stage/CloudNest.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/READ ME.txt" <<'TEXT'
CloudNest Storage — local preview

Drag CloudNest into Applications and launch it.
This preview is ad-hoc signed, not notarized for public distribution.
Read docs/installation.md in the source repository for setup and release limits.
Connect your own Google account and start with a disposable test folder.
Archiving retains originals. Cleanup requires two separate approvals.
TEXT
node scripts/audit-native-bundle.mjs --dmg-stage "$stage"
image="build/CloudNest-macOS-$(uname -m).dmg"
candidate="$(mktemp -d "$PWD/build/.dmg-candidate.XXXXXX")"
trap 'rm -rf "$stage" "$candidate"' EXIT
if [ -e "$image" ]; then mv "$image" "build/CloudNest-macOS-$(uname -m).previous-$(date +%s).dmg"; fi
hdiutil create -quiet -volname CloudNest -srcfolder "$stage" -format UDZO "$candidate/candidate.dmg"
hdiutil verify "$candidate/candidate.dmg"
mv "$candidate/candidate.dmg" "$image"
echo "Created $image (local preview; public signing/notarization still required)."
