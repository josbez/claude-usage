# Usage Meter — design system

How the popover looks and why. The popover is one page, [`dev/dashboard.html`](../dev/dashboard.html), shown in a WKWebView at a fixed width of 360 px.

**The design system leads.** It is published as a Claude Design artifact (private): <https://claude.ai/artifact/YXYFx4aQeGdwM7nHP78vCa>. Its tokens are implemented in the `:root` block at the top of `dashboard.html`; this document explains them. The artifact, `:root` and this document must always say the same thing (see [Design system first](#design-system-first)).
## Principles

- **One job.** Show at a glance how much room is left. Anything that does not serve that stays out.
- **Native macOS.** System font, system-like greys, Apple status colours. The only brand element is the app icon.
- **Data first.** Show only what the source demonstrably returns. Unknown means show nothing; never invent values, marks or copy. 0% only when the source reports 0 (a window that just reset); no numbers (never fetched, not logged in) is "—", never 0, in the menu bar too.
- **Colour means load.** The only expressive colour is the session stress ramp. Blue is the week. Everything else is neutral.
- **Quiet.** Few borders, no shadows on cards, no coloured side bars. Hierarchy comes from size, weight and `--muted`.
- **Light and dark are equal.** Every colour token has both values.

## Design system first

Every UI change starts from the design system and leaves it up to date.

1. **Look it up first.** Read the artifact's README, tokens and the guide of the component you touch before you change the UI. Build with what is there.
2. **Missing or wrong? Change the design system.** A new token, a changed value, a new or changed component, a new rule: add it to the artifact in the same piece of work, then implement it in `:root` and the CSS, then document it here. Never let the code get ahead of the design system.
3. **Every UI PR updates the design system.** A PR that touches `dev/dashboard.html`, `MenubarIcon.swift`, the app icon, or user-facing copy rules also republishes the artifact (tokens, README, component guides and previews it affects) and says so in its description. A pure refactor with no visible change still syncs renamed or removed tokens.
4. **Names are identical.** A token is `name` in the artifact and `--name` in `:root`. Values the artifact cannot hold as a token (`color-mix()`, motion) are given as computed values or described in its README.
5. **One artifact.** There is one design system for Usage Meter. Don't create a second one; revise this one.

## Rules for changing the UI

1. **Use tokens only.** No colour, size, space, radius, font size, weight or duration as a literal in a rule. Need a new value? Add it to the design system, then as a token to `:root` (and its dark value if it is a colour), then document it here.
2. **Contrast WCAG 2.2 AA.** Text ≥ 4.5:1 on every background it can sit on: card, page, and the tinted session card, in light and dark. Work it out before adding a colour. Fills (`--accent-blue`, `--time-fill`, the stress colours) are never text colours.
3. **All user text through `swift/Resources/strings.json`**, Dutch and English, every key in both.
4. **Prove "no visible change".** A refactor must leave every computed style and box identical; compare before and after in the browser with fake data (see Verifying).
5. Fixed width 360. Both views report their content height through the `resize` message (`{height, main}`); the main view grows with the number of model cards and the popover opens at its last height (`mainHeight`, clamped 160–800 in `AppDelegate.swift`). Never change the menu bar title or icon while the popover is open.

## Tokens

All names below are CSS custom properties in `dev/dashboard.html`.

### Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | `#F0F0F0` | `#1C1C1E` | Page behind the cards |
| `--card-bg` | `#FFFFFF` | `#2C2C2E` | Cards, settings cards, menu bar pill |
| `--text` | `#1A1A1A` | `#F2F2F2` | Primary text |
| `--muted` | `#636366` | `#ABABB0` | Secondary text; ≥ 4.5:1 on card, page and tinted session card |
| `--track` | `#EAEAEA` | `#3A3A3C` | The universal "empty": bar track, segmented track, row divider, switch off |
| `--on-accent` | `#FFFFFF` | same | Text on `--accent-fill-strong`, switch knob |
| `--accent-blue` | `#4B7BEC` | `#6B93F5` | Week bar fill (fills only) |
| `--time-fill` | `accent-blue` 30% over `track` | same formula | Elapsed week behind the usage fill |
| `--accent-text` | `#3366D6` (5.23:1) | `= accent-blue` (4.72:1) | Week % as text, focus ring |
| `--accent-fill-strong` | `#3366D6` | same | Update button fill: `--on-accent` on it 5.23:1 in both themes (taak 60) |
| `--time-text` | `#4D6FB3` (4.95:1) | `#9DB5F2` (6.85:1) | "% elapsed" as text |
| `--icon-color` | `#8A8A8A` | `#9A9A9E` | Header icon buttons (icons: 3:1 is enough) |
| `--icon-hover-bg` | `rgba(0,0,0,.07)` | `rgba(255,255,255,.08)` | Icon button hover |
| `--icon-hover-color` | `#1A1A1A` | `#F2F2F2` | Icon colour on hover |
| `--status-ok` | `#34C759` | same | Connected, switch on |
| `--status-stale` | `#FF9500` | same | Stale data, update badge |
| `--status-error` | `#FF3B30` | same | Not logged in, outage (dots and badges only) |
| `--status-error-text` | `#D70015` (5.39:1) | `#FF6961` (4.95:1) | Update error as text (taak 60) |
| `--stress-low` | `#2FA84A` | same | Session colour at 0% |
| `--stress-mid` | `#FF9500` | same | Session colour at 50% |
| `--stress-high` | `#FF3B30` | same | Session colour at 100% |
| `--stress-tint` | `14%` | same | Session card = stress colour at this share over `--card-bg` |
| `--stress-track` | `30%` | same | Donut track = stress colour at this share over `--card-bg` |

**The stress ramp.** `colorForPct()` reads the three `--stress-*` tokens and blends linearly: 0–50% from low to mid, 50–100% from mid to high. The result is set as `--stress-color` on the session card. As text it is never used directly: `readableStressColor()` mixes in black (light) or white (dark) in 5% steps until it reaches 4.6:1 on the tinted card. The menu bar ring (`MenubarIcon.swift`) and notifications use their own copies of these colours in Swift; keep them in step.

### Type

One family, `--font-system` (`-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif`), plus `--font-mono` for the version chip.

| Token | Size | Typical weight | Use |
|---|---|---|---|
| `--text-face-card` | 25px | — | Emoji in a model card's ring |
| `--text-value-lg` | 20px | bold | Session % on a model card |
| `--text-name` | 14px | bold | Source name on its card |
| `--text-title` | 15px | bold | Header title |
| `--text-body` | 13px | regular / semibold / bold | Body, row titles, session %, week % |
| `--text-secondary` | 12px | regular / semibold | Session reset, row values, footer status, buttons |
| `--text-caption` | 11px | regular / semibold | Footer, week reset, sub lines, segmented, resets link |
| `--text-group` | 10.5px | semibold, caps | Group label above a settings card |
| `--text-label` | 10px | semibold, caps | Label inside a card ("CURRENT SESSION") |

Weights: `--weight-regular` 400, `--weight-medium` 500 (menu bar pill), `--weight-semibold` 600, `--weight-bold` 700. Uppercase labels use `--tracking-caps` (0.06em). Digits that line up get `tabular-nums`.

### Space

Named by their pixel value, because the popover has one fixed width and every value is a deliberate pixel decision: `--space-1` 1, `--space-2` 2, `--space-4` 4, `--space-5` 5, `--space-6` 6, `--space-8` 8, `--space-9` 9, `--space-10` 10, `--space-12` 12, `--space-14` 14.

The ones that carry the layout:

- `--space-14`: popover edge (top and sides) and card padding. **Settings cards are 14 px all round too**: `.card` comes after `.settings-card` in the cascade and wins over its `4px 14px`. Rows bring their own 8 px on top of that. Do not make settings tighter (decided 7-10-2026). Exception (taak 65): the small cards below the main groups (version, "Show {name}", hidden sources) are `.compact`: `--space-6` top and bottom, rows at `--size-row-compact`, so a one-row card is 52 px, not 68–74.
- `--space-12`: popover bottom edge.
- `--space-10`: between cards and sections, inside a settings row.
- `--space-8`: between header buttons, settings row padding, week header to bar.
- `--space-4`: label to value inside a card.
- `--space-5`: group label to its card; week bar to its footer.

### Radius

`--radius-bar` 3 (bars, focus ring) · `--radius-chip` 4 (version chip) · `--radius-sm` 5 (active segment, pill) · `--radius-md` 6 (icon and update buttons) · `--radius-control` 7 (segmented) · `--radius-inset` 8 (preview strip) · `--radius-pill` 11 (switch) · `--radius-card` 12 (cards) · `--radius-round` 50% (dots, knob).

