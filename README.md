# ClaudeUsage

macOS-menubalk-app die Claude-plangebruik toont (5-uurs- en weeklimiet via claude.ai) plus lokale Claude Code-tokenstatistieken.

Werkt via het account dat in de Claude desktop-app is ingelogd — leest de sessiecookie live uit de macOS Keychain, slaat niets op.

## Vereisten

- macOS
- [Claude desktop-app](https://claude.ai/download) geïnstalleerd en ingelogd
- Xcode command line tools (`xcode-select --install`) voor de build

## Bouwen

```bash
python3 setup.py py2app
```

Bouwt `dist/ClaudeUsage.app` (universal, x86_64 + arm64).

## Installeren

```bash
cp -R dist/ClaudeUsage.app /Applications/
./install.sh
```

Installeert een LaunchAgent zodat de app start bij inloggen. Klik het ◆-icoon in de menubalk.

### Onbekende ontwikkelaar-waarschuwing

App is niet Apple-signed/notarized (geen Developer-account). Bij eerste start: rechtsklik `ClaudeUsage.app` in Finder → **Open** → **Open** bevestigen. Daarna start hij gewoon via dubbelklik of LaunchAgent.

## Herbouwen na wijzigingen

```bash
./deploy.sh
```

Bouwt opnieuw, herstart de LaunchAgent en installeert in `/Applications`.
