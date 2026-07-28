#!/bin/bash
# Bouwt ClaudeUsage.app en verpakt 'm in een deelbare DMG.
set -e
cd "$(dirname "$0")"

echo "📦 Building ClaudeUsage.app..."
rm -rf build dist
python3 setup.py py2app --quiet 2>&1 | grep -v "^$" | tail -5

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
