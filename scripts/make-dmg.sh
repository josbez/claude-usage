#!/bin/bash
# Builds ClaudeUsage.app and packs it into a shareable DMG (+ .sig).
#   ./scripts/make-dmg.sh
# (--swift is still accepted as an argument; since task 47 there is only the Swift version)
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    ""|--swift) ;;
    *) echo "✗ unknown option: $1" >&2; exit 1 ;;
esac

./scripts/build-swift.sh --release
SRC=dist-swift/ClaudeUsage.app

STAGE=$(mktemp -d)
chmod 755 "$STAGE"
cp -R "$SRC" "$STAGE/"
cp install.sh "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG=ClaudeUsage.dmg
rm -f "$DMG" "$DMG.sig"
hdiutil create -volname "Usage Meter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG done ($(du -h "$DMG" | cut -f1))"

# Signature for in-app updates. Without a .sig the updater rejects the DMG.
if [ -f "$HOME/.config/claude-usage/release-signing-key.pem" ]; then
    "$SRC/Contents/MacOS/ClaudeUsage" --sign-release "$DMG"
    "$SRC/Contents/MacOS/ClaudeUsage" --verify-release "$DMG" "$DMG.sig"
    echo "  Release: upload both $DMG and $DMG.sig"
else
    echo "⚠ No signing key — $DMG is unsigned and cannot be installed via the in-app update."
fi
