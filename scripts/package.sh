#!/usr/bin/env bash
# package.sh — build, sign, notarize and DMG Airlive Bridge for website distribution
# (the OBS model: a downloadable, notarized installer — NOT the App Store).
#
# Prereqs (one-time, your Apple Developer account):
#   • A "Developer ID Application" certificate in your login keychain.
#   • A notarytool keychain profile:
#       xcrun notarytool store-credentials airlive-notary \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Run:
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="airlive-notary" \
#   ./scripts/package.sh
#
# Without DEVELOPER_ID_APP it does an UNSIGNED build (to smoke-test the pipeline)
# and skips signing/notarization with a warning.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Airlive Bridge"
SCHEME="AirliveBridge"
BUILD_DIR="$ROOT/build"
DD="$BUILD_DIR/dd"
APP="$DD/Build/Products/Release/$APP_NAME.app"
STAGING="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/$APP_NAME.dmg"
ENTITLEMENTS="$ROOT/AirliveBridge.entitlements"

echo "▶︎ Regenerating project + building Release…"
/opt/homebrew/bin/xcodegen >/dev/null 2>&1 || xcodegen >/dev/null 2>&1 || true
rm -rf "$BUILD_DIR"; mkdir -p "$STAGING"

SIGN_BUILD=()
[ -z "${DEVELOPER_ID_APP:-}" ] && SIGN_BUILD=(CODE_SIGNING_ALLOWED=NO)

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild -project AirliveBridge.xcodeproj -scheme "$SCHEME" \
  -configuration Release -derivedDataPath "$DD" \
  -destination 'platform=macOS' "${SIGN_BUILD[@]}" build >/dev/null
[ -d "$APP" ] || { echo "✗ build did not produce $APP"; exit 1; }
echo "  ✓ built $APP"

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  echo "▶︎ Signing (Hardened Runtime + entitlements)…"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APP" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "  ✓ signed"
else
  echo "⚠️  DEVELOPER_ID_APP unset — UNSIGNED build (skipping notarization). For a"
  echo "   distributable build set DEVELOPER_ID_APP + NOTARY_PROFILE (see header)."
fi

echo "▶︎ Building DMG…"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "  ✓ $DMG"

if [ -n "${DEVELOPER_ID_APP:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▶︎ Notarizing (this can take a few minutes)…"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "  ✓ notarized + stapled — ready to ship: $DMG"
elif [ -n "${DEVELOPER_ID_APP:-}" ]; then
  echo "⚠️  NOTARY_PROFILE unset — signed but NOT notarized. Gatekeeper will warn on"
  echo "   other Macs. Set NOTARY_PROFILE to notarize."
fi

echo "Done."
