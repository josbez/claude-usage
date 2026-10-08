#!/bin/bash
# Bouwt ClaudeUsage.app en verpakt 'm in een deelbare DMG (+ .sig).
#   ./scripts/make-dmg.sh
# (--swift mag nog als argument; sinds taak 47 is er alleen de Swift-versie)
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    ""|--swift) ;;
    *) echo "✗ onbekende optie: $1" >&2; exit 1 ;;
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

echo "✓ $DMG klaar ($(du -h "$DMG" | cut -f1))"

# Handtekening voor in-app updates. Zonder .sig weigert de updater de DMG.
if [ -f "$HOME/.config/claude-usage/release-signing-key.pem" ]; then
    "$SRC/Contents/MacOS/ClaudeUsage" --sign-release "$DMG"
    "$SRC/Contents/MacOS/ClaudeUsage" --verify-release "$DMG" "$DMG.sig"
    echo "  Release: upload zowel $DMG als $DMG.sig"
else
    echo "⚠ Geen signing key — $DMG is niet ondertekend en kan niet via de in-app update geïnstalleerd worden."
fi