### Size

`--size-popover-width` 360 · `--size-icon-button` 28 · `--size-donut-card` 64 (stroke 7, r 26, in the SVG) · `--size-segmented` 186 (every segmented control, equal segments) · `--size-bar` 6 · `--size-tick` 2 · `--size-dot` 7 · `--size-dot-small` 6 · `--size-row` 46 · `--size-row-compact` 40 · `--size-pill` 22 · `--size-switch-w` 36 × `--size-switch-h` 21 with `--size-knob` 17 (knob travel is computed from these) · `--max-pill` 220 · `--size-focus-ring` 2 · `--underline-strong` 2.

### Shadow, opacity, motion

- `--shadow-segment` `0 1px 2px rgba(0,0,0,.15)`, `--shadow-knob` `0 1px 2px rgba(0,0,0,.25)`. Cards have no shadow.
- `--opacity-disabled` 0.4 (switch), `--opacity-busy` 0.6 (update button while working).
- `--ease-out` `cubic-bezier(0.16, 1, 0.3, 1)`; `--dur-fast` 0.15s (hover, segment), `--dur-base` 0.2s (switch), `--dur-slow` 0.4s (stress colour), `--dur-fill` 0.6s (donut and bar fill on open), `--dur-spin` 1s, `--dur-pulse` 1.5s, `--dur-shake` 3s (skull at 100%).
- The view switch (main ↔ settings) is animated in JavaScript: a 300 ms cross-fade, ease-in-out, 8 px slide: the new view lies over the old one (never an empty popover), the old one is gone at 60 %, the new one starts at 35 %; the title swaps halfway. The new view is measured first and the popover resizes from the first frame, so resize and fade are one movement. Respect `prefers-reduced-motion`.

### Deliberate literals

These stay numbers in the CSS on purpose: optical baseline nudges (`vertical-align: -2px` on the ring preview, `1px` on the version chip), the skull-shake keyframes, the pulse keyframe, SVG geometry in the markup (donut, menu bar ring, icons), and the 360/296 constants in Swift.

## Components

**Naming:** the cards on the overview are *model cards* (one per model provider: Claude, ChatGPT, …), not "the Claude card"; the app also serves people without Claude. In code they are still `.source-card` / `source`.

All in `dev/dashboard.html`; the design-system artifact has a live preview and notes for each.

- **Header**: title (`--text-title`) and 28 px icon buttons (refresh, settings, close; back chevron off the overview). The gear carries a 6 px badge only for an update (taak 65).
- **Model card** (one per source, stacked; taak 55f): tinted with that source's stress colour (`--stress-tint` over `--card-bg`). Top: 64 px ring with the emoji face (`faceIcon`, seasonal themes in Swift), name, then resets (Claude: a link to claude.ai; others: text) or the plan; session % large with "session · resets in 2h 40m"; "Updated 11:10" when the numbers are old. Below: the week as a `--card-bg` strip (radius 8): "61% week · resets Thu 09:00", "30% elapsed", one track with elapsed time behind usage and a 2 px tick when usage covers it. A window the source didn't report shows "—" or no strip, never 0. No numbers at all and a problem (not logged in, never fetched; taak 60): neutral card (`--muted` ring and tint, no fill, no face), the capitalised reason in place of the reset line; the footer shows a short status, and Claude's resets are underlined only because they are a link. Data: `sourceCard()` in `UsageCore/SourceCards.swift`.
- **Footer** (taak 61): status dot + short status only when something is wrong ("Claude: …" with more than one source); "Updated 2 min ago" only with one source and no problem; hidden when empty. The account (name · org · plan, e-mail in the tooltip) is on Claude's model screen. Only ChatGPT: no Claude status; "Updated …" is ChatGPT's, and only while its card doesn't say "Updated" itself.
- **Age of numbers** (taak 61): one notation everywhere, `ageText()` in `SourceCards.swift`: "just now", "1 min ago", "12 min ago" within the hour, then the time ("14:52") or date. Stand-alone lines start with a capital ("Updated 12:00").
- **Segmented controls** are radio groups named by their row title: one Tab stop (the chosen option), arrow keys move the choice.
- **At 0 %** neither the ring (round cap) nor the week bar draws a dot.
- **Model card opens its screen** (taak 65): the name with a chevron right after it (11 px, `--icon-color`) is a real button labelled "Details for {name}" (the Tab stop and the VoiceOver target); the card's numbers stay readable. A click anywhere on the card also opens it, as a mouse convenience (no role on the card). Resets/plan stay on the right of the header; Claude's resets link keeps its own click (`stopPropagation`). Status badge (taak 65): Claude's own problem (stale, not logged in) or a Claude outage puts the 6 px badge on the top right of the Claude model card's chevron, because the detail is on its screen.
- **Model screen** (taak 65, one per source, same cross-fade as settings, from the right): header = source name, back, refresh, close (no gear). Group "Connection": one row; title = what the source delivers (Claude: name · org · plan, e-mail in the tooltip, no title line without an account label; ChatGPT: "ChatGPT · Plus" when the plan is known), then a dot line with the connection status, and for Claude the service status as a link to status.claude.com. Below, only with two or more sources, a card without label: "Show {name}" with a switch; the last visible source can't be turned off; turning one off returns to the overview. Back goes to where you came from (overview, or Settings via Sources). About 232 px high.
- **Settings** (taak 65): app-wide only: Menu bar & display, Notifications & refresh, then a card without label with the version/update row, then Uninstall / Quit. While at least one source is hidden a "Sources" group sits between Notifications and Version: a row per hidden source (name, grey dot + "Hidden", chevron) that opens its model screen, where it is switched on again. Nothing hidden = no group. About 511 px high, 596 with the group. Row = title (`--text-body` semibold), optional sub line (`--text-caption`, `--muted`, ellipsis), control on the right. Controls: segmented control, switch, update button. Quiet text buttons below (uninstall, quit).
- **Menu bar preview**: pill with the ring and the title text exactly as the menu bar shows it. No numbers from any source: "—" in every style, no face, an empty ring (`noDataTitle` in `Formatting.swift`).

