# Mac and Windows — decisions, dependencies, sync rules

The one place for choices that hold for both platforms. The backlogs refer here; they don't repeat it.

- Mac backlog: [MAC-BACKLOG.md](MAC-BACKLOG.md) (items `M…`)
- Windows backlog: [WINDOWS-BACKLOG.md](WINDOWS-BACKLOG.md) (items `W…`)
- What each platform can do: [FEATURES.md](FEATURES.md)

---

## Architecture

**Shared core, thin platform shells.** The logic (limits, resets, notifications, history, Codex, update checks) exists once, in Rust (`core/`). Each platform has its own shell for what genuinely differs: tray or menu bar, notifications, cookie reading, installer, updater install step.

How we get there, without breaking the working Mac app:

1. Windows is built on the Rust core from day one (W2).
2. The Mac app keeps its Swift `UsageCore` until the first Windows release is out.
3. Then the Mac app switches to the Rust core through generated Swift bindings (UniFFI), proven equal by the shared fixtures (M5). After that, `swift/Sources/UsageCore` is removed.

Until step 3, the logic exists twice. The sync rules below cover that period.

Already shared today: `dev/dashboard.html` (the popover), `strings.json` (all text), `fetch.js`, the test fixtures.

## Decisions

| # | Decision | Status |
|---|---|---|
| D1 | **Windows test machine:** Windows 11 ARM in UTM/Parallels on the Mac, with the Claude app signed in. Without it, nothing Windows-specific is verified. | Open: to be arranged |
| D2 | **If the Claude app's cookies can't be read on Windows** (file lock, app-bound encryption): sign in once in the app's own WebView2 window. Fallback only; decided after W1. | Open: after W1 |
| D3 | **One version number for both platforms.** Every release ships the dmg and the Windows installer, each with a `.sig`. A platform-only fix bumps both. A release is only published when both builds succeed: a missing asset makes that platform's updater report an unsigned/missing release. | Decided |
| D4 | **One signing key.** Windows verifies updates with our own Ed25519 code, the existing `updatePublicKeyHex` and `.sig` format. Not the Tauri updater plugin (different key format). | Decided |
| D5 | **Shared fixtures are the contract.** Every pure function is tested against the same fixtures on both sides. A logic change isn't done until both suites pass. | Decided |
| D6 | **Architecture: shared Rust core** (see above). Mac switches after the first Windows release. | Decided |
| D7 | **Stack Windows: Tauri.** Reuses `dashboard.html`; the Mac app stays native Swift/AppKit. | Decided |
| D8 | **Windows releases start unsigned.** Code signing (Azure Trusted Signing) before wider use, because of the antivirus risk. | Decided, revisit at W8 |

## Sync rules

1. **Definition of done.** A feature or behaviour change is done when [FEATURES.md](FEATURES.md) is updated and every platform is ✅, or ⏳ with a backlog item, or `—` with a reason.
2. **Paired items.** Work that touches both platforms has an item in both backlogs, each pointing at the other (`↔ M3` / `↔ W0.2`). `scripts/check-backlogs.py` fails when a pair is one-sided or points at an item that doesn't exist.
3. **Shared files have one home.** `dashboard.html`, `strings.json`, `fetch.js` and the fixtures live in one place both builds read. Never copy them into a platform folder.
4. **Strings.** Every key exists in nl and en. Platform-specific wording gets its own key (`…_mac` / `…_win`), never an `if` in the text.
5. **CI runs both test suites on every push**, so a change on one side that breaks the shared fixtures turns red right away.
6. **Decisions live here.** A backlog may say "see D3"; it never re-decides.

## Dependencies between the backlogs

| Must be done first | Before | Why |
|---|---|---|
| M0 (shared files moved) ↔ W0.2 | W2, W5 | The Rust core and the Windows popover read the shared files |
| M1 (CI for Swift) ↔ W0.3 | W2 | Rule 5 needs both suites in CI |
| M2 (strings check) ↔ W5.5 | W5.5 | Windows adds platform keys; the check must exist first |
| M3 (platform keys in strings) ↔ W5.5 | W5.5 | "Menu bar" vs "taskbar" |
| M4 (release with two platforms) ↔ W8.1 | first Windows release | D3: one release, both assets |
| W2 (Rust core complete) | M5 | The Mac can only switch to a finished core |
| W8 (first Windows release) | M5 | D6: don't touch the Mac's core before Windows ships |
| W1 (probe) | W3–W7 | Go/no-go: can Windows read the session at all |
| D1 (test machine) | W1 and every 🔴 item | |

## Process: the order

D1 → M0/W0 → W1 (go/no-go) ∥ W2 → M1–M4 alongside W3–W7 → W8 (first Windows release) → M5 (Mac on the Rust core).
