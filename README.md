# ClaudeUsage

🇬🇧 English · 🇳🇱 [Nederlands](README.nl.md)

A small macOS menu bar app that shows how much of your Claude plan you have left: the 5-hour session limit and the weekly limit, with a notification when you get close.

- A ring (or emoji) in the menu bar fills up with your session usage.
- Click it for both limits and when they reset.
- Notifications at 80% and 95% of the session limit and 90% of the weekly limit.
- Updates itself (signed updates only). English and Dutch, follows your macOS language.

Requires macOS 11 or later (Apple Silicon or Intel) and the [Claude desktop app](https://claude.ai/download), signed in. ClaudeUsage uses that account; there is nothing to log in to.

## Install

1. **[Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg)** and open it.
2. Drag **ClaudeUsage.app** to **Applications**.
3. Open Terminal and run:

   ```bash
   bash /Volumes/ClaudeUsage/install.sh
   ```

   This starts the app at login and lets it past Gatekeeper (see below).

On launch macOS asks for access to the Keychain item *Claude Safe Storage*: that is how the app reads the Claude desktop app's sign-in. It asks once per launch; choose **Always Allow** to never see it again. Then allow notifications if you want the alerts. The first numbers appear within a few seconds.

**Why the Terminal step?** The app is not notarized by Apple (that needs a paid developer account), so Gatekeeper blocks it otherwise. Alternative: open the app, then **System Settings → Privacy & Security → Open Anyway**.

## Update

The app checks for a new version daily, and when you click refresh. When one is available, the gear in the popover gets an orange dot: open settings and click **Update**. Updates without a valid signature are refused. Release notes are on the [releases page](https://github.com/josbez/claude-usage/releases).

## Privacy

The app talks only to claude.ai (your usage), status.claude.com (service status) and GitHub (updates). Nothing is sent anywhere else. Your usage history stays on your Mac (`~/.claude/usage-history/`).

## Uninstall

Settings (gear) → **Uninstall…**. You choose whether to keep the usage history. Versions before 2.0, in Terminal:

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

## More

- [Development, building and releases](docs/DEVELOPMENT.md)
- Not affiliated with Anthropic. Claude is a trademark of Anthropic.
- License: [MIT](LICENSE)
