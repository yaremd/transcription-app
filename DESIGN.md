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

- `inkAI` #676B66 / #9EA39D — text the model wrote, as opposed to text the user typed. The
  meeting page shows both and the difference is the whole point: muted is the model's reading of
  the meeting, ink is the user's own words, and editing a muted line makes it ink (no badge, no
  icon — see `NotesProvenance`). 5.3:1 on `background` in light, 7.4:1 in dark.

## Type (SF Pro system font only)
`pageTitle` 20 semibold · `title` 15 semibold · `body` 13 · `bodyMedium` 13 medium · `sub` 12 · `meta` 11 · `metaMedium` 11 medium.
`SectionLabel`: 11 semibold, uppercase, tracking 0.7, secondary. Speaker labels: 10 semibold uppercase, tracking 0.6, tinted.

Document type, for the meeting page only: `docTitle` 24 semibold · `docBody` 15 (+`docLineSpacing` 5,
≈1.5 line height) · `docBodyMedium` · `docHeading` 15 semibold · `docSmall` 14 (checklists), on a
`docMeasure` of 640pt (~70 characters). 13pt is Apple's *interface* size and reads as a form; every
real document app runs 15–17pt on a 480–700pt measure. Side panels (transcript, Ask) stay at 13.

## Components
- Buttons: `LinearButtonStyle` — `.linearPrimary` / `.linearQuiet` / `.linearDestructive` (+`Compact` variants). 6pt radius, hairline border, hover wash, 0.97 press dip.
- Panels: `.insetPanel(radius: 8)` for wells (transcript, editors); `.surfacePanel()` for raised tiles/cards.
- Inputs: `.linearField()`; plain TextFields inside composed rows.
- Ask bar: `AskBar` — the one place to talk to Seal about a meeting. It lives where the answers are: under
  the document while the companion is closed or on Transcript, and at the foot of the Ask tab while that is
  open (no transcript button there; ⇧⌘T still works), sharing one `AskDraft` per meeting so a half-typed
  question and its files move with it, and a question sent from under the notes hands the cursor to the box
  beside its answer. With Ask open, the live page keeps only the recording chip under the notes. It is a 30pt transcript button (lit with an accent wash while the transcript shows; ⇧⌘T), then a box that
  grows from one line to six. Typed text is a question (Return asks; the answer streams into the companion's
  Ask tab, which opens); a leading "/" turns it into a command that filters the page's `AskBarAction`s (command
  word first, then a title word, then anywhere — `AskBarMatch`). Focused and empty, it lists three starter
  questions and the featured actions above itself, on frosted glass; ↑↓ move, ↩ runs, esc puts the list away,
  ↑ in a quiet box recalls the last question. Files go beside a question by the paperclip, paste, or drop,
  each an `inset` row above the text, read into text on the Mac first. ⌘J focuses it. Its text view
  (`ComposerTextView`, AppKit) takes focus only from a click, Tab, or ⌘J — never because the window became
  key — so the cursor waits in the notes, not in Ask.
