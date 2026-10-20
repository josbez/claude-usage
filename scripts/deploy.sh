#!/bin/bash
# Rebuilds the app, deploys it to /Applications, restarts the LaunchAgent
# and verifies that the new build actually runs and fetches data.
#   ./scripts/deploy.sh
# (--swift is still accepted as an argument; since task 47 there is only the Swift version)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/ClaudeUsage.app
BIN="$APP/Contents/MacOS/ClaudeUsage"
PLIST="$HOME/Library/LaunchAgents/com.jos.claude-usage.plist"
LIMITS="$HOME/.claude/usage-limits/claude-desktop.json"   # taak 55d; until 2.1: usage-limits.json
LOG="$HOME/Library/Logs/ClaudeUsage.log"
FETCH_WAIT_SEC=60

fail() {
    echo "✗ $*" >&2
    echo "--- last lines of $LOG" >&2
    tail -15 "$LOG" 2>/dev/null >&2 || true
    echo "--- /tmp/claude-usage-error.log" >&2
    tail -15 /tmp/claude-usage-error.log 2>/dev/null >&2 || true
    exit 1
}

FORCE=0
case "${1:-}" in
    ""|--swift) ;;
    --force) FORCE=1 ;;
    *) echo "✗ unknown option: $1" >&2; exit 1 ;;
esac

# /Applications only gets a published release: work in progress goes to the β
# (./scripts/beta.sh). Deploying is allowed when HEAD is the release tag.
VERSION=$(sed -n 's/^VERSION="\${VERSION:-\(.*\)}"$/\1/p' scripts/build-swift.sh)
if [ "$FORCE" = 0 ] && [ "$(git tag --points-at HEAD)" != "v$VERSION" ]; then
    echo "✗ HEAD is not release v$VERSION: use ./scripts/beta.sh for work in progress" >&2
    echo "  (the regular app runs what users have; --force to deploy anyway)" >&2
    exit 1
fi

./scripts/build-swift.sh --release
SRC=dist-swift/ClaudeUsage.app

[ -f "$PLIST" ] || { echo "✗ LaunchAgent missing — run ./install.sh first" >&2; exit 1; }

fetched_at() {
    plutil -extract fetched_at raw -o - "${1:-$LIMITS}" 2>/dev/null || true
}
# The first start after 55d moves usage-limits.json into usage-limits/: compare
# against the old file then, or the moved value would pass for a fresh fetch.
BEFORE=$(fetched_at)
[ -n "$BEFORE" ] || BEFORE=$(fetched_at "$HOME/.claude/usage-limits.json")

echo "🔄 Deploying..."
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
sleep 1

rm -rf "$APP"
cp -R "$SRC" /Applications/
launchctl load "$PLIST"

# 1. Is the process running?
for _ in $(seq 1 10); do
    pgrep -f "$BIN" >/dev/null && break
    sleep 1
done
pgrep -f "$BIN" >/dev/null || fail "app process not running after start"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "✓ Build $VERSION running"

# 2. Does the new process fetch data? (first fetch takes ~10–20 s)
printf "⏳ Waiting for fresh fetch (max %ss)" "$FETCH_WAIT_SEC"
for _ in $(seq 1 "$FETCH_WAIT_SEC"); do
    NOW=$(fetched_at)
    if [ -n "$NOW" ] && [ "$NOW" != "$BEFORE" ]; then
        echo
        echo "✓ fetch verified ($NOW)"
        exit 0
    fi
    pgrep -f "$BIN" >/dev/null || { echo; fail "app crashed during first fetch"; }
    printf "."
    sleep 1
done
echo
fail "no new fetched_at within ${FETCH_WAIT_SEC}s (was: ${BEFORE:-empty})"
