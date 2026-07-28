#!/bin/bash
# Herbouw de app bundle en herstart
set -e
cd "$(dirname "$0")"

echo "📦 Building ClaudeUsage.app..."
python3 setup.py py2app --quiet 2>&1 | grep -v "^$" | tail -5

echo "🔄 Deploying..."
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist 2>/dev/null || true
pkill -f "ClaudeUsage" 2>/dev/null || true
sleep 1

rm -rf /Applications/ClaudeUsage.app
cp -R dist/ClaudeUsage.app /Applications/

launchctl load ~/Library/LaunchAgents/com.jos.claude-usage.plist
sleep 2
echo "✓ Klaar — app draait zonder dock-icon"
