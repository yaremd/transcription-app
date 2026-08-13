# Seal brand system

App: **Seal** (internal codename LocalScribe). Promise: what's said here stays here.
Mascot character name: **TBD** — shortlist is Stamp (wax pun) or Harbor (harbor seal +
safe-harbor). Decide before website copy.

One creature, two fidelities: the **flat mark** (app icon, menu bar, favicon,
stamp) and the **mascot illustration** (onboarding, About, empty states, website
hero). Don't mix fidelities in one surface.

## The mark: a face that says nothing

An earless, mouthless harbor-seal face. Both absences are the argument:

- **Earless** — harbor seals genuinely have no ear flaps. Nothing here eavesdrops.
- **Mouthless** — it hears everything and repeats nothing. (Hello Kitty precedent:
  a missing mouth reads as calm, not creepy.)

A third reading is doing work: the mark is a solid disc with the face punched
clean through, which is what a wax seal actually is. Official impression first,
animal a half-second later — that order matters, because the credibility lands
before the charm.

**Face grid (240 viewBox).** Every version shares it exactly.

| | |
| --- | --- |
| disc | c(120,120) r80 |
| eyes | c(81,104) and c(159,104), r18 |
| nose | two lobes, dipped bridge, rounded point; x100–140, y134–160 |
| whiskers | two a side, drooping down and out; stroke 6, round caps |

Two things in that grid are load-bearing and were arrived at by testing the
alternatives: a **triangle** nose reads unmistakably as a cat, and whiskers that
angle **upward** do too. The dipped nose and the droop are what make it a seal.

**Small cut.** At 20 px and below, use `seal-mark-icon-small.svg` — whiskers
dropped, eyes and nose enlarged. A 6-unit stroke is a fifth of a pixel at 16 px
and only muddies the face.

## Files

Everything below with "generated" beside it comes out of
`Brand/gen-seal-mark.swift`. Edit the geometry constants at the top of that
script, never the SVGs.

    swift Brand/gen-seal-mark.swift                                # from the repo root

| File | What it is |
| --- | --- |
| `seal-mark-icon.svg` | generated · the mark. One path, features punched, recolours with a single `fill`. Menu bar template glyph, watermarks. |
| `seal-mark-icon-small.svg` | generated · small cut, 20 px and below |
| `seal-lockup.svg` | generated · mark + "Seal" wordmark, outlined from the system font so it needs no font installed |
| `seal-mark.svg` | the mascot: lips-sealed pose, flippers clasped over the mouth |
| `seal-stamp.svg` | wax lockup — scalloped wax, pressed field, embossed face. Source for the stop-stamp animation (YAR-59). |
| `out/web/*.png` | generated · favicon 48, apple-touch 180, nav 206, og card 1200×630. Copy into `docs/` with `cp Brand/out/web/*.png docs/`. |
| `out/proof/` | generated · icon renders pulled out of the built app |
| `concepts/` | the routes this was chosen from, and `contact-sheet.html` |
| `seal-icon-source.jpg` | **superseded.** The hand-drawn pup that was the app icon until Aug 2026. Kept for history; it is not the icon and should not be regenerated. |

## App icon

`Support/Seal.icon` is an Icon Composer document and the real source.
`project.yml` points `ASSETCATALOG_COMPILER_APPICON_NAME` at `Seal`. `actool`
compiles the layered icon for macOS 26 and emits a `Seal.icns` fallback for 14
and 15 in the same pass, so the deployment target does not move. Verified by a
full build: `Seal.app` ships `CFBundleIconName = Seal` with both.

The legacy `AppIcon.appiconset` and its generator are both **gone** — `actool`
builds the `.icns` from `Seal.icon`, so carrying a second hand-made icon set
only invited the two to drift. There is one icon source now and no second
pipeline to keep in step. If the pre-26 route is ever genuinely needed, it is
in git history at `e12152c`.

Two knowns:

- **16 px is a blob.** The layered format has no size-specific art, so the app
  icon at 16 px (Finder list view) renders the full mark including whiskers. The
  menu bar is unaffected — that is the flat glyph, where we control the cut.
- **Glass and shadow are dialled down** in `icon.json` (`glass: false`, shadow
  0.3) to respect the flat-shapes rule. If the icon ever looks out of place
  beside other macOS 26 icons, those are the two switches.

## Website

Copying the PNGs into `docs/` is not sufficient. `docs/index.html` also inlines
the mark in three places, and all three have to move together:

1. An **SVG data-URI favicon** in `<head>`. Browsers prefer `image/svg+xml` over
   `/favicon.png`, so the tab icon does not change until this line does. It is
   drawn as a forest tile with a lime face to match the PNG — forest on
   transparent disappears against a dark tab bar.
2. `.stamp` — the small wax seal on "Your sealed note".
3. `.stampimg` — the large wax seal in the closing band.

The OG card (`og.png`) is generated, not hand-made: same composition the site
already shipped, redrawn so its lockup and its wax stamp carry the new face.

## Color

The marks now track `Theme.accent`. The old indigo (`#5E6AD2`, `#4A55B8`,
`#23253A`) is gone from every file.

- **Mark** — forest `#0A2A21` ground, lime `#D3F36B` face. One dark, one bright,
  no third hue, no gradients. On light surfaces the mark is accent `#14513C`.
- **Mascot** — body `#1B6B4F` (the website's accent-hover), muzzle `#EFFAD8`,
  speckles and flippers `#14513C`, ink `#0E1512`, white catchlights.
  Two colours were tried and rejected: **forest** as the body goes to silhouette
  and stops reading as a seal, and **lime** as the body is nearly invisible on
  the white pages where the mascot mostly lives.
- **Mascot whiskers are shortened** — the one deliberate departure from the grid.
  At full length the muzzle pad has to run edge to edge and the head reads as two
  stacked bands instead of a face.
- **Wax** `#C9503C`, pressed field `#B03E2E`, embossed cream `#F2E4D8`, paper
  `#F6F1E7`. Wax red is deliberately NOT Theme.red (`#DC3E42`): a red dot means
  recording is live, wax means sealed and saved. Never swap them. Wax appears
  only in the stamp; it is not a general brand colour.

## Rules

1. The seal **keeps** secrets, never collects them. Never draw it listening at
   doors, peeking, with a microphone, or with ears of any kind.
2. **Never on screen while recording.** Mascot moments: onboarding, empty states,
   errors, About, release notes, website. Working UI stays quiet.
3. Calm, not zany. Reference: Bear app's bear. Anti-model: Duolingo's owl.
4. Flat shapes only, Theme.swift-consistent. No gradients, fur, 3D, outlines.
5. Sub rosa: a tiny rose variant of the stamp (ancient symbol of confidentiality)
   is an easter egg, not the primary mark.
