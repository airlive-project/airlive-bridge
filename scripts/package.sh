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
ENTITLEMENTS="$ROOT/AirliveBridge.entitlements"
# DMG filename is set AFTER the build from the app's real version (below) so it
# is deterministic + versioned + hyphenated (no spaces) — it MUST match the
# appcast <enclosure url> exactly, or Sparkle 404s the update.  $DMG assigned later.

echo "▶︎ Regenerating project + building Release…"
/opt/homebrew/bin/xcodegen >/dev/null 2>&1 || xcodegen >/dev/null 2>&1 || true
rm -rf "$BUILD_DIR"; mkdir -p "$STAGING"

# ARCHIVE + EXPORT, never a plain `build`.
#
# The app ships a CAMERA SYSTEM EXTENSION, and a system extension carries a RESTRICTED
# entitlement (com.apple.developer.system-extension.install).  macOS only honours a
# restricted entitlement when the bundle carries a PROVISIONING PROFILE that grants it, and
# only `-exportArchive` embeds a Developer ID profile.  A plain `build` produces an app that
# runs perfectly on the build machine — its development certificate is right here — and whose
# virtual camera REFUSES TO LOAD on every other Mac: the app installs, NDI / OBS / RTSP / SRT
# / HDMI all work, and the camera silently never appears in anyone's camera list.  Sparkle
# would have delivered exactly that to everyone on the previous version.
#
# Unsigned smoke-test builds skip the export (there is no profile to embed) and are marked
# as such, so a DMG built that way can never be mistaken for a shippable one.
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>XWBJP49FTR</string>
  <key>signingStyle</key><string>automatic</string>
  <!-- Notarization is a separate, explicit step further down (with the stapling this
       does not do), so the export must not try to run its own. -->
  <key>destination</key><string>export</string>
</dict>
PLIST
  echo "</plist>" >> "$BUILD_DIR/ExportOptions.plist"

  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild -project AirliveBridge.xcodeproj -scheme "$SCHEME" \
    -configuration Release -derivedDataPath "$DD" \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive >/dev/null
  [ -d "$ARCHIVE" ] || { echo "✗ archive failed"; exit 1; }

  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR" >/dev/null
  APP="$EXPORT_DIR/$APP_NAME.app"
  [ -d "$APP" ] || { echo "✗ export did not produce $APP"; exit 1; }

  # The whole reason for the archive path: prove the profile is actually in there.
  # The profile belongs on the APP, which is where the restricted entitlement
  # (system-extension.install) lives.  The extension itself needs none — its two
  # entitlements, the sandbox and a TEAM-PREFIXED app group, are self-authorizing — but it
  # must be Developer ID signed like everything else in the bundle.
  EXT="$APP/Contents/Library/SystemExtensions/studio.airlive.bridge.AirliveBridge.vcam.systemextension"
  [ -f "$APP/Contents/embedded.provisionprofile" ] \
    || { echo "✗ no embedded.provisionprofile in the app — the virtual camera would be dead for users"; exit 1; }
  [ -d "$EXT" ] || { echo "✗ the camera extension is missing from the exported app"; exit 1; }
  codesign -dvv "$EXT" 2>&1 | grep -q "Authority=Developer ID Application" \
    || { echo "✗ the camera extension is not Developer ID signed — it will not load on any other Mac"; exit 1; }
  echo "  ✓ exported $APP (Developer ID, provisioning profile embedded, extension signed)"
else
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild -project AirliveBridge.xcodeproj -scheme "$SCHEME" \
    -configuration Release -derivedDataPath "$DD" \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build >/dev/null
  [ -d "$APP" ] || { echo "✗ build did not produce $APP"; exit 1; }
  echo "  ⚠︎ UNSIGNED smoke-test build — the virtual camera will NOT load. Not shippable."
fi

# Make SRT self-contained: bundle libsrt (+ its deps) into Contents/Frameworks BEFORE any
# signing, so the app-level codesign below seals it. Signs the added dylibs with the same
# identity (ad-hoc "-" when DEVELOPER_ID_APP is unset). libndi stays EXTERNAL on purpose
# (NDI's license forbids redistribution — the user installs NDI Tools).
echo "▶︎ Bundling libsrt for self-contained SRT…"
"$ROOT/scripts/bundle-libsrt.sh" "$APP" "${DEVELOPER_ID_APP:--}"

# Versioned, hyphenated DMG name from the app's real marketing version — MUST
# match the appcast enclosure url.  (Read from the built plist = single source.)
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="$BUILD_DIR/Airlive-Bridge-${VERSION}.dmg"

