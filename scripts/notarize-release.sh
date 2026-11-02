#!/bin/bash
# Operator-only: requires a Developer ID identity and an existing notary Keychain profile.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if [ "$#" -ne 3 ]; then
  echo 'Usage: CLOUDNEST_DEVELOPER_ID_APPLICATION="Developer ID Application: …" bash scripts/notarize-release.sh APP_PATH NEW_ZIP_PATH NOTARY_KEYCHAIN_PROFILE' >&2
  exit 64
fi
app="$1"
output="$2"
profile="$3"
identity="${CLOUDNEST_DEVELOPER_ID_APPLICATION:-}"
case "$identity" in 'Developer ID Application: '*) ;; *) echo 'A Developer ID Application identity is required. No signing or submission was attempted.' >&2; exit 1;; esac
if [ ! -f "$app/Contents/Helpers/CloudNestUpdateHelper" ] || [ -e "$output" ]; then
  echo 'The prepared helper is missing or the output already exists. Nothing was submitted.' >&2
  exit 1
fi
node scripts/audit-native-bundle.mjs "$app"
/usr/bin/codesign --force --timestamp --options runtime --sign "$identity" --identifier org.cloudnest.os.update-helper "$app/Contents/Helpers/CloudNestUpdateHelper"
/usr/bin/codesign --force --timestamp --options runtime --sign "$identity" --identifier org.cloudnest.os "$app"
/usr/bin/codesign --verify --strict --deep "$app"
node scripts/audit-native-bundle.mjs "$app"
private_stage="$(mktemp -d "${TMPDIR:-/tmp}/cloudnest-notary.XXXXXXXX")"
trap 'rm -rf "$private_stage"' EXIT
/usr/bin/ditto -c -k --keepParent "$app" "$private_stage/submission.zip"
# Credentials remain in the existing Keychain profile; no password/token is passed here.
/usr/bin/xcrun notarytool submit "$private_stage/submission.zip" --keychain-profile "$profile" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
/usr/bin/codesign --verify --strict --deep "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app" > "$private_stage/assessment.log" 2>&1
if ! /usr/bin/grep -qx 'source=Notarized Developer ID' "$private_stage/assessment.log"; then
  echo 'The signed app did not pass notarized Developer ID assessment; no release ZIP was published.' >&2
  exit 1
fi
# The final updater ZIP is audited and deterministic, generated AFTER app stapling.
node scripts/audit-native-bundle.mjs "$app" --zip "$output"
echo 'Developer ID signature, notarization, stapling and final ZIP checks passed.'
