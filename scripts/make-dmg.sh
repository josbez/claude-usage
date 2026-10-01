#!/bin/bash
# Bouwt ClaudeUsage.app en verpakt 'm in een deelbare DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

STAGE=$(mktemp -d)
chmod 755 "$STAGE"
cp -R dist/ClaudeUsage.app "$STAGE/"
cp install.sh "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG=ClaudeUsage.dmg
rm -f "$DMG" "$DMG.sig"
hdiutil create -volname "ClaudeUsage" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG klaar ($(du -h "$DMG" | cut -f1))"

# Handtekening voor in-app updates. Zonder .sig weigert de updater de DMG.
if [ -f "$HOME/.config/claude-usage/release-signing-key.pem" ]; then
    /usr/bin/python3 scripts/sign-release.py
    echo "  Release: upload zowel $DMG als $DMG.sig"
else
    echo "⚠ Geen signing key — $DMG is niet ondertekend en kan niet via de in-app update geïnstalleerd worden."
fi
