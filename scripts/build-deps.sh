#!/usr/bin/env bash
# build-deps.sh — build the third-party C static libs (libcrypto, libplist) that the
# AirPlay receiver links, targeting macOS 13 so the shipped app is warning-clean and
# runs on every supported OS.
#
# WHY not Homebrew's static libs: Homebrew builds for the HOST OS (e.g. macOS 26), so
# linking them into our 13.0-target app floods the link with "object file was built
# for newer macOS 26 than being linked (13.0)" warnings. They're pure-C and run on 13
# anyway, but a distributable should be clean and metadata-correct. We rebuild them
# from source at -mmacosx-version-min=13.0.
#
# Prereqs (Homebrew):  brew install autoconf automake libtool pkg-config
# Output (gitignored, like Vendor/airplay-lib):
#   Vendor/deps/lib/{libcrypto.a, libplist-2.0.a}
#   Vendor/deps/include/{openssl/*, plist/*}
# Re-run after bumping a version below.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/Vendor/deps"
WORK="$ROOT/.build/deps"
MIN_MACOS="13.0"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
JOBS="$(sysctl -n hw.ncpu)"

# Pinned to match the Homebrew versions this was developed against.
OPENSSL_VER="3.6.2"
LIBPLIST_VER="2.7.0"

mkdir -p "$DEPS/lib" "$DEPS/include" "$WORK"

# ---- OpenSSL (libcrypto only) -------------------------------------------------
openssl_tar="$WORK/openssl-$OPENSSL_VER.tar.gz"
openssl_src="$WORK/openssl-$OPENSSL_VER"
if [ ! -f "$openssl_tar" ]; then
  echo "▶︎ Downloading OpenSSL $OPENSSL_VER…"
  curl -fsSL -o "$openssl_tar" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
fi
rm -rf "$openssl_src"; tar -xzf "$openssl_tar" -C "$WORK"
echo "▶︎ Configuring OpenSSL (darwin64-arm64, min macOS $MIN_MACOS, static)…"
( cd "$openssl_src"
  ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps \
    "-mmacosx-version-min=$MIN_MACOS" >/dev/null
  echo "▶︎ Building libcrypto.a…"
  make -j"$JOBS" build_libs >/dev/null )
cp "$openssl_src/libcrypto.a" "$DEPS/lib/"
rm -rf "$DEPS/include/openssl"; cp -R "$openssl_src/include/openssl" "$DEPS/include/openssl"

# ---- libplist -----------------------------------------------------------------
plist_tar="$WORK/libplist-$LIBPLIST_VER.tar.bz2"
plist_src="$WORK/libplist-$LIBPLIST_VER"
if [ ! -f "$plist_tar" ]; then
  echo "▶︎ Downloading libplist $LIBPLIST_VER…"
  curl -fsSL -o "$plist_tar" \
    "https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VER/libplist-$LIBPLIST_VER.tar.bz2"
fi
rm -rf "$plist_src"; tar -xjf "$plist_tar" -C "$WORK"
echo "▶︎ Configuring libplist (min macOS $MIN_MACOS, static, no python)…"
( cd "$plist_src"
  [ -x ./configure ] || ./autogen.sh >/dev/null 2>&1 || true
  ./configure --enable-static --disable-shared --without-cython \
    CFLAGS="-mmacosx-version-min=$MIN_MACOS" >/dev/null
  echo "▶︎ Building libplist-2.0.a…"
  make -j"$JOBS" >/dev/null )
cp "$plist_src/src/.libs/libplist-2.0.a" "$DEPS/lib/"
rm -rf "$DEPS/include/plist"; cp -R "$plist_src/include/plist" "$DEPS/include/plist"

echo "✅ built into $DEPS/lib:"
ls -1 "$DEPS/lib"
echo "▶︎ deployment-target check (want 'minos 13.0'):"
otool -l "$DEPS/lib/libcrypto.a" 2>/dev/null | grep -m1 -A2 LC_BUILD_VERSION | grep minos || \
  echo "  (no LC_BUILD_VERSION — older archive format, check a member with: otool -l)"
