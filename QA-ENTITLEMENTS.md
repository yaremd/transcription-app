# Entitlement QA matrix (YAR-102)

Licensing bugs are trust bugs for this audience. Run this before any v1.0-era
release. The logic half is automated (`EntitlementTests` + `EntitlementMatrixTests`,
run with the normal test suite); this file is the **manual UI half**.

## How to force states

Debug builds only: **Settings → License → QA (debug builds only) → Force state.**
Ephemeral — never saved, gone on relaunch, compiled out of release builds.
"Trial expired / deactivated / tampered" all *derive* to Free, so walking the
UI in **Free** covers their surfaces; the automated tests prove the derivation.

## The walk (repeat per state: Free · Trial · Pro current · Pro lapsed · Lifetime)

| Surface | Free | Trial | Pro | Pro lapsed | Lifetime |
|---|---|---|---|---|---|
| Meeting page: Identify speakers (gate + ProBadge) | opens sheet | runs | runs | runs | runs |
| Meeting page: Improve transcript | opens sheet | runs | runs | runs | runs |
| Meeting page: Find action items | opens sheet | runs | runs | runs | runs |
| Meeting page: Draft follow-up | opens sheet | runs | runs | runs | runs |
| Notes Rewrite → Reshape section | opens sheet | runs | runs | runs | runs |
| Notes → custom templates ("Yours" section) | opens sheet | runs | runs | runs | runs |
| Ask this meeting (pill + dock) | opens sheet | runs | runs | runs | runs |
| Export menu → Word/.srt/.vtt | opens sheet | runs | runs | runs | runs |
| Settings → General → Calendar toggle | locked row + See Pro | toggle | toggle | toggle | toggle |
| Settings → Notes → cloud model toggle | locked row + See Pro | toggle | toggle | toggle | toggle |
| Sidebar Action Items pane | ProLockedPane | inbox | inbox | inbox | inbox |
| Upgrade sheet footer | trial + buy CTAs | days left + buy | Done | Done | Done |
| Settings → License plan row | "Seal Free" | "trial" + days | "Pro" + window date + renewal line | same, past date | "lifetime updates" |
| Menu bar extra | — | — | "Seal Pro" tag | tag | tag |
| Sparkle: Check for Updates… | offers newest | offers newest | offers builds inside window | declines newer-than-window with renewal message | offers newest |

## Non-negotiables — verify in EVERY state (especially Free)

- [ ] Open any past meeting; transcript, notes, tags, folders all readable/editable.
- [ ] Full-text search returns results.
- [ ] Copy as Markdown + Export as Markdown/PDF work.
- [ ] ⌘N records a new meeting with live transcription at full accuracy.
- [ ] Standard notes generate with built-in templates.
- [ ] Quit/relaunch: state survives; no crash, no data loss.

## Offline pass

Networking off (Wi-Fi down): every state above behaves identically, except
the two user-initiated moments — key activation and re-validation — which
must fail with a readable message, not a hang or crash.

## Destruction pass (automated, but spot-check once per release cycle)

- Corrupt `~/Library/Application Support/Seal/entitlement.json` (flip a byte):
  app launches as Free, no crash, meetings untouched, trial can start.
- Delete the file: same. (By design a data wipe resets the trial — the paying
  audience is buying trust, not DRM.)
- Meetings live in `Seal/Meetings/`, licensing in `Seal/entitlement.json` —
  licensing operations must never write inside `Meetings/`.

## Clean-VM funnel (before v1.0 tag)

Fresh macOS VM (or spare Mac that never ran Seal):
1. Download DMG from sealformac.com → open → drag to Applications.
2. Gatekeeper opens it without warnings (notarization intact).
3. Trial starts only when chosen; day count correct.
4. Checkout with a 100% test coupon → key email arrives → paste key →
   activation succeeds → welcome view shows.
5. Deactivate on this Mac (Settings → License) → back to Free, meetings intact.
6. Re-activate → seat reused, not double-counted (check Freemius dashboard).
7. Sparkle: Check for Updates offers (or correctly declines) per the plan's window.
