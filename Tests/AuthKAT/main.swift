// AuthKAT — known-answer + behaviour test for the receiver-password crypto.
//
// Self-contained (no XCTest / test target — the repo is XcodeGen app-only).
// Run via Tests/run-auth-kat.sh, which compiles this against Sources/Wire/Auth.swift
// and executes it; exit 0 = pass, non-zero = fail (CI-friendly).
//
// The KAT pins the WIRE FORMAT: HMAC-SHA256, key = UTF-8 of the password, message
// = the raw 32-byte nonce, raw 32-byte tag.  `expectedKAT` was computed with an
// INDEPENDENT implementation (Python's hmac) so a refactor that silently changed
// the derivation (e.g. hex-encoding the nonce, normalizing the password) would be
// caught — and so the C++ OBS port can target the same vector to prove interop.

import Foundation

let password = "airlive-test"
let nonce = Data((0..<32).map { UInt8($0) })          // 0x00..0x1f
// python: hmac.new(b"airlive-test", bytes(range(32)), hashlib.sha256).hexdigest()
let expectedKAT = "f5708e4ebcf85a651f5f897323533dcf543add52d651179fbbd390124b1f4ab1"

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("  ✅ \(name)") } else { print("  ❌ \(name)"); failures += 1 }
}

let tag = AirliveAuth.response(password: password, nonce: nonce)
let hex = tag.map { String(format: "%02x", $0) }.joined()

check(hex == expectedKAT, "KAT — wire bytes match the independent HMAC reference")
check(AirliveAuth.verify(tag: tag, password: password, nonce: nonce), "round-trip verify")
check(!AirliveAuth.verify(tag: tag, password: "wrong", nonce: nonce), "wrong password rejected")
check(!AirliveAuth.verify(tag: tag.prefix(31), password: password, nonce: nonce), "short (31-byte) tag rejected")
check(!AirliveAuth.verify(tag: tag, password: password, nonce: Data(repeating: 0xAA, count: 32)), "wrong nonce rejected")
check(AirliveAuth.makeNonce().count == AirliveAuth.tagLength, "nonce is 32 bytes")
check(AirliveAuth.makeNonce() != AirliveAuth.makeNonce(), "nonce is non-constant (single-use)")

// AuthResult JSON wire shape (must match AirliveCore so the camera decodes it).
let okJSON = String(data: AuthResult.success.encoded(), encoding: .utf8) ?? ""
check(okJSON.contains("\"ok\":true"), "AuthResult success JSON")
let failJSON = String(data: AuthResult.failure(.authFailed).encoded(), encoding: .utf8) ?? ""
check(failJSON.contains("auth_failed"), "AuthResult failure reason snake_case JSON")
check(AuthResult.decode(from: AuthResult.failure(.authRequired).encoded())?.reason == .authRequired,
      "AuthResult round-trips through JSON")

if failures == 0 {
    print("ALL AUTH KAT TESTS PASSED")
    exit(0)
} else {
    print("\(failures) AUTH KAT TEST(S) FAILED")
    exit(1)
}
