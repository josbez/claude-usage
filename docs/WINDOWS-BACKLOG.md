# Usage Meter for Windows — backlog

Goal: a released Windows version of Usage Meter next to the Mac app, same features, same release.
Decisions (D1–D8), sync rules and dependencies: [PLATFORMS.md](PLATFORMS.md). Counterpart: [MAC-BACKLOG.md](MAC-BACKLOG.md). What each platform can do: [FEATURES.md](FEATURES.md).

Layout: the shared Rust core in `core/`, the Tauri shell in `windows/`, shared files in `shared/`.

`↔` marks a paired item in the Mac backlog (sync rule 2).

Legend: 🟢 can be built and verified without Windows · 🟡 builds in CI, needs a Windows machine to verify · 🔴 blocked until a Windows machine exists.

---

## W0 — Foundation 🟢

- **W0.1** Rust workspace: `core/` (lib crate, platform-free) and `windows/` (Tauri app). Builds on Linux; `cargo test` runs.
- **W0.2** ↔ M0 The Windows build reads the shared files from `shared/`; nothing copied into `windows/`.
- **W0.3** ↔ M1 GitHub Actions: `cargo test` for `core/` on every push; `windows-latest` builds the installer and uploads it as an artifact. Same workflow as the Swift tests.
- **W0.4** DEVELOPMENT.md: a Windows section (build, test, layout, where things live).

## W1 — Probe: can we read the Claude session at all? 🟡 → 🔴 (do this first)

The biggest risk is here, and it decides D2. Don't build W3–W6 before this answer is in.

- **W1.1** `UsageMeter.exe --probe` (CLI, no UI; prints no secrets, only facts):
  - Claude app install: classic (`%APPDATA%\Claude`) or MSIX (`%LOCALAPPDATA%\Packages\…\LocalCache\Roaming\Claude`)
  - Cookie DB found (`Cookies` / `Network\Cookies`), and **can it be opened while Claude is running?** Chromium on Windows opens this file exclusively; that is the most likely blocker.
  - `Local State` → `os_crypt.encrypted_key` present, DPAPI unprotect succeeds
  - Prefix of the `sessionKey` value: `v10` (AES-256-GCM, workable) or `v20` (app-bound encryption, not workable without elevation)
  - Native request to claude.ai with that cookie: HTTP status, Cloudflare challenge yes/no (like `--probe-native-fetch`)
  - Codex: binary found where, `~/.codex/auth.json` present
- **W1.2** Run the probe with Claude closed and running, on the classic and (if it exists) the MSIX install. Record the result here.
- **W1.3** Decide D2 based on W1.2.

## W2 — Port the pure logic to the shared Rust core (`core/`) 🟢

One task per Swift file in `UsageCore`. Each: same behaviour, same fixtures, the tests ported to `cargo test`.

- **W2.1** JSON helpers, dates, `pyIsoformatUTC`, formatting (`JSON`, `Dates`, `Formatting`)
- **W2.2** Strings: load `strings.json`, nl/en, placeholder fill (`Strings`)
- **W2.3** Limits, resets, plan label, block logging, cedar_ember (`Limits`, `Resets`, `Fetch`)
- **W2.4** Native fetch: org choice and result shape, mirrors `fetch.js` (`NativeFetch`)
- **W2.5** Usage sources and snapshots, source cards (`UsageSources`, `SourceCards`)
- **W2.6** Notifications: thresholds, window keys, per-source alerts, state (`Notifications`, `SourceAlerts`)
- **W2.7** History: record, monthly path, append (`History`)
- **W2.8** Service status (`ServiceStatus`)
- **W2.9** Settings and paths. Windows paths: `%USERPROFILE%\.claude\…` for data (same as Mac, Claude Code uses it too), log in `%LOCALAPPDATA%\UsageMeter\Logs`. Dev build gets its own files, like on Mac (`Settings`)
- **W2.10** Dashboard data assembly (`DashboardData`)
- **W2.11** Codex: snapshot parsing, session-file fallback, app-server JSON-RPC lines. Windows binary candidates (`%APPDATA%\npm\codex.cmd`, ChatGPT app bundle if it ships one, `~\.local\bin`) (`Codex`, `CodexAppServer`)
- **W2.12** Update: version compare, release parsing (pick the asset for the platform), Ed25519 verify with `updatePublicKeyHex` (`Update`, see D4)
- **W2.13** Seasonal faces (`SeasonalFacesTests`)

**Done when:** every Swift test has a Rust counterpart and passes against the same fixtures in `shared/fixtures/`. Keep `core/` free of Windows code: the Mac will use it too (M5).

## W3 — Reading the session on Windows 🟡 (depends on W1)

- **W3.1** Find the cookie DB (classic + MSIX paths)
- **W3.2** Master key from `Local State`, DPAPI unprotect (`CryptUnprotectData`); cache it per launch like `CookieKeyCache`
- **W3.3** Decrypt `v10` (AES-256-GCM: 12-byte nonce, 16-byte tag; strip the sha256(host) prefix like on Mac). Unit test with a self-made encrypted fixture 🟢
- **W3.4** Open the DB while Claude runs (copy, read-only/immutable open, or whatever W1 showed works)
- **W3.5** Clear error states for the popover: Claude not installed, not signed in, file locked, `v20`, each with an explanation like the Mac's "missing login" text
- **W3.6** Only if D2 = WebView2 sign-in: login window, keep the session, sign out in settings