# GUARD: never SHIP a build whose update-trust anchor is missing.  Sparkle can't
# verify updates without a real SUPublicEDKey, so a placeholder/empty key = an
# unprotected update channel.  Abort a distributable (signed) build; only warn on
# the unsigned smoke-test.
EDKEY="$(defaults read "$APP/Contents/Info.plist" SUPublicEDKey 2>/dev/null || echo "")"
if [ -z "$EDKEY" ] || [ "$EDKEY" = "REPLACE_WITH_generate_keys_OUTPUT=" ] || \
   ! printf '%s' "$EDKEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
  # A real Sparkle key is only load-bearing for a DEVELOPER ID (auto-update) release. An
  # Apple-Development interim build (right-click→Open, handed out manually — no Sparkle feed yet)
  # or an unsigned smoke-test can proceed with the placeholder.
  case "${DEVELOPER_ID_APP:-}" in
    "Developer ID"*)
      echo "✗ SUPublicEDKey is missing/placeholder ('$EDKEY') — REQUIRED for a Developer ID release."
      echo "  Run generate_keys (see docs/APPLE-DEVELOPER-RELEASE.md), paste the public key into"
      echo "  project.yml SUPublicEDKey, re-run xcodegen, then package again."
      exit 1 ;;
    *)
      echo "⚠️  SUPublicEDKey is a placeholder — OK for an unsigned or Apple-Development interim build"
      echo "   (no Sparkle auto-update yet); a real key is REQUIRED before a notarized Developer ID release." ;;
  esac
fi

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  echo "▶︎ Signing embedded Sparkle helpers (bottom-up, NO --deep)…"
  SP="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SP" ]; then
    SPC="$SP/Versions/Current"
    # Downloader.xpc keeps its own entitlements (a flat re-sign breaks downloads
    # on Sparkle 2.6+).  Installer.xpc / Autoupdate / Updater.app are plain.
    [ -e "$SPC/XPCServices/Downloader.xpc" ] && codesign --force --options runtime --timestamp \
      --preserve-metadata=entitlements --sign "$DEVELOPER_ID_APP" "$SPC/XPCServices/Downloader.xpc"
    [ -e "$SPC/XPCServices/Installer.xpc" ] && codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID_APP" "$SPC/XPCServices/Installer.xpc"
    [ -e "$SPC/Autoupdate" ] && codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID_APP" "$SPC/Autoupdate"
    [ -e "$SPC/Updater.app" ] && codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID_APP" "$SPC/Updater.app"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$SP"   # framework binary last
    echo "  ✓ Sparkle helpers signed"
  fi
  echo "▶︎ Signing the app (Hardened Runtime + entitlements)…"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APP" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"   # --deep OK for VERIFY (catches a mis-signed helper)
  echo "  ✓ signed"
else
  echo "⚠️  DEVELOPER_ID_APP unset — UNSIGNED build (skipping notarization). For a"
  echo "   distributable build set DEVELOPER_ID_APP + NOTARY_PROFILE (see header)."
fi

echo "▶︎ Building DMG…"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# Ship the uninstaller in the DMG so a user can cleanly remove the app + all its data
# (App Support, prefs, Keychain) without hunting through ~/Library. See docs/APPLE-DEVELOPER-RELEASE.md.
cp "$ROOT/scripts/uninstall-bridge.command" "$STAGING/Uninstall Airlive Bridge.command"
chmod +x "$STAGING/Uninstall Airlive Bridge.command"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "  ✓ $DMG"

if [ -n "${DEVELOPER_ID_APP:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▶︎ Notarizing (this can take a few minutes)…"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "  ✓ notarized + stapled — ready to ship: $DMG"

  # EdDSA-sign the FINAL stapled DMG (stapling changes the bytes, so this MUST be
  # last).  Prints  sparkle:edSignature="…" length="…"  → paste into the appcast
  # <enclosure> for this release (or let generate_appcast write the whole feed).
  echo "▶︎ EdDSA-signing the DMG for the appcast…"
  SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
  if [ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN/sign_update" ]; then
    "$SPARKLE_BIN/sign_update" "$DMG"
    echo "  ^ paste edSignature + length into the appcast <enclosure> (see docs/RELEASE.md)."
  else
    echo "  ! Sparkle bin tools not found — run sign_update manually on $DMG."
  fi
elif [ -n "${DEVELOPER_ID_APP:-}" ]; then
  echo "⚠️  NOTARY_PROFILE unset — signed but NOT notarized. Gatekeeper will warn on"
  echo "   other Macs. Set NOTARY_PROFILE to notarize."
fi

echo "Done."
