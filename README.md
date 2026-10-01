# ClaudeUsage

🇬🇧 English · 🇳🇱 [Nederlands](README.nl.md)

macOS menu bar app that shows your Claude plan usage (5-hour and weekly limits, read from claude.ai) and alerts you when you approach a limit.

The app follows your macOS language: Dutch if that is your first preferred language, English otherwise.

It uses the account that is signed in to the Claude desktop app. It reads the session cookie live from the macOS Keychain and sends nothing to third parties.

## Install (DMG)

1. **[Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg)** (always the latest version; older versions and changelogs are on the [releases page](https://github.com/josbez/claude-usage/releases)) and open it.
2. Drag **ClaudeUsage.app** to the **Applications** folder in the same window.
3. Open Terminal and run:

```bash
bash /Volumes/ClaudeUsage/install.sh
```

This installs a LaunchAgent (starts at login) and removes the Gatekeeper quarantine flag from the app. Then click ◆ in the menu bar.

On first launch macOS asks for access to the Keychain item *Claude Safe Storage*. Choose **Always Allow**. macOS then asks whether ClaudeUsage may send notifications: allow it to get alerts at 80% and 95% of the 5-hour limit and at 90% of the weekly limit. The bell icon in the popover turns notifications on or off. The first numbers appear after about 10–20 seconds.

### Updating

From version 1.2 the app checks daily for a new version. If there is one, an orange arrow appears in the popover (plus a notification). Click it and choose **Update**: the app downloads the update, verifies the digital signature, replaces itself and restarts. Updates without a valid signature are rejected. If you have an older version, update once manually via the DMG above.

The version number is shown next to the title in the popover.

### Why the Terminal step

The app is not Apple-signed or notarized (that requires a paid Developer account). Without `install.sh`, Gatekeeper blocks the first launch, and since macOS 15 Sequoia the old right-click → *Open* trick no longer works. Manual alternative: double-click the app, then go to **System Settings → Privacy & Security** and click **Open Anyway** under *Security*.

### Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

## Building from source

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

`deploy.sh` ends with `✓ fetch geverifieerd` or fails with the last log lines. `CFBundleVersion` is the build time (`YYYYMMDD.HHMMSS`), so you can see which build is running. Script output is in Dutch.

Layout: `core.py` holds all logic without PyObjC (tested in `tests/`); `app.py` is only the menu bar / WebKit glue; `fetch_limits.py` is a standalone debug script for the fetch pipeline; `dev/dashboard.html` is the popover UI (shipped into the bundle root by `setup.py`).

## Making a release

1. Bump the version in `setup.py` (`CFBundleShortVersionString` and `CFBundleVersion`), commit and push.
2. `./scripts/make-dmg.sh` creates `ClaudeUsage.dmg` and `ClaudeUsage.dmg.sig`.
3. Create a GitHub release with tag `vX.Y` and **both** files attached. Without the `.sig`, the in-app updater rejects the release.

The signing key lives in `~/.config/claude-usage/release-signing-key.pem` and never goes into git. Back it up: without it you cannot ship updates that existing installs accept. A key can be created once on a new machine with `scripts/sign-release.py --init`, but a new key also requires a new `UPDATE_PUBLIC_KEY_HEX` in `core.py`, and therefore one manual update for every user.

Forking? Change `UPDATE_REPO` and `UPDATE_PUBLIC_KEY_HEX` in `core.py`, and generate your own signing key.

## Logs and pitfalls

- Log: `~/Library/Logs/ClaudeUsage.log`; fetched data: `~/.claude/usage-limits.json`.
- Usage history (own storage; the API keeps none): `~/.claude/usage-history/YYYY-MM.jsonl`, one line per fetch with raw API values only, about 5.5 MB per month. Stays local.
- **PyObjC selectors:** methods on `NSObject` subclasses become Objective-C selectors (underscore → colon). Callbacks: camelCase with one trailing underscore per argument (`fetchWatchdogFired_`).
- **No Python subprocess from the bundle:** the bundled interpreter helper is badly linked; keep everything in-process.
- **Source ≠ deployed:** changes only take effect after `./scripts/deploy.sh`.

Built with py2app against the system Python (3.9 on macOS); the bundle is universal (x86_64 + arm64) and runs on Intel and Apple Silicon.

## License

[MIT](LICENSE)
