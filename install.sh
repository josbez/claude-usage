#!/bin/bash
# Installs Usage Meter (ClaudeUsage.app) as a background app (LaunchAgent) for the current user.
# Requires: ClaudeUsage.app is already in /Applications.
set -e

APP=/Applications/ClaudeUsage.app
LABEL=com.jos.claude-usage
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -d "$APP" ]; then
    echo "✗ $APP not found. Drag Usage Meter to Applications first."
    exit 1
fi

if [ ! -d "/Applications/Claude.app" ]; then
    echo "⚠ Claude desktop app not found in /Applications."
    echo "  Usage Meter reads the session from that app — install it and sign in first via https://claude.ai/download"
fi

# The app is not Apple-notarized. Without this step Gatekeeper blocks the first launch.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/ClaudeUsage</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-usage.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-usage-error.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "✓ Usage Meter installed and started. Click ◆ in the menu bar."
echo "  First time: macOS asks for access to the 'Claude Safe Storage' key — choose 'Always Allow'."
echo "  First numbers appear after ~10–20 s. Log: ~/Library/Logs/ClaudeUsage.log"