## W4 — Fetching 🟡

- **W4.1** Native fetch (reqwest) with the `sessionKey` cookie: bootstrap → orgs → usage, mirrors `NativeFetching.swift`
- **W4.2** Webview fallback when Cloudflare blocks (hidden WebView2 + `fetch.js`), mirrors `Fetching.swift`
- **W4.3** Refresh timer, fetch on popover open, the "keeps its width while fetching" equivalent (spinner state in the tray tooltip)
- **W4.4** Service status check every 5 min
- **W4.5** Codex: start `codex app-server` without a console window flashing (`CREATE_NO_WINDOW`), always stop it, fallback to session files
- **W4.6** Write `usage-limits/*.json` and history, same format as on Mac

## W5 — Tray and popover 🔴

- **W5.1** Tray icon: ring drawn in code at 16/20/24/32 px (DPI scaling), light/dark taskbar, stress colour from 75%. Emoji option: render the face as an icon
- **W5.2** Tooltip instead of menu bar text: "Usage Meter — session 42%, week 18%" (the Windows tray has no room for text)
- **W5.3** Left click: popover window (360×296, frameless, rounded, positioned next to the tray, at the taskbar's edge wherever it is, closes on focus loss). Right click: menu (Refresh, Settings, Quit)
- **W5.4** Bridge: `dashboard.html` calls `webkit.messageHandlers…` (line ~1009). Add a small shim that sends it to Tauri `invoke` when on Windows. Handle the same messages: refresh, close, quit, uninstall, setNotifications, setMenubarStyle, setMenubarIcon, setSeasonalFaces, setAppearance, setRefresh, startUpdate, resize, setSourceHidden, openResetsPage, openStatusPage, fetchResult
- **W5.5** ↔ M2, M3 Settings the Mac has that don't apply (menu bar style) are hidden on Windows; texts that say "menu bar" use the `_win` keys ("taskbar"), nl + en
- **W5.6** Light/dark follows Windows, plus the existing manual choice
- **W5.7** First launch: Windows 11 hides new tray icons in the overflow. Show once how to pin it

## W6 — Notifications 🔴

- **W6.1** Toast notifications (AppUserModelID set by the installer, otherwise toasts don't show)
- **W6.2** Thumbnail image (the session donut from `renderStatusImage`) in the toast
- **W6.3** Dev build: "β " before titles, like on Mac
- **W6.4** `--test-notification`

## W7 — Install, start at login, update, uninstall 🔴

- **W7.1** Installer: per-user NSIS `.exe` (no admin rights needed); start menu shortcut; asset name `UsageMeter-Setup.exe` + `.sig`
- **W7.2** Start at login: `HKCU\…\Run`, on by default, toggle in settings
- **W7.3** Updater: check `releases/latest` (daily, manual every 5 min max), download the Windows asset, verify `.sig` (D4), run the installer silently, restart. On failure: keep the current version, show the error like on Mac
- **W7.4** Uninstall from settings and from Windows "Apps": remove own files, the Run key and the app; never touch `~\.claude` beyond our own files (same rule as Mac)
- **W7.5** Single instance: a second launch opens the popover instead of starting a second app

## W8 — Release 🔴

- **W8.1** ↔ M4 Release workflow: tag `vX.Y` → CI builds the Windows installer → sign with `--sign-release` (local, key never in CI unless you decide to put it in a secret) → attach next to the dmg
- **W8.2** FEATURES.md: every Windows row ✅, ⏳ with an item, or — with a reason (sync rule 1)
- **W8.3** README: Windows requirements, install steps (including "SmartScreen → More info → Run anyway"), privacy (DPAPI, nothing leaves the PC except to claude.ai/status/GitHub)
- **W8.4** Test round on a clean Windows 11 (x64 and ARM): install, first fetch, notification, update from the previous version, uninstall
- **W8.5** Antivirus check: upload the installer to VirusTotal before every release (see risk R2)

---

## Risks

- **R1 — Locked cookie file / app-bound encryption.** The core idea (read the Claude app's session) may not work on Windows. W1 tells us, before we invest in the rest.
- **R2 — Antivirus false positives.** Opening another app's cookie DB and decrypting it with DPAPI is exactly what infostealers do. An unsigned exe that does this has a real chance of being flagged or quarantined by Defender. Mitigation: VirusTotal every release, submit false positives to Microsoft, and signing (Azure Trusted Signing) as soon as this hits users.
- **R3 — Two codebases drift** until the Mac uses the Rust core (M5). Mitigated by the sync rules in PLATFORMS.md.
- **R4 — No Windows machine (D1).** Without one, nothing marked 🟡 or 🔴 is verified.

## Order

D1 → W0 → **W1 (go/no-go)** ∥ W2 → W3 → W4 → W5 → W6 → W7 → W8. Cross-backlog dependencies: see PLATFORMS.md.
