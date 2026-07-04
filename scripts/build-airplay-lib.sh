#!/usr/bin/env bash
# build-airplay-lib.sh — build the AirPlay receiver static lib (libairplay.a) from
# the vendored UxPlay submodule, for the Screen Mirroring channel source.
#
# UxPlay (GPLv3) is the AirPlay/RAOP + FairPlay C stack.  We build ONLY its
# `airplay` static library (+ playfair / dnssd / llhttp sublibs) — NOT the GStreamer
# `uxplay` app/renderers, which the Bridge doesn't use (it renders frames itself).
#
# Prereqs (Homebrew):  brew install cmake openssl@3 libplist
# Output:  Vendor/airplay-lib/lib/*.a  +  Vendor/airplay-lib/include/*.h
# (gitignored build artifacts; re-run after updating the submodule).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UX="$ROOT/Vendor/UxPlay"

[ -f "$UX/lib/raop.c" ] || { echo "✗ UxPlay submodule missing — run: git submodule update --init --recursive"; exit 1; }
command -v cmake >/dev/null || { echo "✗ cmake not found — brew install cmake"; exit 1; }

# Stage a copy with the GStreamer app/renderers stripped (the airplay LIB needs no
# GStreamer — only the uxplay app does).  Keeps the submodule pristine.
# Staging under .build/ (gitignored) — NOT ./build, which collided with
# `xcodebuild clean` ("Could not delete build because it was not created by the
# build system").
STAGE="$ROOT/.build/uxplay-src"
BUILD="$ROOT/.build/airplay-lib"
OUT="$ROOT/Vendor/airplay-lib"
rm -rf "$STAGE" "$BUILD"; mkdir -p "$STAGE"
cp -R "$UX/." "$STAGE/"
sed -i '' '/add_subdirectory( renderers )/,$d' "$STAGE/CMakeLists.txt"

# ── AIRLIVE PATCH (applied to the STAGED copy — the submodule stays pristine) ──
# Rotation contract (found 2026-07-04, field-proven by obs-airplay): the /info
# plist must advertise features WITH bit 8 (ScreenRotate) + bits 0/4/33-36, while
# the Bonjour TXT stays STOCK (0x5A7FFEE6, bit 8 OFF).  That split makes iOS
# re-encode the mirror upright and re-negotiate dimensions on every rotation.
#   • bit 8 in BOTH → phone streams its native portrait buffer with sideways
#     content, expecting the receiver to rotate pixels (tried; not wanted);
#   • bit 8 in NEITHER (stock) → orientation pinned at session start forever.
echo "▶︎ Applying Airlive patch to the staged copy…"
python3 - "$STAGE/lib/raop_handlers.h" <<'EOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = "uint64_t features = dnssd_get_airplay_features(raop->dnssd);"
new = ("uint64_t features = ((uint64_t) 0x1E << 32) | 0x5A7FFFF7; "
       "/* AIRLIVE: proven /info mask - see build-airplay-lib.sh */")
if old not in src:
    sys.exit("AIRLIVE PATCH FAILED: features line not found in raop_handlers.h "
             "(upstream changed?) - re-derive the patch before building")
open(path, "w").write(src.replace(old, new, 1))
print("  patched raop_handlers.h: /info features -> 0x1E:5A7FFFF7 (rotation contract)")
EOF

echo "▶︎ Configuring (lib only, macOS 13 target)…"
# Match the app's deployment target so the .a objects don't warn ("built for
# newer macOS 26 than 13"). (Homebrew libcrypto/libplist stay at their own minos.)
cmake -S "$STAGE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DNO_MARCH_NATIVE=ON \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 >/dev/null

echo "▶︎ Building airplay static lib…"
cmake --build "$BUILD" --target airplay -j"$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$OUT/lib" "$OUT/include"
find "$BUILD" -name "*.a" -exec cp {} "$OUT/lib/" \;
cp "$UX/lib/"*.h "$OUT/include/" 2>/dev/null || true

echo "✅ built into $OUT/lib:"
ls -1 "$OUT/lib"
