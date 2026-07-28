#!/usr/bin/env bash
#
# Builds a signed, notarized, Sparkle-ready Seal.dmg for direct download.
#
# PREREQUISITES (one-time — see DISTRIBUTION.md):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notarization credentials stored:  xcrun notarytool store-credentials "seal-notary"
#   3. Sparkle EdDSA keys created:       ./bin/generate_keys   (public key pasted into project.yml)
#
# All three prerequisites are in place and this script shipped v0.1 end-to-end
# (notarization accepted 2026-07-27), so the CONFIG values below are known good.
#
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml before
# running — Sparkle will not offer an update unless the latter increases.

set -euo pipefail

# ---------------- CONFIG (edit these) ----------------
APP_NAME="Seal"
SCHEME="LocalScribe"
TEAM_ID="S4M9R72TXR"
DEV_ID="Developer ID Application: Dmytro Yaremchuk (${TEAM_ID})"
NOTARY_PROFILE="seal-notary"
# Where the DMG will be downloadable. This is per-release and versioned on
# purpose: an appcast enclosure must be an immutable URL, so /releases/latest/
# would repoint older items at a newer DMG and break their edSignature.
RELEASE_URL_BASE="https://github.com/yaremd/transcription-app/releases/download"
# -----------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.release"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "▶︎ Regenerating Xcode project…"
( cd "$ROOT" && xcodegen generate )

echo "▶︎ Archiving (Release)…"
xcodebuild -project "$ROOT/LocalScribe.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -archivePath "$OUT/$APP_NAME.xcarchive" archive

echo "▶︎ Exporting a Developer ID-signed app (Hardened Runtime is already on)…"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/$APP_NAME.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"

APP="$OUT/export/$APP_NAME.app"
DMG="$OUT/$APP_NAME.dmg"

echo "▶︎ Building the DMG…"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --sign "$DEV_ID" --timestamp "$DMG"

echo "▶︎ Notarizing (uploads to Apple; can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶︎ Stapling the notarization ticket…"
xcrun stapler staple "$DMG"

# Read the versions back out of the app we just built, rather than out of
# project.yml — the built bundle is the only thing that proves the version keys
# actually expanded. Sparkle compares CFBundleVersion, so if this prints 1 for
# every release, no update will ever be offered.
PLIST="$APP/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "▶︎ Built bundle reports version $SHORT_VERSION ($BUILD_VERSION)"

APPCAST="$ROOT/docs/appcast.xml"
if grep -q "<sparkle:version>$BUILD_VERSION</sparkle:version>" "$APPCAST"; then
  echo "  ⚠️  docs/appcast.xml already advertises sparkle:version $BUILD_VERSION."
  echo "     Installed copies report the same number, so Sparkle will NOT offer"
  echo "     this update. Bump CURRENT_PROJECT_VERSION in project.yml and rebuild."
fi

echo "▶︎ Signing the update for Sparkle…"
# Match the EdDSA tool by its full path. A bare `-name sign_update` also matches
# bin/old_dsa_scripts/sign_update — the deprecated DSA script, which takes a
# different argument list — and with several LocalScribe-* DerivedData dirs the
# order `find` returns them in is arbitrary, so `head -1` is a coin flip.
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData \
  -path "*artifacts/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)"
SIGNATURE_ATTRS=""
if [ -z "${SIGN_UPDATE:-}" ]; then
  echo "  (sign_update not found — build once so Sparkle's artifacts exist)"
  SIGNATURE_ATTRS='sparkle:edSignature="PASTE_ME" length="PASTE_ME"'
else
  SIGNATURE_ATTRS="$("$SIGN_UPDATE" "$DMG")"

  # Verify what we just produced. A signature the client rejects fails silently
  # here otherwise: the appcast looks fine and every user's update fails.
  echo "▶︎ Verifying the signature…"
  EDSIG="$(printf '%s' "$SIGNATURE_ATTRS" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
  "$SIGN_UPDATE" --verify "$DMG" "$EDSIG"
  echo "  signature verifies against the Keychain key"

  # …and confirm that key is the one the app trusts. If SUPublicEDKey belongs to
  # a different keypair, --verify still passes but every client rejects the update.
  APP_PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
  GENERATE_KEYS="$(dirname "$SIGN_UPDATE")/generate_keys"
  KEYCHAIN_PUBKEY="$("$GENERATE_KEYS" 2>&1 | grep -oE "[A-Za-z0-9+/]{43}=" | head -1)"
  if [ "$APP_PUBKEY" != "$KEYCHAIN_PUBKEY" ]; then
    echo "  ✗ SUPublicEDKey in the app does not match the signing key in your Keychain."
    echo "    app:      $APP_PUBKEY"
    echo "    keychain: $KEYCHAIN_PUBKEY"
    echo "    Every client would reject this update. Fix SUPublicEDKey in project.yml."
    exit 1
  fi
  echo "  SUPublicEDKey matches the signing key"
fi

echo ""
echo "✅ Built: $DMG"
echo ""
echo "Paste this <item> at the top of the <channel> in docs/appcast.xml:"
echo ""
cat <<ITEM
    <item>
      <title>Version $SHORT_VERSION</title>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure
        url="$RELEASE_URL_BASE/v$SHORT_VERSION/$APP_NAME.dmg"
        $SIGNATURE_ATTRS
        type="application/octet-stream" />
    </item>
ITEM
echo ""
echo "Next:"
echo "  1. Create GitHub Release tag v$SHORT_VERSION and upload $DMG as $APP_NAME.dmg"
echo "     (the enclosure URL above assumes exactly that tag and asset name)."
echo "  2. Add the <item> above to docs/appcast.xml."
echo "  3. Commit & push docs/ — GitHub Pages serves the page and the appcast."
