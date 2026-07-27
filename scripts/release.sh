#!/usr/bin/env bash
#
# Builds a signed, notarized, Sparkle-ready Seal.dmg for direct download.
#
# PREREQUISITES (one-time — see DISTRIBUTION.md):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notarization credentials stored:  xcrun notarytool store-credentials "seal-notary"
#   3. Sparkle EdDSA keys created:       ./bin/generate_keys   (public key pasted into project.yml)
#
# NOTE: This script has not been run end-to-end yet (it needs the credentials
# above). It encodes the standard flow; expect to tweak the CONFIG values.

set -euo pipefail

# ---------------- CONFIG (edit these) ----------------
APP_NAME="Seal"
SCHEME="LocalScribe"
TEAM_ID="S4M9R72TXR"
DEV_ID="Developer ID Application: Dmytro Yaremchuk (${TEAM_ID})"
NOTARY_PROFILE="seal-notary"
# Where the DMG will be downloadable (used in the appcast enclosure):
DOWNLOAD_URL_BASE="https://github.com/CHANGE-ME/seal/releases/latest/download"
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

echo "▶︎ Signing the update for Sparkle…"
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1)"
if [ -z "${SIGN_UPDATE:-}" ]; then
  echo "  (sign_update not found — build once so Sparkle's artifacts exist, or run bin/sign_update)"
else
  echo "  Paste the following into a new <item> in docs/appcast.xml:"
  "$SIGN_UPDATE" "$DMG"
fi

echo ""
echo "✅ Built: $DMG"
echo "Next:"
echo "  1. Upload $DMG to a GitHub Release (its URL becomes the appcast enclosure)."
echo "  2. Add an <item> to docs/appcast.xml with that URL + the edSignature/length above."
echo "  3. Commit & push docs/ — GitHub Pages serves the page and the appcast."
