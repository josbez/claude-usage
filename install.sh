#!/bin/bash
# Installeert ClaudeUsage als achtergrond-app (LaunchAgent) voor de huidige gebruiker.
# Vereist: ClaudeUsage.app staat al in /Applications.
set -e

APP=/Applications/ClaudeUsage.app
LABEL=com.jos.claude-usage
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -d "$APP" ]; then
    echo "✗ $APP niet gevonden. Sleep ClaudeUsage.app eerst naar Applications."
    exit 1
fi

if [ ! -d "/Applications/Claude.app" ]; then
    echo "⚠ Claude desktop-app niet gevonden in /Applications."
    echo "  ClaudeUsage leest de sessie uit die app — installeer en log eerst in via https://claude.ai/download"
fi

# De app is niet Apple-notarized. Zonder deze stap blokkeert Gatekeeper de eerste start.
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

echo "✓ ClaudeUsage geïnstalleerd en gestart. Klik ◆ in de menubalk."
echo "  Eerste keer: macOS vraagt toegang tot de sleutel 'Claude Safe Storage' — kies 'Always Allow'."
echo "  Eerste cijfers verschijnen na ~10–20 s. Logboek: ~/Library/Logs/ClaudeUsage.log"
