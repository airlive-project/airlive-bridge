#!/usr/bin/env bash
# make-icon.sh — turn a single 1024×1024 PNG into the macOS AppIcon set.
#
#   ./scripts/make-icon.sh path/to/airlive-bridge-1024.png
#
# Generates every required size into Sources/Assets.xcassets/AppIcon.appiconset and
# rewrites its Contents.json with the filenames, so the next build embeds the icon.
# Then run `xcodegen` (no-op for assets) and rebuild.

set -euo pipefail

SRC="${1:-}"
if [ ! -f "$SRC" ]; then
  echo "usage: $0 path/to/icon-1024.png  (a square PNG, ideally 1024×1024)"
  exit 1
fi

SET="$(cd "$(dirname "$0")/.." && pwd)/Sources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

gen() { # gen <pixels>
  sips -z "$1" "$1" "$SRC" --out "$SET/icon_$1.png" >/dev/null
  echo "  ✓ icon_$1.png"
}
echo "Generating icon sizes from $SRC →"
for px in 16 32 64 128 256 512 1024; do gen "$px"; done

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Done. Rebuild to embed the icon."
