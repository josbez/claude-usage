#!/bin/bash
# Bouwt dist/ClaudeUsage.app en faalt luid als er iets mis is.
# Gebruikt door scripts/deploy.sh en scripts/make-dmg.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

# Systeem-Python (3.9): daar staan py2app, pyobjc en pycryptodome. Een Homebrew-
# 'python3' eerder in PATH heeft die niet en bouwt stilletjes niets.
PY=/usr/bin/python3
APP=dist/ClaudeUsage.app

fail() { echo "✗ $*" >&2; exit 1; }

echo "🧪 Tests..."
"$PY" -m pytest -q || fail "tests falen — niet gebouwd"

echo "🔎 Import-check (PyObjC-selectors)..."
"$PY" -c "import app" || fail "'import app' faalt — niet gebouwd"

echo "📦 Building ClaudeUsage.app..."
rm -rf build dist
BUILD_LOG=$(mktemp -t claudeusage-build)
if ! "$PY" setup.py py2app > "$BUILD_LOG" 2>&1; then
    tail -30 "$BUILD_LOG" >&2
    fail "py2app faalde (volledige log: $BUILD_LOG)"
fi
rm -f "$BUILD_LOG"
[ -x "$APP/Contents/MacOS/ClaudeUsage" ] || fail "$APP ontbreekt na build"

for f in core.py dashboard.html fetch_limits.py ClaudeUsage.icns; do
    [ -f "$APP/Contents/Resources/$f" ] || fail "$f ontbreekt in bundle-Resources (setup.py DATA_FILES?)"
done

# Oplopend buildnummer, zodat je aan de draaiende app kunt zien welke build het is.
VERSION=$(date +%Y%m%d.%H%M%S)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Ad-hoc signature ná de plist-wijziging (anders klopt de seal niet meer).
codesign --force --deep -s - "$APP" 2>/dev/null || fail "codesign faalde"
codesign --verify --deep "$APP" || fail "codesign-verificatie faalde"

echo "✓ Build $VERSION klaar: $APP"
