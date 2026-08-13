# Seal — logo design prompt

A commissioning brief for a new primary mark, written to be pasted whole into a
model or handed to a studio. Colors are the live forest/lime tokens from
`DESIGN.md` and `docs/index.html` — nothing here invents a hue.

**Why replace the current icon.** The hand-drawn pup is pale blue with a
pixel-mosaic wash: it shares no color with the brand, reads "kids app" rather
than "notary," dissolves below 32 px, and fails macOS 26's layered icon format.
Those are four separate failures, not a matter of taste.

---

## 1. The prompt

Paste this whole block.

```text
You are a senior identity designer at a Pentagram-calibre studio. Design the
primary logo for Seal — a private, on-device meeting-notes app for macOS.
Seal listens to meetings and transcribes them entirely on the user's machine.
Nothing it hears ever leaves the Mac. Its users are lawyers, clinicians,
founders and consultants who are privacy-sensitive by instinct or by policy.

THE IDEA TO EXECUTE
"Seal" is two things at once: the animal, and the wax seal that proves nothing
has been opened. The mark must hold both readings in one shape — an official
impression that resolves, a half-second later, into a harbour seal's face.

Two absences carry the whole argument and are non-negotiable:
  - NO EARS. Harbour seals genuinely have no ear flaps. Nothing here eavesdrops.
  - NO MOUTH. It hears everything and repeats nothing.
Calm and institutional, never cute. The temperature is a notary stamp, not a
mascot. Bear app's bear is the closest acceptable warmth; Duolingo's owl is the
anti-reference.

FORM
Flat vector on a visible geometric logic — circles, arcs, one consistent stroke
weight or pure solid fills; constructions a viewer could redraw with a compass.
Optically corrected, not mathematically naive. The face is two solid circular
eyes, one rounded nose, four whisker dots, inside a single unbroken circular
contour. Nothing else. The mark should feel like a piece of punctuation.

COLOR — use these exact values and no others
  Forest        #0A2A21   the dark ground and the app-icon field
  Deep forest   #061C16   optional second dark, for depth only
  Signal green  #14513C   the mark on light backgrounds
  Lime          #D3F36B   the single highlight; the face on forest
  Ink           #0E1512   neutral dark
  Paper         #FFFFFF / Mist #F5F6F1   neutral light
  Wax red       #C9503C   ONLY inside the wax-seal expression, never as a
                          general brand colour, never as a status colour
Primary app icon: lime face on a forest ground. One dark, one bright, no third
hue, no gradients of any kind. The restraint is the argument.

IT MUST SURVIVE
  - 16 px in the macOS menu bar as a single-colour alpha glyph
  - one-colour engraving and 1-bit photocopy
  - being cropped by the system squircle mask
  - light and dark backgrounds, unchanged
  - being flattened to one arbitrary tint by macOS 26's icon system

NEVER
Gradients, gloss, 3D, bevels, drop shadows, outer glows. Big cartoon eyes with
specular sparkles. Pixel or mosaic texture. Hand-drawn wobble. Microphones,
headphones, waveforms, speech bubbles, ears of any kind. A seal peeking,
listening at a door, or holding an object. Purple-to-blue tech gradients.
Swooshes. More than two colours in any single expression.

DELIVER
  1. The primary mark, flat vector on a 240 x 240 grid, with the centre and
     radius of every circle stated so it can be rebuilt exactly.
  2. A monochrome single-path version that holds at 16 px.
  3. The app-icon composition on forest.
  4. A horizontal lockup with the wordmark "Seal" — neo-grotesque, tight but
     not cramped tracking, optically aligned to the mark.
  5. One sentence explaining why the mark is right. If you cannot write that
     sentence, the mark is decoration and you should start again.
```

---

## 2. Four routes worth exploring

Ask for all four as thumbnails, then push **one** to resolution. Averaging them
produces the mush that makes logos look generated.

- **A — The impression.** A wax medallion whose intaglio is the seal's face.
  Scalloped edge, pressed field, the face struck into it. Most literal on the
  double meaning; the risk is fussiness at 16 px.
- **B — The reduction.** The face alone, drawn with total conviction on the
  existing grid. Two eyes, a nose, four whisker dots, one circle. Highest
  survival rate at every size; asks the most of the drawing.
- **C — The unbroken line.** The head as one continuous contour that never
  breaks — because a broken seal is a broken promise. The concept lives in the
  construction rather than in an added element.
