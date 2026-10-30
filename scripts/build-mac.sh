#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release
binary_dir="$(bash scripts/swift.sh build -c release --show-bin-path)"
bundle="build/.CloudNest-$(date +%s).app"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
iconset="build/CloudNest.iconset"
swift scripts/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/CloudNest.icns"
cp "$binary_dir/CloudNest" "$bundle/Contents/MacOS/CloudNest"
/usr/bin/strip -S "$bundle/Contents/MacOS/CloudNest"
cp "$binary_dir/cloudnest-cli" build/cloudnest
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CloudNest</string>
<key>CFBundleIdentifier</key><string>org.cloudnest.os</string>
<key>CFBundleName</key><string>CloudNest</string>
<key>CFBundleIconFile</key><string>CloudNest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier org.cloudnest.os "$bundle"
if [ -d build/CloudNest.app ]; then mv build/CloudNest.app "build/CloudNest.previous-$(date +%s).app"; fi
mv "$bundle" build/CloudNest.app
ditto -c -k --keepParent build/CloudNest.app "build/CloudNest-macOS-$(uname -m).zip"
echo "Built build/CloudNest.app (local ad-hoc signature; not notarized)."
