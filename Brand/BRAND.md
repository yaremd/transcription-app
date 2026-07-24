# Seal brand system

App: **Seal** (internal codename LocalScribe). Promise: what's said here stays here.
Mascot character name: **TBD** — shortlist is Stamp (wax pun) or Harbor (harbor seal +
safe-harbor). Decide before website copy.

## The mark: a face that says nothing

An earless, mouthless harbor-seal face. Both absences are the argument:

- **Earless** — harbor seals genuinely have no ear flaps. Nothing here eavesdrops.
- **Mouthless** — it hears everything and repeats nothing. (Hello Kitty precedent:
  a missing mouth reads as calm, not creepy.)

Face grid (240 viewBox, head r76 at 120,118): eyes r9 at (92,104) and (148,104),
nose 9×6.5 at (120,138), four whisker dots. All versions share this grid exactly.

## Files — one geometry, three jobs

- `seal-mark-icon.svg` — monochrome, features punched through (transparent).
  Use ≤ 96 px: menu-bar template glyph, favicon, watermarks. Recolor via group fill.
- `seal-mark.svg` — full-color mascot: the **lips-sealed pose**, flippers clasped
  over the mouth. Use ≥ 96 px: onboarding, About, website hero, empty states.
- `seal-stamp.svg` — wax lockup (scalloped wax, pressed field, embossed face).
  Source for the app icon (YAR-60) and the stop-stamp animation (YAR-59).

Future illustration poses (draw with proper beziers, keep the face grid): banana
rest for empty states, curled-asleep-on-notes for guarding imagery.

## Color

- Body indigo `#5E6AD2` (= Theme.accent light; use `#6E79D6` on dark surfaces).
- Details: muzzle `#DDE0F8`, shading/flippers `#4A55B8`, ink `#23253A`.
- Wax `#C9503C`, pressed field `#B03E2E`, embossed cream `#F2E4D8`, paper `#F6F1E7`.
- Wax red is deliberately NOT Theme.red (`#DC3E42`): red dot means recording live,
  wax means sealed and saved. Never swap them.

## Rules

1. The seal **keeps** secrets, never collects them. Never draw it listening at
   doors, peeking, with a microphone, or with ears of any kind.
2. **Never on screen while recording.** Mascot moments: onboarding, empty states,
   errors, About, release notes, website. Working UI stays quiet.
3. Calm, not zany. Reference: Bear app's bear. Anti-model: Duolingo's owl.
4. Flat shapes only, Theme.swift-consistent. No gradients, fur, 3D, outlines.
5. Sub rosa: a tiny rose variant of the stamp (ancient symbol of confidentiality)
   is an easter egg, not the primary mark.
