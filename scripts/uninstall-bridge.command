#!/bin/bash
# Uninstall Airlive Bridge — removes the app and EVERY trace it leaves, nothing else.
# Double-click to run. No admin needed (all paths are the app + the current user's
# ~/Library). Touches only "studio.airlive.bridge.*" — never other Airlive products.

set -u
BID="studio.airlive.bridge.AirliveBridge"     # the app bundle id
KC_SERVICE="studio.airlive.bridge.auth"        # the receiver-password Keychain item
APP="/Applications/Airlive Bridge.app"

echo "This removes Airlive Bridge and all its data:"
echo "  • $APP"
echo "  • ~/Library/Application Support/Airlive Bridge"
echo "  • ~/Library/Preferences/$BID.plist  (+ caches / saved state / http storages)"
echo "  • Keychain item \"$KC_SERVICE\" (the receiver password)"
echo
read -r -p "Continue? [y/N] " ans
case "$ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0;; esac

# Quit the app if it's running so the bundle can be removed cleanly.
osascript -e 'tell application "Airlive Bridge" to quit' 2>/dev/null || true
sleep 1
pkill -f "Airlive Bridge" 2>/dev/null || true

rm -rf "$APP"
rm -rf "$HOME/Library/Application Support/Airlive Bridge"
rm -f  "$HOME/Library/Preferences/$BID.plist"
rm -rf "$HOME/Library/Caches/$BID"
rm -rf "$HOME/Library/HTTPStorages/$BID" "$HOME/Library/HTTPStorages/$BID".* 2>/dev/null
rm -rf "$HOME/Library/Saved Application State/$BID.savedState"
# Flush the cfprefsd copy so the deleted plist doesn't get rewritten on next launch.
defaults delete "$BID" 2>/dev/null || true
# Receiver password (Bridge-global; safe no-op if auth was never enabled).
security delete-generic-password -s "$KC_SERVICE" >/dev/null 2>&1 || true

echo
echo "✅ Airlive Bridge fully removed."
echo "   (NDI Tools / Homebrew srt, if you installed them, are untouched — Bridge only"
echo "    read them, never owned them. Remove those yourself if you no longer need them.)"
