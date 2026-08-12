# Shipping Seal as a download

This is the plain-English path to letting anyone download and run Seal. The app
itself is ready; these steps sign it, get Apple's blessing (notarization), and
put it online. Steps marked **[you]** need your Apple ID password, so I can't do
them for you — but each is a couple of clicks or one command.

---

## One-time setup

### 1. Create a "Developer ID Application" certificate  **[you]**

You have an *Apple Distribution* certificate, but that's only for the App Store.
Direct downloads need a different one:

1. Open **Xcode → Settings → Accounts**.
2. Select your Apple ID, click **Manage Certificates…**.
3. Click **+** → **Developer ID Application**.

That's it — it's saved to your keychain and the release script finds it.

### 2. Store notarization credentials  **[you]**

Notarization = Apple scans the app so macOS trusts it. It needs a password:

1. Go to **appleid.apple.com → Sign-In & Security → App-Specific Passwords**,
   and create one (call it "Seal notarize"). Copy it.
2. Run this once (paste the password when asked):

   ```bash
   xcrun notarytool store-credentials "seal-notary" \
     --apple-id "your@email.com" --team-id S4M9R72TXR
   ```

### 3. Create Sparkle update-signing keys  **[you]**

These let Seal verify that an update really came from you.

1. Build the app once (so Sparkle's tools appear), then find and run `generate_keys`:

   ```bash
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f | head -1
   # run the path it prints:
   <that path>
   ```
2. It prints a **public key** and stores the private key in your keychain.
3. Paste the public key into `project.yml` → `SUPublicEDKey` (replacing
   `REPLACE_WITH_SPARKLE_PUBLIC_KEY`).

### 4. Placeholders  ✅ done

The repo URLs are set to `github.com/yaremd/transcription-app`:
- `SUFeedURL` → `https://sealformac.com/appcast.xml` (the old
  `yaremd.github.io/transcription-app/` URL 301-redirects there, so builds
  that shipped with the old URL — v0.18 and earlier — keep updating)
- the download links in `docs/index.html` and `docs/appcast.xml` → the repo's release assets

All placeholders are now filled — `SUPublicEDKey` is set to your Sparkle public key.

---

## Cut a release

First bump both versions in `project.yml` (`settings.base`):

- `MARKETING_VERSION` — what users see, e.g. `0.2`
- `CURRENT_PROJECT_VERSION` — **must increase every release**. Sparkle compares
  this number (`CFBundleVersion`) against `sparkle:version` in the appcast; if it
  doesn't go up, installed copies never see the update.

```bash
./scripts/release.sh
```

This regenerates the project, builds Release, signs with your Developer ID,
notarizes, staples, and produces `.release/Seal.dmg`. At the end it reads the
version back out of the app it just built and prints a complete `<item>` block —
versions, pubDate, enclosure URL, and Sparkle signature already filled in. It
also warns if the appcast already advertises that `sparkle:version`, which means
you forgot to bump.

Then:
1. Create a **GitHub Release** tagged `v<MARKETING_VERSION>` (e.g. `v0.2`) and
   upload the DMG as `Seal.dmg` — the printed enclosure URL assumes that exact
   tag and asset name.
2. Paste the printed `<item>` at the top of the `<channel>` in `docs/appcast.xml`.
   Leave older items alone: each one's `edSignature` belongs to its own DMG.
3. Commit and push. Done — existing users get the update automatically.

### Pre-publish checklist (the licensing era)

- **`pubDate` on the new appcast item is present and untouched** — the Pro
  update-window (UpdatePolicy) is judged by it. The script prints it; never
  hand-edit or omit it.
- **Verify the deploy**: `gh api repos/yaremd/transcription-app/pages/builds/latest`
  says `built` AND `curl https://sealformac.com/appcast.xml` shows the new
  `sparkle:version`. A push that "worked" can still leave the appcast stale.
- **Licensing smoke test** on a machine or VM that has never run Seal —
  the full funnel in `QA-ENTITLEMENTS.md` ("Clean-VM funnel"). Non-negotiable
  before the v1.0 tag; spot-check on ordinary releases.
- Beta-era installs (meetings older than 2026-08-11) see the SEALBETA
  thank-you note exactly once, and never on licensed installs.

### At v1.0
- Release notes say plainly: this is the build where the Free/Pro line turns
  on, and beta users are thanked (SEALBETA — free Pro; capped redemptions;
  expires Nov 10, 2026).
- Create the purchasing-power-parity coupon (~50% off) in Freemius.
- Connect the Freemius payout method (Wise/Payoneer) if not done yet.

### At v1.1
- **Early-bird ends**: change plan 61232 to $59 in Freemius, then update
  `Pricing.earlyBird` and the site's price block in the same release.

## Put the download page online (GitHub Pages)  **[you, one time]**

In your repo on github.com: **Settings → Pages → Source: Deploy from a branch →
Branch: `main`, Folder: `/docs`**. The page is served at
`https://sealformac.com` — the custom domain is bound by `docs/CNAME`, and the
DNS A/AAAA + `www` records live in Vercel's DNS (the domain registrar).
`https://yaremd.github.io/transcription-app/` 301-redirects there.

---

## What's already done
- On-device AI (no Ollama) — verified working, including under Hardened Runtime.
- Hardened Runtime is on (required for notarization), with a minimal, non-sandboxed
  entitlements file (`Support/Seal.entitlements`) declaring microphone access — the
  one entitlement a notarized hardened build needs to record.
- Sparkle auto-update is wired into the app (menu: **Seal → Check for Updates…**).
- The download page (`docs/index.html`) and appcast (`docs/appcast.xml`) are ready.

## Build gotchas (already handled in the script)
- Needs the Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain` (one-time).
- Needs `-skipPackagePluginValidation -skipMacroValidation` (MLX's build plugin + macros).
