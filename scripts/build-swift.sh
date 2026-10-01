#!/bin/bash
# Bouwt de Swift-versie (taak 35) als .app en faalt luid als er iets mis is.
#
#   ./scripts/build-swift.sh          → dist-swift/ClaudeUsage Dev.app
#                                       (bundle-id com.jos.claude-usage.dev; draait
#                                       naast de gewone app, eigen instellingen en log)
#   ./scripts/build-swift.sh --release → dist-swift/ClaudeUsage.app
#                                       (bundle-id com.jos.claude-usage; pas vanaf fase 5)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.0"
MODE=dev
[ "${1:-}" = "--release" ] && MODE=release

if [ "$MODE" = dev ]; then
    NAME="ClaudeUsage Dev"; BUNDLE_ID="com.jos.claude-usage.dev"; DISPLAY="Claude Usage (dev)"
else
    NAME="ClaudeUsage"; BUNDLE_ID="com.jos.claude-usage"; DISPLAY="Claude Usage"
fi
APP="dist-swift/$NAME.app"
BUILD=$(date +%Y%m%d.%H%M%S)

fail() { echo "✗ $*" >&2; exit 1; }

echo "🔗 Gedeelde teksten en fixtures bijwerken..."
/usr/bin/python3 scripts/swift-fixtures.py > /dev/null || fail "swift-fixtures.py faalt"

echo "🧪 Swift-tests..."
(cd swift && swift test -q 2>&1 | tail -5) || fail "Swift-tests falen — niet gebouwd"

echo "📦 Building $NAME.app..."
(cd swift && swift build -c release -q) || fail "swift build faalde"
BIN="swift/.build/release/ClaudeUsage"
[ -x "$BIN" ] || fail "$BIN ontbreekt na build"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsage"
cp dev/dashboard.html swift/Resources/strings.json icon/ClaudeUsage.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>ClaudeUsage</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" || fail "codesign faalde"
codesign --verify "$APP" || fail "code-signature ongeldig"
echo "✓ $APP ($(du -sh "$APP" | cut -f1), build $BUILD)"
