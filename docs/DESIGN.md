# Usage Meter — design system

How the popover looks and why. The popover is one page, [`dev/dashboard.html`](../dev/dashboard.html), shown in a WKWebView at a fixed width of 360 px. Its tokens live in the `:root` block at the top of that file; this document explains them. The same system is published as a browsable Claude Design artifact (private): <https://claude.ai/artifact/XiqpxqouWriHsupojDQAyL>.

## Principles

- **One job.** Show at a glance how much room is left. Anything that does not serve that stays out.
- **Native macOS.** System font, system-like greys, Apple status colours. The only brand element is the app icon.
- **Data first.** Show only what the source demonstrably returns. Unknown means show nothing; never invent values, marks or copy.
- **Colour means load.** The only expressive colour is the session stress ramp. Blue is the week. Everything else is neutral.
- **Quiet.** Few borders, no shadows on cards, no coloured side bars. Hierarchy comes from size, weight and `--muted`.
- **Light and dark are equal.** Every colour token has both values.

## Rules for changing the UI

1. **Use tokens only.** No colour, size, space, radius, font size, weight or duration as a literal in a rule. Need a new value? Add a token to `:root` (and its dark value if it is a colour), then document it here.
2. **Contrast WCAG 2.2 AA.** Text ≥ 4.5:1 on every background it can sit on: card, page, and the tinted session card, in light and dark. Work it out before adding a colour. Fills (`--accent-blue`, `--time-fill`, the stress colours) are never text colours.
3. **All user text through `swift/Resources/strings.json`**, Dutch and English, every key in both.
4. **Prove "no visible change".** A refactor must leave every computed style and box identical; compare before and after in the browser with fake data (see Verifying).
5. Fixed width 360. Both views report their content height through the `resize` message (`{height, main}`); the main view grows with the number of source cards and the popover opens at its last height (`mainHeight`, clamped 160–800 in `AppDelegate.swift`). Never change the menu bar title or icon while the popover is open.

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
| `--text-face` | 34px | — | Emoji in the large donut (not used since 55f) |
| `--text-face-card` | 25px | — | Emoji in a source card's ring |
| `--text-value-lg` | 20px | bold | Session % on a source card |
| `--text-name` | 14px | bold | Source name on its card |
| `--text-title` | 15px | bold | Header title |
| `--text-body` | 13px | regular / semibold / bold | Body, row titles, session %, week % |
| `--text-secondary` | 12px | regular / semibold | Session reset, row values, account name, buttons |
| `--text-caption` | 11px | regular / semibold | Footer, week reset, sub lines, segmented, resets link |
| `--text-group` | 10.5px | semibold, caps | Group label above a settings card |
| `--text-label` | 10px | semibold, caps | Label inside a card ("CURRENT SESSION") |

Weights: `--weight-regular` 400, `--weight-medium` 500 (menu bar pill), `--weight-semibold` 600, `--weight-bold` 700. Uppercase labels use `--tracking-caps` (0.06em). Digits that line up get `tabular-nums`.

### Space

Named by their pixel value, because the popover has one fixed width and every value is a deliberate pixel decision: `--space-1` 1, `--space-2` 2, `--space-4` 4, `--space-5` 5, `--space-6` 6, `--space-8` 8, `--space-9` 9, `--space-10` 10, `--space-12` 12, `--space-14` 14.

The ones that carry the layout:

- `--space-14`: popover edge (top and sides) and card padding. **Settings cards are 14 px all round too**: `.card` comes after `.settings-card` in the cascade and wins over its `4px 14px`. Rows bring their own 8 px on top of that. Do not make settings tighter (decided 7-10-2026).
- `--space-12`: popover bottom edge.
- `--space-10`: between cards and sections, inside a settings row.
- `--space-8`: between header buttons, settings row padding, week header to bar.
- `--space-4`: label to value inside a card.
- `--space-5`: group label to its card; week bar to its footer.

### Radius

`--radius-bar` 3 (bars, focus ring) · `--radius-chip` 4 (version chip) · `--radius-sm` 5 (active segment, pill) · `--radius-md` 6 (icon and update buttons) · `--radius-control` 7 (segmented) · `--radius-inset` 8 (preview strip) · `--radius-pill` 11 (switch) · `--radius-card` 12 (cards) · `--radius-round` 50% (dots, knob).

### Size

`--popover-width` 360 · `--size-icon-button` 28 · `--size-donut` 90 (not used since 55f) · `--size-donut-card` 64 (stroke 7, r 26, in the SVG) · `--size-segmented` 186 (every segmented control, equal segments) · `--size-bar` 6 · `--size-tick` 2 · `--size-dot` 7 · `--size-dot-small` 6 · `--size-row` 46 · `--size-row-compact` 40 · `--size-pill` 22 · `--size-switch-w` 36 × `--size-switch-h` 21 with `--size-knob` 17 (knob travel is computed from these) · `--max-pill` 220 · `--max-account` 140 · `--focus-ring` 2 · `--underline-strong` 2.

### Shadow, opacity, motion

