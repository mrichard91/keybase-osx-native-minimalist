#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/keybase-minimal-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/keybase-minimal-swift-cache"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
xcrun swift build --build-system native --disable-sandbox -c release
APP="$PWD/build/Keybase Minimal.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(xcrun swift build --build-system native --disable-sandbox -c release --show-bin-path)"
cp "$BIN_DIR/KeybaseMinimal" "$APP/Contents/MacOS/KeybaseMinimal"
for resource in "$BIN_DIR"/*.bundle; do
    if [ -d "$resource" ]; then cp -R "$resource" "$APP/Contents/Resources/"; fi
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>KeybaseMinimal</string>
<key>CFBundleIdentifier</key><string>io.github.mrichard91.keybase-minimal</string>
<key>CFBundleName</key><string>Keybase Minimal</string>
<key>CFBundleDisplayName</key><string>Keybase Minimal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Local builds are ad-hoc signed with hardened runtime, without exception entitlements.
# Distribution requires an explicit Developer ID identity and notarization.
/usr/bin/codesign --force --options runtime --sign "${KEYBASE_MINIMAL_SIGN_IDENTITY:--}" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
