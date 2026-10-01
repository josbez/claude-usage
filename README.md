# ClaudeUsage

macOS-menubalk-app die Claude-plangebruik toont (5-uurs- en weeklimiet via claude.ai), met een melding als je een limiet nadert.

De app volgt de taal van macOS: Nederlands als dat je eerste voorkeurstaal is, anders Engels.

Werkt via het account dat in de Claude desktop-app is ingelogd — leest de sessiecookie live uit de macOS Keychain en stuurt niets naar derden.

> **English:** macOS menu bar app showing your Claude plan usage (5-hour and weekly limits) with alerts when you approach a limit. The app follows your macOS language (Dutch or English). Install: download [ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg), drag the app to Applications, then run `bash /Volumes/ClaudeUsage/install.sh` in Terminal. Later updates install from the app (gear → Update).

## Installeren (DMG)

1. **[Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg)** (altijd de nieuwste versie; oudere versies en wijzigingen staan bij de [releases](https://github.com/josbez/claude-usage/releases)) en open hem.
2. Sleep **ClaudeUsage.app** naar de **Applications**-map in hetzelfde venster.
3. Open Terminal en voer uit:

```bash
bash /Volumes/ClaudeUsage/install.sh
```

Dat installeert een LaunchAgent (start automatisch bij inloggen) en zet de Gatekeeper-quarantaine van de app af. Klik daarna ◆ in de menubalk.

Bij de eerste start vraagt macOS toegang tot de Keychain-sleutel *Claude Safe Storage* — kies **Always Allow**. Daarna vraagt macOS of ClaudeUsage meldingen mag sturen: sta dat toe voor een waarschuwing bij 80% en 95% van de 5-uurslimiet en 90% van de weeklimiet. Met het bel-icoon in de popover zet je meldingen aan of uit. Eerste cijfers verschijnen na ~10–20 seconden.

### Bijwerken

Vanaf versie 1.2 checkt de app dagelijks of er een nieuwe versie is. Is die er, dan verschijnt een oranje pijl in de popover (en een melding). Klik erop en kies **Bijwerken**: de app downloadt de update, controleert de digitale handtekening, vervangt zichzelf en start opnieuw. Updates zonder geldige handtekening worden geweigerd. Heb je een oudere versie, werk dan één keer handmatig bij via de DMG hierboven.

Het versienummer staat naast de titel in de popover.

### Waarom die Terminal-stap

De app is niet Apple-signed of notarized (vereist een betaald Developer-account). Zonder `install.sh` blokkeert Gatekeeper de eerste start; sinds macOS 15 Sequoia werkt de oude rechtsklik → *Open*-truc daar niet meer voor. Handmatig alternatief: dubbelklik de app, ga dan naar **Systeeminstellingen → Privacy en beveiliging** en klik onderaan bij *Beveiliging* op **Toch openen**.

### Verwijderen

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

## Zelf bouwen

Vereisten: macOS, Xcode command line tools (`xcode-select --install`), en in de **systeem-Python** (`/usr/bin/python3`, niet Homebrew):

```bash
/usr/bin/python3 -m pip install --user py2app pycryptodome pyobjc pyobjc-framework-UserNotifications pytest
```

Scripts:

```bash
./build.sh             # tests + import-check + py2app + buildnummer + ad-hoc codesign
./deploy.sh            # build.sh, uitrollen naar /Applications, LaunchAgent-herstart, verifieert verse fetch
./make-dmg.sh          # build.sh + ClaudeUsage.dmg (+ .sig als de signing key aanwezig is)
/usr/bin/python3 -m pytest   # alleen de tests
```

`deploy.sh` eindigt met `✓ fetch geverifieerd` of faalt met de laatste logregels. `CFBundleVersion` is de buildtijd (`YYYYMMDD.HHMMSS`), zo zie je welke build draait.

Structuur: `core.py` bevat alle logica zonder PyObjC (getest in `tests/`); `app.py` is alleen de menubalk/WebKit-glue; `fetch_limits.py` is een los debugscript voor de fetch-pipeline.

## Release maken

1. Versie ophogen in `setup.py` (`CFBundleShortVersionString` en `CFBundleVersion`), committen en pushen.
2. `./make-dmg.sh` — maakt `ClaudeUsage.dmg` én `ClaudeUsage.dmg.sig`.
3. GitHub-release met tag `vX.Y` en **beide** bestanden als bijlage. Zonder `.sig` weigert de in-app updater de release.

De signing key staat in `~/.config/claude-usage/release-signing-key.pem` en komt nooit in git. Maak er een back-up van: zonder die sleutel kun je geen updates meer uitbrengen die bestaande installaties accepteren. Eenmalig aanmaken op een nieuwe machine gaat met `sign-release.py --init`, maar een nieuwe sleutel vraagt ook een nieuwe `UPDATE_PUBLIC_KEY_HEX` in `core.py` en dus één handmatige update bij alle gebruikers.

## Logs en valkuilen

- Logboek: `~/Library/Logs/ClaudeUsage.log`; opgehaalde data: `~/.claude/usage-limits.json`.
- Gebruiksgeschiedenis (eigen opslag, de API bewaart geen historie): `~/.claude/usage-history/JJJJ-MM.jsonl`, één regel per fetch met alleen ruwe API-waarden — ~5,5 MB per maand. Blijft lokaal.
- **PyObjC-selectors:** methodes op `NSObject`-subclasses worden Objective-C selectors (underscore → dubbele punt). Callbacks: camelCase met één trailing underscore per argument (`fetchWatchdogFired_`).
- **Geen Python-subprocess vanuit de bundle:** de gebundelde interpreter-helper is kapot gelinkt; alles in-process.
- **Source ≠ deployed:** wijzigingen zijn pas actief na `./deploy.sh`.

Gebouwd met py2app tegen de systeem-Python (3.9 op macOS); de bundle is universal (x86_64 + arm64) en draait dus op Intel en Apple Silicon.
