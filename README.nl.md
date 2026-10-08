# Usage Meter

🇬🇧 [English](README.md) · 🇳🇱 Nederlands

Een kleine menubalk-app voor macOS die laat zien hoeveel ruimte je nog hebt in je abonnement: de 5-uurslimiet en de weeklimiet van Claude, en van ChatGPT als je Codex gebruikt, met een melding als je in de buurt komt. Heette eerder ClaudeUsage.

- Een ring (of emoji) in de menubalk vult mee met je sessiegebruik. Met meer dan één bron toont hij de bron die het dichtst bij een limiet zit.
- Klik erop voor een kaart per bron: beide limieten en wanneer ze resetten.
- Meldingen bij 80% en 95% van de sessielimiet en 90% van de weeklimiet, per bron.
- Werkt zichzelf bij (alleen ondertekende updates). Nederlands en Engels, volgt de taal van macOS.

Vereist macOS 11 of nieuwer (Apple Silicon of Intel) en de [Claude desktop-app](https://claude.ai/download), ingelogd. Usage Meter gebruikt dat account; er is niets om in te loggen. ChatGPT verschijnt vanzelf zolang de ChatGPT-app (met Codex) of Codex op je Mac staat en je bent ingelogd; in de instellingen kun je elke bron verbergen.

## Installeren

1. **[Download ClaudeUsage.dmg](https://github.com/josbez/claude-usage/releases/latest/download/ClaudeUsage.dmg)** en open hem.
2. Sleep **Usage Meter** naar **Applications**.
3. Open Terminal en voer uit:

   ```bash
   bash "/Volumes/Usage Meter/install.sh"
   ```

   Daarmee start de app bij inloggen en komt hij langs Gatekeeper (zie hieronder).

Bij het starten vraagt macOS toegang tot de Keychain-sleutel *Claude Safe Storage*: zo leest de app de inlog van de Claude desktop-app. Dat gebeurt één keer per start; kies **Always Allow** om de vraag nooit meer te zien. Sta daarna meldingen toe als je de waarschuwingen wilt. De eerste cijfers verschijnen binnen een paar seconden.

**Waarom de Terminal-stap?** De app is niet door Apple genotariseerd (daarvoor is een betaald developer-account nodig), dus anders blokkeert Gatekeeper hem. Alternatief: open de app, dan **Systeeminstellingen → Privacy en beveiliging → Toch openen**.

## Bijwerken

De app zoekt dagelijks naar een nieuwe versie, en als je op vernieuwen klikt. Is er een, dan krijgt het tandwiel in de popover een oranje stip: open de instellingen en klik **Bijwerken**. Updates zonder geldige handtekening worden geweigerd. Wat er nieuw is staat bij de [releases](https://github.com/josbez/claude-usage/releases).

## Privacy

De app praat alleen met claude.ai (je gebruik), status.claude.com (storingen) en GitHub (updates). Voor ChatGPT vraagt hij je limieten op bij het Codex-programma op je Mac (Codex praat zelf met OpenAI); je Codex-inlog leest hij nooit. Er gaat niets naar anderen. Je gebruiksgeschiedenis blijft op je Mac (`~/.claude/usage-history/`).

## Verwijderen

Instellingen (tandwiel) → **Verwijderen…**. Je kiest zelf of de gebruiksgeschiedenis blijft staan. Versies van vóór 2.0, in Terminal:

```bash
launchctl unload ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm ~/Library/LaunchAgents/com.jos.claude-usage.plist
rm -rf /Applications/ClaudeUsage.app
```

Het appbestand heet nog `ClaudeUsage.app`, zodat updates blijven werken; Finder toont het als Usage Meter.

## Meer

- [Ontwikkelen, bouwen en releases](docs/DEVELOPMENT.md) (Engels)
- Niet verbonden aan Anthropic of OpenAI. Claude is een merk van Anthropic; ChatGPT en Codex zijn merken van OpenAI.
- Licentie: [MIT](LICENSE)
