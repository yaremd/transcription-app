# Seal design system (macOS, SwiftUI)

Every token lives in `Sources/Theme.swift`. Use tokens, never raw colors or ad-hoc fonts. All colors auto-adapt to light/dark inside `Theme.dynamic` — no `colorScheme` checks at call sites.

## Colors (light / dark)
- `background` #FCFCFD / #0D0E11 · `sidebar` #F7F7F9 / #101115
- `surface` #FFFFFF / #17181C (raised) · `inset` #F7F8FA / #101216 (sunken wells)
- `border` 9–10% ink · `divider` 6–7% · `track` 7–9% · `hover` 4.5–6%
- `accent` indigo #5E6AD2 / #6E79D6 — the one saturated color (You/mic, selection, primary actions)
- `green` #2F9E68 / #53B57F (Others/system audio, success) · `red` #DC3E42 / #EB5757 (record, destructive) · `amber` #BF7A18 / #E2A336 (warnings, cloud caution)
- `tagPalette` — 6 dot colors assigned deterministically per tag name via `Theme.tagColor`

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