- **D — The monogram.** The `S` of Seal and the animal's silhouette occupying
  the same counterform. Strongest as a favicon and a stamp; hardest to keep
  from reading as a clever trick.

The existing geometry, if a route wants to inherit it: 240 viewBox, head r76 at
(120,118), eyes r9 at (92,104) and (148,104), nose 9 × 6.5 at (120,138), four
whisker dots (see `Brand/seal-mark-icon.svg`). Treat it as a starting proportion,
not a cage.

---

## 3. Technical requirements the studio must be told

- **macOS 26 layered icon.** Deliver background, middle and foreground as
  separate layers with no pre-baked squircle, no baked shadow, and no baked
  specular highlight — the system draws all three. Art sits inside the standard
  inset (824 of 1024). It must survive the automatic light, dark, clear and
  tinted variants without the face disappearing into its ground.
- **Menu-bar glyph.** One path, alpha only, no fill colours; features punched
  through so it works as a template image.
- **Small sizes.** Favicon 32 px, site nav 30 px, sidebar 16–20 px.
- **Clear space.** One eye-diameter on all sides, minimum.
- **Minimum size.** 16 px for the monochrome glyph; 24 px for anything with two
  colours.
- **File formats.** SVG source with a documented grid, plus a flattened
  single-path variant. No raster masters.

---

## 4. The tests it has to pass

If it fails any one of these it isn't finished:

1. **Squint test.** At 16 px, is it still a face and not a smudge?
2. **1-bit test.** Printed in pure black on white, does the argument survive?
3. **Half-second test.** Official seal first, animal second. That order matters —
   the credibility lands before the charm.
4. **Memory test.** Can someone who saw it once redraw it roughly right?
5. **Dock test.** Sitting between Slack, Notion and Zoom, is it obviously not
   any of them?

---

> **Status, Aug 2026: Route B was chosen and resolved.** The shipping spec now
> lives in `Brand/BRAND.md`; open `Brand/concepts/proof.html` to see it. This
> brief is kept as the reasoning behind the mark and as the prompt to hand a
> studio if the identity is ever taken further.

## 5. Drawn concepts — routes B and C

In `Brand/concepts/`. Open `contact-sheet.html` in a browser to see both at every
size, on light and dark, in the Dock and as a lockup.

| File | What it is |
| --- | --- |
| `route-b-mark.svg` | Route B, primary |
| `route-b-mark-small.svg` | Route B, small cut for 20 px and below |
| `route-c-mark.svg` | Route C, primary |
| `route-c-mark-small.svg` | Route C, small cut for 24 px and below |
| `contact-sheet.html` | Both routes, all contexts |
| `studio.html` | Variant explorer used to arrive at these — edit the arrays to try more |

**Shared face geometry** (240 grid), so either route can be rebuilt exactly:

- eyes — r18 at (81,104) and (159,104)
- nose — two lobes with a dipped bridge and a rounded point, spanning x100–140,
  y134–160. The dip is what stops it reading as a cat; a plain triangle nose
  tested as unmistakably feline.
- whiskers — two a side, **drooping** down and out, stroke 6, round caps.
  Whiskers that angle upward also read cat. This was the single biggest fix.
- Route B adds: disc c(120,120) r80, features punched through to transparent.
- Route C adds: closed contour, centerline x47–193 / y47–194, stroke 15, with the
  face scaled to 0.85 about the centre so nothing collides with it.

Both drop the whiskers at small sizes and enlarge the eyes and nose instead —
a 6-unit stroke is a fifth of a pixel at 16 px and only muddies the face.

**What is still open.** Neither has been tested as a macOS 26 layered icon, and
neither carries a wordmark beyond the placeholder SF Pro setting in the contact
sheet. Route A (the wax medallion) and Route D (the monogram) are undrawn.

## 6. Notes on tooling

Image generators produce raster approximations with wobbly curves and invented
colours — useful for exploring routes 1–4, useless as a master. Use them for
thumbnails only. For the actual mark, give this brief to a model that outputs
SVG, or to a person. Either way the grid coordinates in section 1's deliverables
list are what makes the result rebuildable.

## 7. Downstream, once the mark is chosen

- `Brand/BRAND.md` §Color still carries the open decision and the old indigo
  (`#5E6AD2`) body colour — close it.
- `seal-mark.svg`, `seal-mark-icon.svg` and `seal-stamp.svg` get recoloured to
  the chosen palette.
- `Brand/gen-appicon.swift` regenerates the appiconset; the layered-icon export
  is new work alongside it.
