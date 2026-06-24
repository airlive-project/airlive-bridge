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
STAGE="$ROOT/build/uxplay-src"
BUILD="$ROOT/build/airplay-lib"
OUT="$ROOT/Vendor/airplay-lib"
rm -rf "$STAGE" "$BUILD"; mkdir -p "$STAGE"
cp -R "$UX/." "$STAGE/"
sed -i '' '/add_subdirectory( renderers )/,$d' "$STAGE/CMakeLists.txt"

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
