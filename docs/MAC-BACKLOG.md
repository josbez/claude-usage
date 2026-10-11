# Usage Meter for Mac — backlog (two-platform work)

Mac work that comes from supporting Windows next to it. Decisions, sync rules and dependencies: [PLATFORMS.md](PLATFORMS.md). Counterpart: [WINDOWS-BACKLOG.md](WINDOWS-BACKLOG.md).

Mac-only feature work keeps its own numbering (taak NN); when it changes behaviour, it also updates [FEATURES.md](FEATURES.md) (sync rule 1).

`↔` marks a paired item in the Windows backlog (sync rule 2).

---

## M0 — Shared files in one place ↔ W0.2

- **M0.1** Move `dev/dashboard.html`, `swift/Resources/strings.json`, `swift/Resources/fetch.js` and `swift/Tests/UsageCoreTests/Fixtures/` to `shared/` (`shared/ui/`, `shared/strings.json`, `shared/fetch.js`, `shared/fixtures/`).
- **M0.2** Point `build-swift.sh`, `Package.swift` (test resources) and the tests at `shared/`. Build and tests green; the built `.app` contents unchanged (same files in `Contents/Resources`).
- **M0.3** DEVELOPMENT.md: new layout, and the rule that shared files are never copied into a platform folder.

## M1 — CI for the Swift tests ↔ W0.3

- **M1.1** GitHub Actions on `macos-latest`: `swift test` on every push (needs Xcode, which the runner has).
- **M1.2** One workflow file for both platforms, so a red check on either side is visible on the same commit.
- **M1.3** `scripts/check-backlogs.py` runs in that workflow (sync rule 2).

## M2 — Strings check ↔ W5.5

- **M2.1** Test: every key in `strings.json` exists in nl and en, and is used by at least one platform (Swift sources, `dashboard.html` or the Windows shell). Unused keys fail.
- **M2.2** Test: platform-suffixed keys (`…_mac`, `…_win`) come in pairs, or have a reason in a short allowlist.

## M3 — Platform wording in strings ↔ W5.5

- **M3.1** Keys that say "menu bar" (`set_group_display`, `set_menubar`, and any others) get a `_mac` variant; Windows adds `_win` ("taskbar"). The popover picks the variant for the platform it runs on.
- **M3.2** No visible change on Mac: same texts as before, checked against the current nl and en.

## M4 — Releases with two platforms ↔ W8.1

- **M4.1** Test for `parseRelease`: a release that also carries the Windows assets still yields the dmg and its `.sig` (it picks by name today; this locks that in).
- **M4.2** DEVELOPMENT.md "Making a release": one version for both (D3), both builds must succeed before publishing, both `.sig` files attached.
- **M4.3** Version number in one place both builds read (now `VERSION` in `build-swift.sh`).

## M5 — Mac on the shared Rust core (after the first Windows release)

Depends on W2 (core complete) and W8 (Windows released). See D6.

- **M5.1** UniFFI bindings for `core/`; build a universal (arm64 + x86_64) static library in `build-swift.sh`.
- **M5.2** Switch `ClaudeUsage` from `UsageCore` to the bindings, one area at a time, each behind the existing parity tests: formatting/dates → limits/resets → notifications/alerts → history → Codex → update.
- **M5.3** Keep the Swift `UsageCore` tests running against the bindings until everything has switched; then remove `swift/Sources/UsageCore`.
- **M5.4** Release check: same `.app` identity (bundle id, executable, LaunchAgent, files in `~/.claude/`), size and memory not noticeably worse, macOS 11 still supported.
- **M5.5** Update FEATURES.md and DEVELOPMENT.md: one core, two shells.

---

## Order

M0 → M1 → M2/M3 (before W5.5) → M4 (before W8.1) → M5 (after W8).
