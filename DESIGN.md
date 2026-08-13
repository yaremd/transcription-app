# Seal design system (macOS, SwiftUI)

Every token lives in `Sources/Theme.swift`. Use tokens, never raw colors or ad-hoc fonts. All colors auto-adapt to light/dark inside `Theme.dynamic` — no `colorScheme` checks at call sites.

## Colors (light / dark)
- `background` #FCFDFB / #0C0F0E · `sidebar` #F6F8F4 / #0F1211
- `surface` #FFFFFF / #161A18 (raised) · `inset` #F7F9F6 / #0F1312 (sunken wells)
  Neutrals carry a faint green bias so they sit under the accent instead of fighting it.
- `border` 9–10% ink · `divider` 6–7% · `track` 7–9% · `hover` 4.5–6%
- `accent` forest #14513C / lime #D3F36B — the one saturated color (You/mic, primary
  actions), shared with the website. It **inverts** across appearances rather than
  lightening: the middle of the green range is indistinguishable from `green` under
  red-green color blindness, so the accent stays at the extremes where luminance alone
  separates them (ΔE 0.24 simulated, vs 0.21 for the old indigo).
- `onAccent` #FFFFFF / #0E1512 — **always** use this on an accent fill, never `.white`,
  which disappears on lime (1.25:1).
- `selection` #14513C / #1E5C46 — for surfaces macOS draws itself: List row selection,
  `.tint(…)`, toggle tracks. The system hard-codes a white foreground on these and we
  can't override it, so this token stays dark enough for white in both appearances.
  Rule of thumb: **we** draw the foreground → `accent`; **macOS** draws it → `selection`.
- `green` #238050 / #53B57F (Others/system audio, success). The light value clears AA
  on every ground it's drawn on (4.91:1 white, 4.64 inset, 4.60 sidebar); the old
  #2F9E68 cleared none of them. It can't go lighter for separation from `accent`:
  every green dark enough for AA lands ~0.15 OKLab away, so in light appearance the
  speaker's name carries the disambiguation that colour alone can't.
- `red` #DC3E42 / #EB5757 (record, destructive) · `amber` #BF7A18 / #E2A336 (warnings, cloud caution)
- `tagPalette` — 6 dot colors assigned deterministically per tag name via `Theme.tagColor`.
  Deliberately a functional rainbow, not brand colors: the hash maps a tag to an index,
  so changing an entry silently recolors every existing tag that lands on it.
- Surfaces macOS paints for itself, and how each is reclaimed:
  a grouped `Form` draws its own scroll material (#1F222F) — every Form in Settings
  hides it *individually*, since setting that on the enclosing `TabView` does not
  reach them; the window toolbar is a vibrancy material sampling the desktop (#282936)
  until `.toolbarBackground(Theme.background, for: .windowToolbar)` pins it. These five
  Forms and the sidebar `List` are the only `List`/`Form`/`Table` in the app.

## Type (SF Pro system font only)
`pageTitle` 20 semibold · `title` 15 semibold · `body` 13 · `bodyMedium` 13 medium · `sub` 12 · `meta` 11 · `metaMedium` 11 medium.
`SectionLabel`: 11 semibold, uppercase, tracking 0.7, secondary. Speaker labels: 10 semibold uppercase, tracking 0.6, tinted.

## Components
- Buttons: `LinearButtonStyle` — `.linearPrimary` / `.linearQuiet` / `.linearDestructive` (+`Compact` variants). 6pt radius, hairline border, hover wash, 0.97 press dip.
- Panels: `.insetPanel(radius: 8)` for wells (transcript, editors); `.surfacePanel()` for raised tiles/cards.
- Inputs: `.linearField()`; plain TextFields inside composed rows.
- Chips: `TagChip` (dot + 11pt label + optional ✕).
- Icon buttons: `.buttonStyle(.plain)`, 11pt SF Symbol, `.secondary` — and always a `.help()` tooltip.
- Icon menus: `Menu { … }` + `.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(…)`.
- Progress: `ProgressLabel(text:)` (small spinner + caption); download states show real percentages.

## Rules
- Radii: 4 chips · 6 buttons/fields · 8 panels · 10 chat bubbles · capsule for the control bar and pills.
- Spacing rhythm: 6/8/10/12/14/16/24.
- Motion: `.spring(response: 0.3, dampingFraction: 1.0)` for panel/section collapse; `.easeOut(0.12–0.2)` for hover/press; nothing decorative; honor Reduce Motion (`PulsingDot` holds steady).
- Copy: sentence case everywhere including menu items; "…" on actions that ask or confirm; no em dashes in UI copy.
- Pro gating: `.proGated(.feature)` + `ProBadge()`; inside menus, gate at the action and let the section title carry "— Seal Pro".
- Status: transient conditions are notices that auto-dismiss; only hard errors persist. Fully-local is the default and is not announced; the amber badge appears only when cloud notes are on.
