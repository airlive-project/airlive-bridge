#!/usr/bin/env bash
# bundle-libsrt.sh — make Airlive Bridge self-contained for SRT output.
#
# Copies libsrt (+ the non-system dylibs it needs) into the app's Contents/Frameworks,
# rewrites their load paths to @loader_path, restamps them to the app's deployment
# floor, and signs them (ad-hoc by default; pass a Developer ID for a release). After
# this the app carries its own libsrt, so SRT works with NO `brew install srt` on the
# user's machine — libndi stays external on purpose (NDI's license forbids bundling).
#
# Run BEFORE the app is codesigned/sealed (package.sh does exactly that).
#   ./scripts/bundle-libsrt.sh "/path/to/Airlive Bridge.app" [SIGN_ID]
#
# Prereqs on the BUILD machine only: `brew install srt dylibbundler`.
set -euo pipefail

APP="${1:?path to the .app bundle}"
SIGN_ID="${2:-${SIGN_ID:--}}"       # default ad-hoc "-"; a Developer ID Application for release
MIN_MACOS="13.0"                     # match scripts/build-deps.sh (the app's other bundled deps)
FW="$APP/Contents/Frameworks"
SRC="$(ls /opt/homebrew/lib/libsrt.1.dylib /opt/homebrew/lib/libsrt.dylib \
          /usr/local/lib/libsrt.1.dylib /usr/local/lib/libsrt.dylib 2>/dev/null | head -1 || true)"

[ -d "$APP" ]           || { echo "✗ not an app bundle: $APP" >&2; exit 1; }
[ -n "${SRC:-}" ]       || { echo "✗ no libsrt on this machine — 'brew install srt' first" >&2; exit 1; }
command -v dylibbundler >/dev/null || { echo "✗ dylibbundler missing — 'brew install dylibbundler'" >&2; exit 1; }

mkdir -p "$FW"
cp "$SRC" "$FW/libsrt.dylib"; chmod u+w "$FW/libsrt.dylib"

echo "▶︎ Bundling libsrt + its deps into $FW …"
dylibbundler -of -b -x "$FW/libsrt.dylib" -d "$FW" -p '@loader_path/' >/dev/null

# dylibbundler fixes the IDs of the DEPS it bundles, but not the -x target's own id, so
# libsrt keeps its Homebrew LC_ID_DYLIB. Harmless for a dlopen'd lib (loaded by path, not
# id) but untidy + it trips the leak-check below. Normalize every bundled dylib's id.
shopt -s nullglob
for f in "$FW"/*.dylib; do install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true; done
shopt -u nullglob

echo "▶︎ Restamping bundled SRT dylibs to macOS $MIN_MACOS + signing …"
# Only the loose *.dylib files dylibbundler dropped in Frameworks (libsrt + openssl…);
# a nested framework like Sparkle.framework is a directory, so it's untouched.
shopt -s nullglob
for f in "$FW"/*.dylib; do
  vtool -set-build-version macos "$MIN_MACOS" "$MIN_MACOS" -replace -output "$f" "$f" >/dev/null 2>&1 || true
  codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || { echo "✗ sign failed: $f" >&2; exit 1; }
done
shopt -u nullglob

echo "▶︎ Verifying self-containment (no Homebrew refs, minos ≤ $MIN_MACOS) …"
shopt -s nullglob
for f in "$FW"/*.dylib; do
  leak="$(otool -L "$f" | grep -E '/opt/homebrew|/usr/local/Cellar' || true)"
  [ -z "$leak" ] || { echo "✗ $(basename "$f") still references Homebrew:"; echo "$leak"; exit 1; }
done
shopt -u nullglob
echo "  ✓ libsrt bundled from $(basename "$SRC") — SRT now works without Homebrew."
