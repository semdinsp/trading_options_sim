# Design System — "Dark Pool" Terminal

This document captures the visual language of the Trading Dashboard so new
screens, components, and LiveViews stay consistent with what's already built.
If you're adding a page, read this first.

## Concept

A single always-on dark theme modeled on institutional trading terminals
(Bloomberg/Reuters desk aesthetic) rather than a generic light/dark toggle.
The dashboard is a tool operators stare at all day next to other terminals —
it should look dense, fast, and unmistakably *not* a generic SaaS dashboard.

There is intentionally **no light theme and no theme switcher**. A single
`dark_pool` DaisyUI theme is hardcoded in the root layout
(`data-theme="dark_pool"`). If a future requirement needs a light mode,
treat it as a deliberate second theme addition, not a toggle bolted onto
this one.

## Typography

Two font families, no exceptions:

| Role | Font | Used for |
|------|------|----------|
| Display | `Oswald` (condensed grotesk) | Headings, nav, buttons, labels, badges — anything that's a *word*, not a *number* |
| Data | `JetBrains Mono` | Anything numeric or feed-like: prices, P&L, quantities, timestamps, raw message payloads, badges that wrap a value |

Loaded via `@import url(...)` at the top of `assets/css/app.css` (Google
Fonts). `body` defaults to `font-display`; apply `.font-data` (or Tailwind's
arbitrary `font-[--font-data]` if you need it inline) to any element showing
numbers or live data.

Headings and nav labels are uppercase with wide tracking
(`uppercase tracking-wide` / `tracking-wider` / `tracking-[0.2em]` for hero
text). Body copy is sentence case.

## Color

Defined as a single DaisyUI theme block named `dark_pool` in
`assets/css/app.css`. Don't add ad-hoc hex/oklch colors in component files —
extend the theme tokens instead.

| Token | Role | Notes |
|-------|------|-------|
| `primary` (amber) | Primary actions, focus, the "signal" color | Used for the live-feed dot, hero accent, primary nav hover state |
| `secondary` / `accent` / `info` (cyan) | Informational accents, secondary CTAs | Message topic badges, "Book"/secondary hero card |
| `success` (green) | Gains, filled orders, connected state | |
| `error` (red) | Losses, rejected orders, disconnected state | |
| `warning` (amber, same hue as primary) | Pending states | |
| `base-100/200/300` | Background layers, darkest to less-dark — 100 is the *page* bg, 300 is the *highest* surface (headers, stat strips) | Inverted from typical DaisyUI convention — check before reusing |

Custom tokens (in `:root`, not part of the DaisyUI theme plugin) for
direction-of-trade, which is semantically distinct from gain/loss:

```css
--color-long: oklch(72% 0.17 150);   /* .text-long / .bg-long */
--color-short: oklch(68% 0.19 25);   /* .text-short / .bg-short */
```

Use `text-long`/`text-short` for LONG/SHORT position badges so direction
reads independently of the P&L color in the same row (a long position can
have negative unrealized P&L right next to it — don't conflate the two).

## Surfaces & Shape

- Hard edges everywhere. `--radius-*` tokens are near-zero (0.125rem). Don't
  add `rounded-lg`/`rounded-xl` to new components — use `rounded-none` or
  leave the DaisyUI default, which is already square.
- Borders, not shadows, separate regions. `--depth: 0` in the theme disables
  DaisyUI's default elevation shadows. Panels are framed with
  `border border-base-300`, not `shadow-lg`.
  Don't reintroduce `shadow-*` utilities on cards/headers.
  Stat strips and grouped cards use `gap-px bg-base-300` (a "seam" pattern)
  instead of individual card borders + margins — see `stat_card/1` in
  `portfolio_monitor_live.ex` for the canonical example.
- Badges/pills are never DaisyUI's default `badge` pill shape — they're
  small bordered rectangles: `px-1.5 py-0.5 border text-[11px] uppercase
  tracking-wide`. Color the border + text together (e.g.
  `border-success/40 text-success bg-success/10`), don't use solid
  `badge-success` fills.

## Background texture

`body` has a faint 24px grid line texture (two `linear-gradient`s at 95%) to
suggest a terminal/graph-paper surface without being loud. This is global —
don't duplicate it per-page. The homepage hero adds three vertical gradient
"data lines" on top of that as a one-off decorative flourish; that pattern
is hero-specific, not a reusable utility.

## Motion

Two purpose-built CSS animations in `app.css`, used sparingly:

- `.signal-dot` — pulsing ring on the connection-status dot when connected/
  live. Don't use a generic `animate-pulse` for this; `.signal-dot` is
  tuned to look like a radar ping, not a loading skeleton.
- `.row-flash` — brief amber background flash (1.2s) for newly-arrived rows
  in a live feed. Applied to `message_item/1` in the Message Monitor; apply
  to any future live-streamed row component the same way.

Avoid adding new keyframe animations without a clear "this represents live
data arriving" justification — motion is reserved for signaling liveness,
not decoration.

## Layout patterns

- `Layouts.trading_navbar/1` — the only navbar. Fixed height (`h-14`),
  square logo mark + wordmark with a `://` accent in primary color. Every
  page (including the marketing-style homepage) must render this; if a
  controller/template doesn't go through `Layouts.app` or
  `Layouts.trading_live`, render `<Layouts.trading_navbar />` directly at
  the top of the template (see `home.html.heex`).
- `Layouts.trading_live/1` — full-viewport layout for the two monitor
  LiveViews. Use this (not `Layouts.app`) for any new dense, live-updating
  monitor screen.
- Monitor LiveViews follow a fixed three-zone pattern: header bar (title +
  connection status + nav + controls) → stats/filter strip → scrollable
  content area(s). Multi-panel views (Portfolio Monitor) split panels with
  `border-base-300` and a `bg-base-200` mini-header per panel showing an
  icon + uppercase label + count.

## Empty states

Every list/feed has a dedicated empty-state component (`empty_positions/1`,
`empty_orders/1`, `empty_pnl_history/1`, `empty_state/1` in Message
Monitor). Pattern: large icon at 30% opacity in `text-primary`, uppercase
heading, muted `font-data` subtext, and — only when relevant — a bordered
error-colored chip if the underlying cause is "not connected to Trading
Hub". Reuse this shape for any new empty state rather than inventing a new
one.

## When adding a new screen

1. Wrap in `Layouts.trading_live` (dense monitor) or add
   `<Layouts.trading_navbar />` manually (marketing/static page).
2. Headings/labels: `Oswald` (default), uppercase, tracking-wide.
3. Any number, price, timestamp, or raw payload: wrap in `font-data` /
   `tabular-nums`.
4. New status/category indicator → bordered rectangle badge, not a pill.
5. New color need → extend the `dark_pool` theme block or add a token next
   to `--color-long`/`--color-short` in `:root`, don't inline a one-off hex.
6. No rounded corners, no drop shadows, borders only.
