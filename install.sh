#!/bin/bash
# Installeert ClaudeUsage als achtergrond-app (LaunchAgent) voor de huidige gebruiker.
# Vereist: ClaudeUsage.app staat al in /Applications.
set -e

APP=/Applications/ClaudeUsage.app
PLIST="$HOME/Library/LaunchAgents/com.claudeusage.menubar.plist"

if [ ! -d "$APP" ]; then
    echo "✗ $APP niet gevonden. Sleep ClaudeUsage.app eerst naar Applications."
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudeusage.menubar</string>
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

echo "✓ ClaudeUsage geïnstalleerd en gestart. Klik ◆ in de menubalk."
echo "  Herstart je Mac? App start vanzelf mee."
