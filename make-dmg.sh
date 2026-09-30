#!/bin/bash
# Bouwt ClaudeUsage.app en verpakt 'm in een deelbare DMG.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

STAGE=$(mktemp -d)
chmod 755 "$STAGE"
cp -R dist/ClaudeUsage.app "$STAGE/"
cp install.sh "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG=ClaudeUsage.dmg
rm -f "$DMG"
hdiutil create -volname "ClaudeUsage" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG klaar ($(du -h "$DMG" | cut -f1))"
