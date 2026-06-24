#!/usr/bin/env bash
# run-release.sh — build + launch the Release app for TESTING (esp. AirPlay).
#
# Why not Xcode ▶: ⌘R launches Debug UNDER the debugger, and macOS then treats
# Xcode (not the app) as the responsible process for Local Network privacy — so
# Bonjour publishing (AirPlay/Airlive discovery) is denied. A standalone Release
# launch is the app's own responsible process, so the Local Network grant applies.
# Release is also Team-signed (stable TCC identity) and arm64.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

pkill -f "Airlive Bridge" 2>/dev/null || true; sleep 1
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AirliveBridge.xcodeproj -scheme AirliveBridge -configuration Release \
  -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build >/dev/null
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Airlive Bridge.app" -path "*Release*" 2>/dev/null | head -1)
open "$APP"
echo "✅ launched $APP"
echo "   (logs: Console.app, filter 'Airlive Bridge' or 'dnssd registered')"
