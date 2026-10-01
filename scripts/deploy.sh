#!/bin/bash
# Herbouwt de app, rolt uit naar /Applications, herstart de LaunchAgent
# en verifieert dat de nieuwe build echt draait én data ophaalt.
#   ./scripts/deploy.sh --swift          → Swift-versie (taak 35) — de gewone route
#   ./scripts/deploy.sh                  → Python-versie; weigert als er al een
#                                          Swift-app in /Applications staat
#   ./scripts/deploy.sh --force-python   → Python-versie toch over Swift heen
#                                          (alleen voor een bewuste noodrelease)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/ClaudeUsage.app
BIN="$APP/Contents/MacOS/ClaudeUsage"
PLIST="$HOME/Library/LaunchAgents/com.jos.claude-usage.plist"
LIMITS="$HOME/.claude/usage-limits.json"
LOG="$HOME/Library/Logs/ClaudeUsage.log"
FETCH_WAIT_SEC=60

fail() {
    echo "✗ $*" >&2
    echo "--- laatste regels $LOG" >&2
    tail -15 "$LOG" 2>/dev/null >&2 || true
    echo "--- /tmp/claude-usage-error.log" >&2
    tail -15 /tmp/claude-usage-error.log 2>/dev/null >&2 || true
    exit 1
}

MODE="${1:-python}"
case "$MODE" in
    --swift|python|--force-python) ;;
    *) echo "✗ onbekende optie: $MODE (gebruik --swift of --force-python)" >&2; exit 1 ;;
esac

# Vangnet: een kale deploy.sh zou de Python-versie over de Swift-app zetten.
# fetch.js zit alleen in de Swift-bundle (de Python-bundle heeft core.py).
if [ "$MODE" = python ] && [ -f "$APP/Contents/Resources/fetch.js" ]; then
    echo "✗ In /Applications staat de Swift-versie; deze deploy zou hem vervangen door Python." >&2
    echo "  Bedoelde je ./scripts/deploy.sh --swift ?" >&2
    echo "  Python er bewust overheen zetten (noodrelease): ./scripts/deploy.sh --force-python" >&2
    exit 1
fi

if [ "$MODE" = --swift ]; then
    ./scripts/build-swift.sh --release
    SRC=dist-swift/ClaudeUsage.app
else
    ./scripts/build.sh
    SRC=dist/ClaudeUsage.app
fi

[ -f "$PLIST" ] || { echo "✗ LaunchAgent ontbreekt — draai eerst ./install.sh" >&2; exit 1; }

fetched_at() {
    /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('fetched_at',''))" "$LIMITS" 2>/dev/null || true
}
BEFORE=$(fetched_at)

echo "🔄 Deploying..."
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
sleep 1

rm -rf "$APP"
cp -R "$SRC" /Applications/
launchctl load "$PLIST"

# 1. Draait het proces?
for _ in $(seq 1 10); do
    pgrep -f "$BIN" >/dev/null && break
    sleep 1
done
pgrep -f "$BIN" >/dev/null || fail "app-proces draait niet na start"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "✓ Build $VERSION draait"

# 2. Haalt het nieuwe proces data op? (eerste fetch duurt ~10–20 s)
printf "⏳ Wachten op verse fetch (max %ss)" "$FETCH_WAIT_SEC"
for _ in $(seq 1 "$FETCH_WAIT_SEC"); do
    NOW=$(fetched_at)
    if [ -n "$NOW" ] && [ "$NOW" != "$BEFORE" ]; then
        echo
        echo "✓ fetch geverifieerd ($NOW)"
        exit 0
    fi
    pgrep -f "$BIN" >/dev/null || { echo; fail "app is gecrasht tijdens eerste fetch"; }
    printf "."
    sleep 1
done
echo
fail "geen nieuwe fetched_at binnen ${FETCH_WAIT_SEC}s (was: ${BEFORE:-leeg})"
