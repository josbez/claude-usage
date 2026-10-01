# ClaudeUsage

🇬🇧 [English](README.md) · 🇳🇱 Nederlands

macOS-menubalk-app die Claude-plangebruik toont (5-uurs- en weeklimiet via claude.ai), met een melding als je een limiet nadert.

De app volgt de taal van macOS: Nederlands als dat je eerste voorkeurstaal is, anders Engels.

Werkt via het account dat in de Claude desktop-app is ingelogd — leest de sessiecookie live uit de macOS Keychain en stuurt niets naar derden.

## Installeren (DMG)

Vereist macOS 11 of nieuwer (Apple Silicon en Intel).

1. **[Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg)** (altijd de nieuwste versie; oudere versies en wijzigingen staan bij de [releases](https://github.com/josbez/claude-usage/releases)) en open hem.
2. Sleep **ClaudeUsage.app** naar de **Applications**-map in hetzelfde venster.
3. Open Terminal en voer uit:

```bash
bash /Volumes/ClaudeUsage/install.sh
```

Dat installeert een LaunchAgent (start automatisch bij inloggen) en zet de Gatekeeper-quarantaine van de app af. Klik daarna op het gezichtje (🚀 en de percentages) in de menubalk.

Bij de eerste start vraagt macOS toegang tot de Keychain-sleutel *Claude Safe Storage* — kies **Always Allow**. Daarna vraagt macOS of ClaudeUsage meldingen mag sturen: sta dat toe voor een waarschuwing bij 80% en 95% van de 5-uurslimiet en 90% van de weeklimiet. Meldingen zet je aan of uit in de instellingen (het tandwiel in de popover). Eerste cijfers verschijnen na ~10–20 seconden.

### Bijwerken

Vanaf versie 1.2 checkt de app dagelijks of er een nieuwe versie is. Is die er, dan krijgt het tandwiel in de popover een oranje stip (en komt er een melding). Open de instellingen, klik **Bijwerken** en bevestig: de app downloadt de update, controleert de digitale handtekening, vervangt zichzelf en start opnieuw. Updates zonder geldige handtekening worden geweigerd. Heb je een oudere versie, werk dan één keer handmatig bij via de DMG hierboven.

Het versienummer staat in de instellingen.

### Waarom die Terminal-stap

De app is niet Apple-signed of notarized (vereist een betaald Developer-account). Zonder `install.sh` blokkeert Gatekeeper de eerste start; sinds macOS 15 Sequoia werkt de oude rechtsklik → *Open*-truc daar niet meer voor. Handmatig alternatief: dubbelklik de app, ga dan naar **Systeeminstellingen → Privacy en beveiliging** en klik onderaan bij *Beveiliging* op **Toch openen**.

### Verwijderen

Vanaf versie 2.0: instellingen (tandwiel) → **Verwijderen…** onderaan. De app gaat naar de Prullenbak, start niet meer bij inloggen en zijn eigen bestanden worden opgeruimd; je kiest zelf of de gebruiksgeschiedenis blijft staan. Oudere versies, in Terminal:

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

## Zelf bouwen

De repo bevat twee implementaties van dezelfde app:

- **Swift (`swift/`)** — de native herschrijving die als **2.0** uitkomt. Nog niet gereleased; de download hierboven is nog 1.2.x.
- **Python (`app.py`, `core.py`)** — de huidige release (1.2.x), gebouwd met py2app. Feature-freeze tot 2.0 uit is; blijft in de repo als referentie waartegen de Swift-versie getest wordt.

### Swift (2.0)

Vereisten: macOS 11 of nieuwer en **Xcode** (niet alleen de command line tools: de tests hebben XCTest nodig). Tijdens het bouwen draaien ook de Python-tests, dus de systeem-Python heeft `pycryptodome` en `pytest` nodig (zie hieronder).

```bash
./scripts/build-swift.sh            # pytest + Swift-tests + universal build + ad-hoc codesign
                                    # → dist-swift/ClaudeUsage Dev.app (bundle-id …claude-usage.dev)
./scripts/build-swift.sh --release  # idem, als de echte bundle → dist-swift/ClaudeUsage.app
./scripts/deploy.sh --swift         # release-build, uitrollen naar /Applications, LaunchAgent-herstart, verifieert verse fetch
./scripts/make-dmg.sh --swift       # release-build + ClaudeUsage.dmg (+ .sig als de signing key aanwezig is)
(cd swift && swift test)            # alleen de Swift-tests
```

De **dev-build** draait naast de geïnstalleerde app, om naast elkaar te testen: eigen bundle-id, een `β` vóór de menubalktitel en meldingstitels, en eigen bestanden (`~/.claude/*.dev.json`, `~/.claude/usage-history-dev/`, `~/Library/Logs/ClaudeUsage-Dev.log`). De release-build gebruikt dezelfde bestanden als de Python-app, dus een update behoudt instellingen, meldingsstatus en geschiedenis.

Structuur: `swift/Sources/UsageCore` is de pure logica (port van `core.py`, alleen Foundation); `swift/Sources/ClaudeUsage` is de AppKit-glue (menubalk, popover, ophalen, meldingen, updater). De popover is dezelfde `dev/dashboard.html`.

**Pariteit met `core.py`:** `scripts/swift-fixtures.py` draait de Python-functies op een reeks invoer bij een vaste tijd en tijdzone en schrijft de uitkomsten naar `swift/Tests/UsageCoreTests/Fixtures/core.json`; de Swift-tests moeten elke uitkomst exact reproduceren. Het script exporteert ook `STRINGS` naar `swift/Resources/strings.json` en het ophaalscript naar `swift/Resources/fetch.js` — pas die aan in `core.py` en draai het script opnieuw (pytest faalt als ze niet gelijk lopen). `build-swift.sh` doet dat zelf.

Testhaken: `ClaudeUsage --render-status-image <pct> <out.png>`, `ClaudeUsage --verify-release <dmg> <sig>`, en voor de dev-build `--test-notification` en `--update-feed <url>` (bijv. een lokale `file://…/release.json`, om de updater end-to-end te testen).

### Python (1.2.x)

Vereisten: macOS, Xcode command line tools (`xcode-select --install`), en in de **systeem-Python** (`/usr/bin/python3`, niet Homebrew):

```bash
/usr/bin/python3 -m pip install --user py2app pycryptodome pyobjc pyobjc-framework-UserNotifications pytest
```

Scripts:

```bash
./scripts/build.sh             # tests + import-check + py2app + buildnummer + ad-hoc codesign
./scripts/deploy.sh            # build.sh, uitrollen naar /Applications, LaunchAgent-herstart, verifieert verse fetch
./scripts/make-dmg.sh          # build.sh + ClaudeUsage.dmg (+ .sig als de signing key aanwezig is)
/usr/bin/python3 -m pytest     # alleen de tests
```

Structuur: `core.py` bevat alle logica zonder PyObjC (getest in `tests/`); `app.py` is alleen de menubalk/WebKit-glue; `fetch_limits.py` is een los debugscript voor de fetch-pipeline; `dev/dashboard.html` is de popover-UI (`setup.py` zet hem in de bundle-root).

`scripts/deploy.sh` eindigt met `✓ fetch geverifieerd` of faalt met de laatste logregels. `CFBundleVersion` is de buildtijd (`YYYYMMDD.HHMMSS`), zo zie je welke build draait.

## Release maken

1. Versie ophogen: `VERSION` in `scripts/build-swift.sh` (Swift) of `CFBundleShortVersionString` en `CFBundleVersion` in `setup.py` (Python). Committen en pushen.
2. `./scripts/make-dmg.sh --swift` (of zonder `--swift` voor Python) — maakt `ClaudeUsage.dmg` én `ClaudeUsage.dmg.sig`.
3. GitHub-release met tag `vX.Y` en **beide** bestanden als bijlage. Zonder `.sig` weigert de in-app updater de release.

Beide versies controleren updates met dezelfde sleutel, dus de updater van de Python-app installeert de Swift-versie als een gewone update (zelfde bundle-id `com.jos.claude-usage`, zelfde executable-naam, dus de bestaande LaunchAgent start hem).

De signing key staat in `~/.config/claude-usage/release-signing-key.pem` en komt nooit in git. Maak er een back-up van: zonder die sleutel kun je geen updates meer uitbrengen die bestaande installaties accepteren. Eenmalig aanmaken op een nieuwe machine gaat met `scripts/sign-release.py --init`, maar een nieuwe sleutel vraagt ook een nieuwe publieke sleutel in de app (en dus één handmatige update bij alle gebruikers).

## Logs en valkuilen

- Logboek: `~/Library/Logs/ClaudeUsage.log`; opgehaalde data: `~/.claude/usage-limits.json`.
- Gebruiksgeschiedenis (eigen opslag, de API bewaart geen historie): `~/.claude/usage-history/JJJJ-MM.jsonl`, één regel per fetch met alleen ruwe API-waarden — ~5,5 MB per maand. Blijft lokaal.
- **Source ≠ deployed:** wijzigingen zijn pas actief na `./scripts/deploy.sh` (`--swift` voor de Swift-versie).
- **Universal builds:** beide versies leveren arm64 + x86_64. Een update is eenrichtingsverkeer: een release die alleen arm64 is, laat Intel-Macs achter met een app die niet start.
- **Alleen Python — PyObjC-selectors:** methodes op `NSObject`-subclasses worden Objective-C selectors (underscore → dubbele punt). Callbacks: camelCase met één trailing underscore per argument (`fetchWatchdogFired_`).
- **Alleen Python — geen Python-subprocess vanuit de bundle:** de gebundelde interpreter-helper is kapot gelinkt; alles in-process.

De Swift-versie vereist macOS 11+. De Python-versie is gebouwd met py2app tegen de systeem-Python (3.9 op macOS). Beide zijn universal (x86_64 + arm64) en draaien op Intel en Apple Silicon.

## Licentie

Zie [LICENSE](LICENSE).