## App icon

`icon/ClaudeUsage.svg` is the source (512 × 512, a 412 × 412 macOS tile with radius 92.5); `icon/ClaudeUsage-1024.png` and `icon/ClaudeUsage.icns` are made from it. A smiling face in a ring with a green arc: the same ring-with-face as the donut. Its colours, taken from the SVG: arc `#76B528` → `#5B931C`, empty ring `#D3E0C0`, plate `#F5F8F0` → `#EBF0E1`, face `#FFD642` → `#FFBA1A` → `#FFA80A`, features `#704400`. Do not redraw it. After changing it, macOS shows the old icon until the icon cache is cleared (see CLAUDE.md).

## Multiple sources (designed in 55e, built in 55f/59)

The early mock-ups are retired; this is built. Every screen and state, on the design system: <https://claude.ai/artifact/PvWKEk3s6bBekSh4cEKwK9> (private Claude Design canvas).

- **Popover (C1b):** no picker. One card per source, stacked. The card is tinted with that source's stress colour (`--stress-tint` over `--card-bg`); top: ring with face, name, plan or resets, session % large; below: the week as a `--card-bg` strip inside the tinted card (radius 8). One source = the same card once. The main view grows with the number of sources.
- **Source names:** "Claude" and "ChatGPT" (not "Codex": the limit covers the whole ChatGPT plan).
- **Menu bar:** the source closest to a limit, with its name when it is not Claude.
- **Only ChatGPT:** when Claude never had numbers (nothing fetched) and another source has, Claude is not there: no card, no Claude model screen, no footer status, no badge for a Claude outage (`claudeAbsent()` in `SourceCards.swift`, `claude_absent` in the data). Once Claude had numbers it stays and reports its problems ("Claude: Not logged in"). With no numbers anywhere, Claude's neutral card stays.
- **Notifications:** source name first ("ChatGPT: 5-hour limit at 80%"), same thresholds per source, one switch.
- **Settings:** current layout with equal-width segmented controls and the menu bar preview as a line inside the Menu bar row; sources moved to their own screens (taak 65, see Components). Notifications per source follow in 55g.

## Verifying

Open `dev/dashboard.html` in a browser, call `updateData({...})` with fake data (see `render()` for the fields), and look at 360 px wide in light and dark. For a refactor, snapshot the computed style and bounding box of every element in the main and settings views before and after (dark: copy the rules of the dark media query into the sheet), and compare. Then check the real popover after `./scripts/deploy.sh`.
