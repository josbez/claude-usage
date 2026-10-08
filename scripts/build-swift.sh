#!/bin/bash
# Bouwt de app als .app en faalt luid als er iets mis is.
#
#   ./scripts/build-swift.sh          → dist-swift/ClaudeUsage Dev.app
#                                       (bundle-id com.jos.claude-usage.dev; draait
#                                       naast de gewone app, eigen instellingen en log)
#   ./scripts/build-swift.sh --release → dist-swift/ClaudeUsage.app
#                                       (bundle-id com.jos.claude-usage)
#   VERSION=2.1 OUT_DIR=/tmp/x ./scripts/build-swift.sh
#                                     → andere versie/map, bv. voor een update-test
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-3.0}"
OUT_DIR="${OUT_DIR:-dist-swift}"
MODE=dev
[ "${1:-}" = "--release" ] && MODE=release

if [ "$MODE" = dev ]; then
    NAME="ClaudeUsage Dev"; BUNDLE_ID="com.jos.claude-usage.dev"; DISPLAY="Usage Meter Dev"
else
    NAME="ClaudeUsage"; BUNDLE_ID="com.jos.claude-usage"; DISPLAY="Usage Meter"
fi
# NAME = the .app file and stays (the updater expects ClaudeUsage.app in the DMG);
# DISPLAY = what users see: menu bar tooltip, notifications, Finder (taak 57b).
APP="$OUT_DIR/$NAME.app"
BUILD=$(date +%Y%m%d.%H%M%S)

fail() { echo "✗ $*" >&2; exit 1; }

echo "🧪 Swift-tests..."
(cd swift && swift test -q 2>&1 | tail -5) || fail "Swift-tests falen — niet gebouwd"

echo "📦 Building $NAME.app..."
# Universal (Apple Silicon + Intel): an update is one-way, Intel Macs must keep working.
ARCHS=(--arch arm64 --arch x86_64)
(cd swift && swift build -c release "${ARCHS[@]}" -q) || fail "swift build faalde"
BIN="$(cd swift && swift build -c release "${ARCHS[@]}" --show-bin-path)/ClaudeUsage"
[ -x "$BIN" ] || fail "$BIN ontbreekt na build"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsage"
cp dev/dashboard.html swift/Resources/strings.json swift/Resources/fetch.js icon/ClaudeUsage.icns "$APP/Contents/Resources/"
# Finder shows the display name instead of the file name only through a localized name
for lang in en nl; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$DISPLAY" "$DISPLAY" \
        > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>ClaudeUsage</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" || fail "codesign faalde"
codesign --verify "$APP" || fail "code-signature ongeldig"
echo "✓ $APP ($(du -sh "$APP" | cut -f1), build $BUILD)"
