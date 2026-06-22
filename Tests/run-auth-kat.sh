#!/bin/bash
# Compile + run the receiver-password KAT against the real Sources/Wire/Auth.swift.
# Self-contained: no XCTest target needed. Exit 0 = pass, non-zero = fail.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t airlive-auth-kat)"
trap 'rm -f "$BIN"' EXIT
xcrun --sdk macosx swiftc -target arm64-apple-macos13.0 \
  Sources/Wire/Auth.swift Tests/AuthKAT/main.swift -o "$BIN"
"$BIN"