- Floating glass: `.floatingGlass(in:)` for anything that floats over the page (the Ask bar and the bar's list)
  — Liquid Glass on macOS 26, `surface` + hairline + soft shadow before; `frosted: true` tints it for surfaces
  that are read, not glanced at. `FloatingGlassGroup` draws neighbouring glass as one material.
- Recording chip: `RecordingChip` — the live session's only control, first in the Ask bar: a `BreathingDot`
  (red, with a halo that swells with the louder of you or the call; grey and still when paused), the running
  time, and a pause button (⏸, ▶ when paused; neutral, never red, so it can't read as Stop) on one red 10%
  wash. Pause acts at once; the dot and time open one panel: Stop and save (⇧⌘R), Star (⇧⌘H), Snap (⇧⌘S),
  then a row each for the microphone and the language naming the one in use (`ChoiceRow` — a click drops a
  native menu of the choices below the row, as wide as it, the current one ticked; a choice applies to this
  recording at once and the panel stays open), then Discard set apart. Speed swaps the speech model, so it
  can't change mid-meeting and isn't a session control: it is a preference, Settings → Recording →
  Transcription (remembered as `transcriptionSpeed`, locked while recording). Pause and Stop are also in the
  bar's "/".
- Edge tab: `EdgeTabView` in an `EdgeTabPanel` (borderless, non-activating, but can take the keyboard) —
  shown while a recording runs and Seal isn't in front. Folded, an 18pt sliver with the dot against the
  screen's edge; under the pointer it slides out to 420pt: dot and time (open Seal), pause, stop, star, snap,
  and "Jot a note" (Return files a timestamped note without leaving the call; esc gives the keyboard back).
  The panel grows before the face opens and shrinks after it folds, so nothing draws outside the window.
  Dragged, it settles on the nearer side of the screen it is dropped on; side and height persist
  (`edgeTabSide`, `edgeTabHeight`). Never folds while a note is being typed or it is being dragged.
- Chips: `TagChip` (dot + 11pt label + optional ✕).
- Icon buttons: `.buttonStyle(.plain)`, 11pt SF Symbol, `.secondary` — and always a `.help()` tooltip.
- Icon menus: `Menu { … }` + `.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(…)`.
- Progress: `ProgressLabel(text:)` (small spinner + caption); download states show real percentages.

## The meeting page
One page for the live recording and every saved meeting, so nothing is learned twice
(`MeetingPageLayout`): a document column (title, the user's jotted notes, the model's write-up,
action items, a follow-up once drafted) with a companion column beside it — Transcript or Ask —
that the page reflows next to, never an overlay that hides what it refers to. The companion is
360pt, narrowing to 280 so the document keeps ~350 at the window's minimum; its visibility and tab
are one shared preference (`CompanionPrefs`). The companion runs from the window's top edge: its
divider reaches up through the toolbar, and its Transcript and Ask tabs (plain text, the one that's
on resting on a `hover` wash, inset 12pt from the divider like the column's own content) and a bare ✕
(its glyph over the column's trailing icons) are toolbar items with no glass behind them
(`sharedBackgroundVisibility(.hidden)`, `CompanionToolbar`), stretched across the column's width, so the page's own toolbar
item — Share, on a saved meeting — ends just left of the column, over the document it belongs to.
Nothing else is in the toolbar; on macOS 26 the window title is removed from it (the page shows the
title in large type right below), and a flexible `ToolbarSpacer` keeps the items trailing
(`meetingPageToolbar`). The document column clips itself so its text never scrolls into the toolbar
strip. (SwiftUI's `.inspector` was tried for the column and rejected: nested in the split view's
detail it sat under the toolbar, pushed every item to the far right and shifted the document under the
sidebar.) New meeting is the sidebar's first row (⌘N is File → New Meeting, so it works with the
sidebar hidden); while recording that row becomes the live meeting with its running time. Everything
the model can do for the page — rewrite, write as a template, reshape, action items, follow-up,
identify speakers, improve the transcript, export — runs from the Ask bar's "/" list.
Transcript-only actions also stay on the transcript's own ⋯ menu. The live page's only bar is the Ask
bar with the recording chip first in it. Title and notes edit in place on click and save on focus loss
— no Edit/Save pair.

## Rules
- Radii: 4 chips · 6 buttons/fields · 8 panels · 10 chat bubbles · 14 the Ask bar's list · 22 the Ask bar (its 30pt button plus a 7pt inset, so one line is a capsule) · 22 the open edge tab, 10 folded, square against the screen edge · capsule for the recording chip and pills.
- Spacing rhythm: 6/8/10/12/14/16/24.
- Motion: `.spring(response: 0.3, dampingFraction: 1.0)` for panel/section collapse; `.easeOut(0.12–0.2)` for hover/press; nothing decorative; honor Reduce Motion (`PulsingDot` holds steady).
- Copy: sentence case everywhere including menu items; "…" on actions that ask or confirm; no em dashes in UI copy.
- Pro gating: `.proGated(.feature)` + `ProBadge()`; inside menus, gate at the action and let the section title carry "— Seal Pro". A whole panel that *is* the feature (Ask) explains itself when locked instead of showing dead controls.
- Status: transient conditions are notices that auto-dismiss; only hard errors persist. Fully-local is the default and is not announced; the amber badge appears only when cloud notes are on.
