# Usage Meter

macOS menu bar app: how much of your Claude (and ChatGPT) plan is left.

- 5-hour and weekly limit, per source, with reset times
- Menu bar shows the source closest to a limit
- Notifications at 80% / 95% session and 90% weekly
- Signed self-updates; English and Dutch

## Requirements

- macOS 11+, Apple Silicon or Intel
- [Claude desktop app](https://claude.ai/download), signed in — nothing to log in to in Usage Meter
- ChatGPT card: ChatGPT app (with Codex) or Codex, signed in

## Install

- [Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg), open it
- Drag **Usage Meter** to **Applications**
- In Terminal: `bash "/Volumes/Usage Meter/install.sh"` (starts at login, gets past Gatekeeper: the app isn't notarized)
- Keychain asks for *Claude Safe Storage*: choose **Always Allow**

## Update

- Orange dot on the gear → settings → **Update**
- Unsigned updates are refused

## Privacy

- Talks only to claude.ai, status.claude.com and GitHub
- ChatGPT limits come from the Codex program on your Mac; its sign-in is never read
- Usage history stays on your Mac

## Uninstall

- Settings → **Uninstall…**

## More

- [Development](docs/DEVELOPMENT.md) · [MIT license](LICENSE)
- Not affiliated with Anthropic or OpenAI
