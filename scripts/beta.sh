#!/bin/bash
# Work in progress goes to the β, never to /Applications: the regular app always
# runs what every user has (a published release, updated through the app).
# Rebuilds the dev build (runs next to the regular app, own settings, log and
# files), restarts it and verifies that it fetches data.
#   ./scripts/beta.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist-swift/ClaudeUsage Dev.app"
BIN="ClaudeUsage Dev.app/Contents/MacOS/ClaudeUsage"
LIMITS="$HOME/.claude/usage-limits-dev/claude-desktop.json"
LOG="$HOME/Library/Logs/ClaudeUsage-Dev.log"
FETCH_WAIT_SEC=60

fail() {
    echo "✗ $*" >&2
    echo "--- last lines of $LOG" >&2
    tail -15 "$LOG" 2>/dev/null >&2 || true
    exit 1
}

./scripts/build-swift.sh

fetched_at() { plutil -extract fetched_at raw -o - "$LIMITS" 2>/dev/null || true; }
BEFORE=$(fetched_at)

echo "🔄 Restarting the β..."
pkill -f "$BIN" 2>/dev/null || true
sleep 1
open "$APP"

for _ in $(seq 1 10); do
    pgrep -f "$BIN" >/dev/null && break
    sleep 1
done
pgrep -f "$BIN" >/dev/null || fail "β not running after start"
echo "✓ β build $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist") running"

printf "⏳ Waiting for fresh fetch (max %ss)" "$FETCH_WAIT_SEC"
for _ in $(seq 1 "$FETCH_WAIT_SEC"); do
    NOW=$(fetched_at)
    if [ -n "$NOW" ] && [ "$NOW" != "$BEFORE" ]; then
        echo
        echo "✓ fetch verified ($NOW)"
        exit 0
    fi
    pgrep -f "$BIN" >/dev/null || { echo; fail "β crashed during first fetch"; }
    printf "."
    sleep 1
done
echo
fail "no new fetched_at within ${FETCH_WAIT_SEC}s (was: ${BEFORE:-empty})"
