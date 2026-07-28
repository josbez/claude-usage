# ClaudeUsage

macOS-menubalk-app die Claude-plangebruik toont (5-uurs- en weeklimiet via claude.ai) plus lokale Claude Code-tokenstatistieken.

Werkt via het account dat in de Claude desktop-app is ingelogd — leest de sessiecookie live uit de macOS Keychain en stuurt niets naar derden.

## Installeren (DMG)

1. Download `ClaudeUsage.dmg` uit de [releases](https://github.com/josbez/claude-usage/releases) en open hem.
2. Sleep **ClaudeUsage.app** naar de **Applications**-map in hetzelfde venster.
3. Open Terminal en voer uit:

```bash
bash /Volumes/ClaudeUsage/install.sh
```

Dat installeert een LaunchAgent (start automatisch bij inloggen) en zet de Gatekeeper-quarantaine van de app af. Klik daarna ◆ in de menubalk.

Bij de eerste start vraagt macOS toegang tot de Keychain-sleutel *Claude Safe Storage* — kies **Always Allow**. Eerste cijfers verschijnen na ~10–20 seconden.

### Waarom die Terminal-stap

De app is niet Apple-signed of notarized (vereist een betaald Developer-account). Zonder `install.sh` blokkeert Gatekeeper de eerste start; sinds macOS 15 Sequoia werkt de oude rechtsklik → *Open*-truc daar niet meer voor. Handmatig alternatief: dubbelklik de app, ga dan naar **Systeeminstellingen → Privacy en beveiliging** en klik onderaan bij *Beveiliging* op **Toch openen**.

### Verwijderen

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

## Zelf bouwen

Vereisten: macOS, Xcode command line tools (`xcode-select --install`), en:

```bash
pip3 install py2app pycryptodome
```

Bouwen en verpakken:

```bash
./make-dmg.sh          # bouwt dist/ClaudeUsage.app + ClaudeUsage.dmg
```

Alleen de app bouwen en direct lokaal uitrollen (rebuild → /Applications → LaunchAgent-herstart):

```bash
./deploy.sh
```

Gebouwd met py2app tegen de systeem-Python (3.9 op macOS); de bundle is universal (x86_64 + arm64) en draait dus op Intel en Apple Silicon.
