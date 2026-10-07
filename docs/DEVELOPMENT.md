# ClaudeUsage — development

For users: see the [README](../README.md).

## Building from source

Requirements: macOS 11 or later and **Xcode** (not just the command line tools: the tests need XCTest).

```bash
./scripts/build-swift.sh            # Swift tests + universal build + ad-hoc codesign
                                    # → dist-swift/ClaudeUsage Dev.app (bundle id …claude-usage.dev)
./scripts/build-swift.sh --release  # same, as the real bundle → dist-swift/ClaudeUsage.app
./scripts/deploy.sh                 # release build, install to /Applications, restart LaunchAgent, verify a fresh fetch
./scripts/make-dmg.sh               # release build + ClaudeUsage.dmg (+ .sig if the signing key is present)
(cd swift && swift test)            # tests only
```

`deploy.sh` ends with `✓ fetch geverifieerd` or fails with the last log lines. `CFBundleVersion` is the build time (`YYYYMMDD.HHMMSS`), so you can see which build is running. Script output is in Dutch.

The **dev build** runs next to the installed app for side-by-side testing: it has its own bundle id, a `β` before the menu bar title and notification titles, and its own files (`~/.claude/*.dev.json`, `~/.claude/usage-history-dev/`, `~/Library/Logs/ClaudeUsage-Dev.log`).

**Layout:**

- `swift/Sources/UsageCore` — pure logic (Foundation only), tested with XCTest.
- `swift/Sources/ClaudeUsage` — the AppKit glue: menu bar, popover, fetch, notifications, updater.
- `dev/dashboard.html` — the popover UI (a WKWebView).
- `swift/Resources/strings.json` — all user-facing text, Dutch and English. Every new key goes in both languages.
- `swift/Resources/fetch.js` — the fetch script for the webview fallback; `UsageCore/NativeFetch.swift` mirrors it, so change them together.
- `swift/Tests/UsageCoreTests/Fixtures/core.json` — frozen expected outputs from the former Python app (1.x, removed in 2.2; see git history). The Swift code must keep reproducing them.

**Test hooks:** `ClaudeUsage --render-status-image <pct> <out.png>`, `--render-menubar-ring <pct> <light|dark> <out.png>`, `--verify-release <file> <file.sig>`, `--sign-release <file>`, `--probe-native-fetch` (HTTP statuses and response key paths, no values), and for the dev build `--test-notification` and `--update-feed <url>` (e.g. a local `file://…/release.json`, to test the updater end to end).

**UI without the app:** `python3 -m http.server 8765` in the repo, open `dev/dashboard.html`, and call `updateData({...})` with sample data (360×296, light and dark).

## Making a release

1. Bump `VERSION` in `scripts/build-swift.sh`. Commit and push.
2. `./scripts/make-dmg.sh` creates `ClaudeUsage.dmg` and `ClaudeUsage.dmg.sig` (signed with `ClaudeUsage --sign-release`, then verified).
3. Create a GitHub release with tag `vX.Y` and **both** files attached. Without the `.sig`, the in-app updater rejects the release.

The signing key lives in `~/.config/claude-usage/release-signing-key.pem` (Ed25519, PKCS#8 PEM) and never goes into git. Back it up: without it you cannot ship updates that existing installs accept. `--sign-release` refuses a key that doesn't match `updatePublicKeyHex`, so a wrong key can't slip into a release.

Forking? Change `updateAPIURL` and `updatePublicKeyHex` in `swift/Sources/UsageCore/Update.swift` and make your own key:

```bash
openssl genpkey -algorithm ed25519 -out ~/.config/claude-usage/release-signing-key.pem
openssl pkey -in ~/.config/claude-usage/release-signing-key.pem -pubout -outform DER | tail -c 32 | xxd -p -c 32
```

The second command prints the public key for `updatePublicKeyHex`. A new key in an existing app means every user has to update once by hand.

## Logs and pitfalls

- Log: `~/Library/Logs/ClaudeUsage.log`; fetched data: one file per source in `~/.claude/usage-limits/` (`claude-desktop.json`; up to 2.1 this was `~/.claude/usage-limits.json`, moved on first launch).
- Usage history (own storage; the API keeps none): `~/.claude/usage-history/YYYY-MM.jsonl`, one line per fetch with raw API values only, about 5.5 MB per month. Stays local.
- **Source ≠ deployed:** changes only take effect after `./scripts/deploy.sh`.
- **Universal builds, macOS 11+:** releases ship arm64 + x86_64. An update is one-way: an arm64-only release would leave Intel Macs with an app that doesn't start.
- **Keychain:** the cookie password is read with `/usr/bin/security`, once per launch. Don't switch to `SecItemCopyMatching` without a plan: every user would get a new Keychain prompt.
- **Same identity across versions:** bundle id `com.jos.claude-usage`, executable `ClaudeUsage`, LaunchAgent `com.jos.claude-usage` and the files in `~/.claude/` must stay the same, or updates break existing installs.
