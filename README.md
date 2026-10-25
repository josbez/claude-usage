# Usage Meter

macOS menu bar app: how much of your AI plan is left: Claude, Claude Code and ChatGPT.

- 5-hour and weekly limit, per source, with reset times
- Menu bar shows the source closest to a limit
- Click a card for its connection status, or to hide it
- Notifications at 80% / 95% session and 90% weekly
- Signed self-updates; English and Dutch

## Requirements

- macOS 11+, Apple Silicon or Intel
- At least one of these, signed in — nothing to log in to in Usage Meter:
  - [Claude desktop app](https://claude.ai/download)
  - Claude Code (own card when signed in with another account than the Claude app; on an API key: a card without limits)
  - ChatGPT app (with Codex) or Codex

## Install

- [Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg), open it
- Drag **Usage Meter** to **Applications**
- In Terminal: `bash "/Volumes/Usage Meter/install.sh"` (starts at login, gets past Gatekeeper: the app isn't notarized)
- Keychain asks for *Claude Safe Storage* (and *Claude Code-credentials* with Claude Code): choose **Always Allow**

## Update

- Orange dot on the gear → settings → **Update**
- Unsigned updates are refused

## Privacy

- Talks only to claude.ai, api.anthropic.com, status.claude.com and GitHub
- Claude Code: its sign-in token is read from the Keychain, kept in memory only, never stored or refreshed
- ChatGPT limits come from the Codex program on your Mac; its sign-in is never read
- A hidden source isn't checked at all
- Usage history stays on your Mac

## Uninstall

- Settings → **Uninstall…**

## More

- Feedback or an idea: Settings → **Feedback** opens a short form (sends app version, macOS, Mac type and language; nothing else)
- [Development](docs/DEVELOPMENT.md) · [MIT license](LICENSE)
- Not affiliated with Anthropic or OpenAI
