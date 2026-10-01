# ClaudeUsage

🇬🇧 English · 🇳🇱 [Nederlands](README.nl.md)

macOS menu bar app that shows your Claude plan usage (5-hour and weekly limits, read from claude.ai) and alerts you when you approach a limit.

The app follows your macOS language: Dutch if that is your first preferred language, English otherwise.

It uses the account that is signed in to the Claude desktop app. It reads the session cookie live from the macOS Keychain and sends nothing to third parties.

## Install (DMG)

Requires macOS 11 or later (Apple Silicon and Intel).

1. **[Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg)** (always the latest version; older versions and changelogs are on the [releases page](https://github.com/josbez/claude-usage/releases)) and open it.
2. Drag **ClaudeUsage.app** to the **Applications** folder in the same window.
3. Open Terminal and run:

```bash
bash /Volumes/ClaudeUsage/install.sh
```

This installs a LaunchAgent (starts at login) and removes the Gatekeeper quarantine flag from the app. Then click the face (🚀 and the percentages) in the menu bar.

On first launch macOS asks for access to the Keychain item *Claude Safe Storage*. Choose **Always Allow**. macOS then asks whether ClaudeUsage may send notifications: allow it to get alerts at 80% and 95% of the 5-hour limit and at 90% of the weekly limit. You can turn notifications on or off in settings (the gear in the popover). The first numbers appear after about 10–20 seconds.

### Updating

From version 1.2 the app checks daily for a new version. If there is one, the gear in the popover gets an orange dot (plus a notification). Open settings, click **Update** and confirm: the app downloads the update, verifies the digital signature, replaces itself and restarts. Updates without a valid signature are rejected. If you have an older version, update once manually via the DMG above.

The version number is shown in settings.

### Why the Terminal step

The app is not Apple-signed or notarized (that requires a paid Developer account). Without `install.sh`, Gatekeeper blocks the first launch, and since macOS 15 Sequoia the old right-click → *Open* trick no longer works. Manual alternative: double-click the app, then go to **System Settings → Privacy & Security** and click **Open Anyway** under *Security*.

### Uninstall

From version 2.0: settings (gear) → **Uninstall…** at the bottom. It moves the app to the Trash, stops it starting at login and removes its own files; you choose whether to keep the usage history. Older versions, in Terminal:

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

## Building from source

The repo holds two implementations of the same app:

- **Swift (`swift/`)** — the native rewrite that will ship as **2.0**. Not released yet; the download above is still 1.2.x.
- **Python (`app.py`, `core.py`)** — the current release (1.2.x), built with py2app. Feature-frozen until 2.0 ships; it stays in the repo as the reference the Swift port is tested against.

### Swift (2.0)

Requirements: macOS 11 or later and **Xcode** (not just the command line tools: the tests need XCTest). The Python tests also run during the build, so the system Python needs `pycryptodome` and `pytest` (see below).

```bash
./scripts/build-swift.sh            # pytest + Swift tests + universal build + ad-hoc codesign
                                    # → dist-swift/ClaudeUsage Dev.app (bundle id …claude-usage.dev)
./scripts/build-swift.sh --release  # same, as the real bundle → dist-swift/ClaudeUsage.app
./scripts/deploy.sh --swift         # release build, install to /Applications, restart LaunchAgent, verify a fresh fetch
./scripts/make-dmg.sh --swift       # release build + ClaudeUsage.dmg (+ .sig if the signing key is present)
(cd swift && swift test)            # Swift tests only
```

The **dev build** runs next to the installed app for side-by-side testing: it has its own bundle id, a `β` before the menu bar title and notification titles, and its own files (`~/.claude/*.dev.json`, `~/.claude/usage-history-dev/`, `~/Library/Logs/ClaudeUsage-Dev.log`). The release build uses the same files as the Python app, so an update keeps settings, notification state and history.

Layout: `swift/Sources/UsageCore` is the pure logic (a port of `core.py`, Foundation only); `swift/Sources/ClaudeUsage` is the AppKit glue (menu bar, popover, fetch, notifications, updater). The popover is the same `dev/dashboard.html`.

**Parity with `core.py`:** `scripts/swift-fixtures.py` runs the Python functions on a set of inputs at a fixed time and time zone and writes the results to `swift/Tests/UsageCoreTests/Fixtures/core.json`; the Swift tests must reproduce every output. It also exports `STRINGS` to `swift/Resources/strings.json` and the fetch script to `swift/Resources/fetch.js` — edit those in `core.py` and rerun the script (pytest fails when they are out of sync). `build-swift.sh` runs it for you.

Test hooks: `ClaudeUsage --render-status-image <pct> <out.png>`, `ClaudeUsage --verify-release <dmg> <sig>`, and for the dev build `--test-notification` and `--update-feed <url>` (e.g. a local `file://…/release.json`, to test the updater end to end).

### Python (1.2.x)

Requirements: macOS, Xcode command line tools (`xcode-select --install`), and in the **system Python** (`/usr/bin/python3`, not Homebrew):

```bash
/usr/bin/python3 -m pip install --user py2app pycryptodome pyobjc pyobjc-framework-UserNotifications pytest
```

Scripts:

```bash
./scripts/build.sh             # tests + import check + py2app + build number + ad-hoc codesign
./scripts/deploy.sh            # build.sh, install to /Applications, restart LaunchAgent, verify a fresh fetch
./scripts/make-dmg.sh          # build.sh + ClaudeUsage.dmg (+ .sig if the signing key is present)
/usr/bin/python3 -m pytest     # tests only
```

Layout: `core.py` holds all logic without PyObjC (tested in `tests/`); `app.py` is only the menu bar / WebKit glue; `fetch_limits.py` is a standalone debug script for the fetch pipeline; `dev/dashboard.html` is the popover UI (shipped into the bundle root by `setup.py`).

`deploy.sh` ends with `✓ fetch geverifieerd` or fails with the last log lines. `CFBundleVersion` is the build time (`YYYYMMDD.HHMMSS`), so you can see which build is running. Script output is in Dutch.

## Making a release

1. Bump the version: `VERSION` in `scripts/build-swift.sh` (Swift) or `CFBundleShortVersionString` and `CFBundleVersion` in `setup.py` (Python). Commit and push.
2. `./scripts/make-dmg.sh --swift` (or without `--swift` for Python) creates `ClaudeUsage.dmg` and `ClaudeUsage.dmg.sig`.
3. Create a GitHub release with tag `vX.Y` and **both** files attached. Without the `.sig`, the in-app updater rejects the release.

Both stacks verify updates with the same key, so the Python app's updater installs the Swift version like any other update (same bundle id `com.jos.claude-usage`, same executable name, so the existing LaunchAgent starts it).

The signing key lives in `~/.config/claude-usage/release-signing-key.pem` and never goes into git. Back it up: without it you cannot ship updates that existing installs accept. A key can be created once on a new machine with `scripts/sign-release.py --init`, but a new key also requires a new public key in the app (and therefore one manual update for every user).

Forking? Change the update repo and public key — `UPDATE_REPO` and `UPDATE_PUBLIC_KEY_HEX` in `core.py`, `updateAPIURL` and `updatePublicKeyHex` in `swift/Sources/UsageCore/Update.swift` — and generate your own signing key.

## Logs and pitfalls

- Log: `~/Library/Logs/ClaudeUsage.log`; fetched data: `~/.claude/usage-limits.json`.
- Usage history (own storage; the API keeps none): `~/.claude/usage-history/YYYY-MM.jsonl`, one line per fetch with raw API values only, about 5.5 MB per month. Stays local.
- **Source ≠ deployed:** changes only take effect after `./scripts/deploy.sh` (`--swift` for the Swift version).
- **Universal builds:** both stacks ship arm64 + x86_64. An update is one-way: an arm64-only release would leave Intel Macs with an app that doesn't start.
- **Python only — PyObjC selectors:** methods on `NSObject` subclasses become Objective-C selectors (underscore → colon). Callbacks: camelCase with one trailing underscore per argument (`fetchWatchdogFired_`).
- **Python only — no Python subprocess from the bundle:** the bundled interpreter helper is badly linked; keep everything in-process.

The Swift version targets macOS 11+. The Python version is built with py2app against the system Python (3.9 on macOS). Both are universal (x86_64 + arm64) and run on Intel and Apple Silicon.

## License

[MIT](LICENSE)