- `--shadow-segment` `0 1px 2px rgba(0,0,0,.15)`, `--shadow-knob` `0 1px 2px rgba(0,0,0,.25)`. Cards have no shadow.
- `--opacity-disabled` 0.4 (switch), `--opacity-busy` 0.6 (update button while working).
- `--ease-out` `cubic-bezier(0.16, 1, 0.3, 1)`; `--dur-fast` 0.15s (hover, segment), `--dur-base` 0.2s (switch), `--dur-slow` 0.4s (stress colour), `--dur-fill` 0.6s (donut and bar fill on open), `--dur-spin` 1s, `--dur-pulse` 1.5s, `--dur-shake` 3s (skull at 100%).
- The view switch (main ↔ settings) is animated in JavaScript: 110 ms out, 240 ms in with the same easing, title 200 ms. Respect `prefers-reduced-motion`.

### Deliberate literals

These stay numbers in the CSS on purpose: optical baseline nudges (`vertical-align: -2px` on the ring preview, `1px` on the version chip), the skull-shake keyframes, the pulse keyframe, SVG geometry in the markup (donut, menu bar ring, icons), and the 360/296 constants in Swift.

## Components

All in `dev/dashboard.html`; the design-system artifact has a live preview and notes for each.

- **Header**: title (`--text-title`) and 28 px icon buttons (refresh, settings with a 6 px status badge, close; back chevron in settings).
- **Source card** (one per source, stacked; taak 55f): tinted with that source's stress colour (`--stress-tint` over `--card-bg`). Top: 64 px ring with the emoji face (`faceIcon`, seasonal themes in Swift), name, then resets (Claude: a link to claude.ai; others: text) or the plan; session % large with "session · resets in 2h 40m"; "updated 11:10" when the numbers are old. Below: the week as a `--card-bg` strip (radius 8): "61% week · resets Thu 09:00", "30% elapsed", one track with elapsed time behind usage and a 2 px tick when usage covers it. A window the source didn't report shows "—" or no strip, never 0. No numbers at all and a problem (not logged in, never fetched; taak 60): neutral card (`--muted` ring and tint, no fill, no face), the capitalised reason in place of the reset line; the footer shows a short status instead of an empty account, and Claude's resets are underlined only because they are a link. Data: `sourceCard()` in `UsageCore/SourceCards.swift`.
- **Footer**: status dot (only when something is wrong), account name, org, plan, "Updated".
- **Settings** (taak 59): group label above a card of rows. Menu bar row: title and control on one line, the preview on its own line below (no box in the card). With more than one source the last group is "Sources & system": a row per source (status, show switch; the last visible source can't be hidden), then the version. Row = title (`--text-body` semibold), optional sub line (`--text-caption`, `--muted`, ellipsis), control on the right. Controls: segmented control, switch, update button. Quiet text buttons below (uninstall, quit).
- **Menu bar preview**: pill with the ring and the title text exactly as the menu bar shows it.

## App icon

`icon/ClaudeUsage.svg` is the source (512 × 512, a 412 × 412 macOS tile with radius 92.5); `icon/ClaudeUsage-1024.png` and `icon/ClaudeUsage.icns` are made from it. A smiling face in a ring with a green arc: the same ring-with-face as the donut. Its colours, taken from the SVG: arc `#76B528` → `#5B931C`, empty ring `#D3E0C0`, plate `#F5F8F0` → `#EBF0E1`, face `#FFD642` → `#FFBA1A` → `#FFA80A`, features `#704400`. Do not redraw it. After changing it, macOS shows the old icon until the icon cache is cleared (see CLAUDE.md).

## Multiple sources (designed in 55e, built in 55f/59)

Mock-ups: <https://claude.ai/artifact/AePS2L7t15pFoEZKBuvP7C> (private).

- **Popover (C1b):** no picker. One card per source, stacked. The card is tinted with that source's stress colour (`--stress-tint` over `--card-bg`); top: ring with face, name, plan or resets, session % large; below: the week as a `--card-bg` strip inside the tinted card (radius 8). One source = the same card once. The main view grows with the number of sources.
- **Source names:** "Claude" and "ChatGPT" (not "Codex": the limit covers the whole ChatGPT plan).
- **Menu bar:** the source closest to a limit, with its name when it is not Claude.
- **Notifications:** source name first ("ChatGPT: 5-hour limit at 80%"), same thresholds per source, one switch.
- **Settings:** current layout with equal-width segmented controls and the menu bar preview as a line inside the Menu bar row; sources (status per source, show/hide switch) at the bottom where Connection is now; then version; then Uninstall / Send feedback / Quit. Settings are about 705 px high with two sources. Notifications per source follow in 55g.

## Verifying

Open `dev/dashboard.html` in a browser, call `updateData({...})` with fake data (see `render()` for the fields), and look at 360 px wide in light and dark. For a refactor, snapshot the computed style and bounding box of every element in the main and settings views before and after (dark: copy the rules of the dark media query into the sheet), and compare. Then check the real popover after `./scripts/deploy.sh`.
