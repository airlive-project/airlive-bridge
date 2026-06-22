// Auth.swift — Airlive Bridge receiver-password authentication.
//
// STANDALONE COPY of AirliveCore/Sources/AirliveCore/Auth.swift (the FROZEN wire
// contract, 2026-06-22) — see docs/STREAM-AUTH-SPEC.md.  Bridge must never link
// the airlive repo, so the canonical tag definition is duplicated here BIT-FOR-BIT:
// four codebases (camera, Studio, Bridge, OBS plugin) must compute the same HMAC
// or the handshake won't interoperate.  If the spec ever changes, change it there
// first and re-sync this file by hand.
//
// Threat model (deliberately narrow): the LAN stream is NOT secret — anyone may
// watch the open video.  The one real threat is a same-LAN prankster occupying a
// channel slot or injecting a fake feed into a multiview.  That is ACCESS control,
// not confidentiality, so there is deliberately NO TLS.  We only prove "the peer
// connecting is one of ours."
//
// Properties: the password NEVER crosses the wire (only an HMAC of a one-time
// nonce); the nonce is single-use (a captured response can't be replayed); exactly
// ONE HMAC per connection, before any video — zero per-frame cost, no thermal hit.

import Foundation
import CryptoKit

enum AirliveAuth {

    /// Bytes in a challenge nonce and in a response tag — SHA-256 output size.
    static let tagLength = 32

    /// A fresh single-use random nonce for an `authChallenge` (RECEIVER side).
    /// `SecRandomCopyBytes` is the system CSPRNG; the `SystemRandomNumberGenerator`
    /// fallback is also cryptographically secure on Apple platforms.
    static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: tagLength)
        if SecRandomCopyBytes(kSecRandomDefault, tagLength, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = .random(in: .min ... .max, using: &rng) }
        }
        return Data(bytes)
    }

    /// THE canonical response tag (camera side; Bridge uses it only in tests /
    /// mocks): `HMAC-SHA256` with key = the password's UTF-8 bytes, message = the
    /// raw nonce → raw 32 bytes.  No normalization, no KDF, no salt; raw bytes on
    /// the wire (never hex/base64).
    static func response(password: String, nonce: Data) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: nonce, using: key))
    }

    /// Verify a response (RECEIVER side).  `isValidAuthenticationCode` is
    /// CONSTANT-TIME (no byte-by-byte timing leak) and length-safe (a tag that
    /// isn't 32 bytes simply fails) — never compare tags with `==`.
    static func verify(tag: Data, password: String, nonce: Data) -> Bool {
        let key = SymmetricKey(data: Data(password.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: nonce, using: key)
    }
}

/// Why a receiver rejected (or could not start) an authenticated connection.
/// Wire value is the snake_case `rawValue` inside the `AuthResult` JSON — must
/// match AirliveCore exactly so the camera decodes it.
enum AuthReason: String, Codable, Sendable {
    /// Receiver needs a password but the camera sent none/blank → camera PROMPTS.
    case authRequired = "auth_required"
    /// The HMAC didn't match (wrong password) → camera clears its cache + re-prompts.
    case authFailed   = "auth_failed"
}

/// Result of the handshake, sent receiver → camera as the `authResult` packet
/// (JSON).  `ok == true` → proceed to `formatDescription` / `sample`; otherwise
/// the receiver closes the connection with a clean FIN right after sending this.
struct AuthResult: Codable, Sendable {
    var ok: Bool
    var reason: AuthReason?

    init(ok: Bool, reason: AuthReason? = nil) {
        self.ok = ok
        self.reason = reason
    }

    static let success = AuthResult(ok: true)
    static func failure(_ reason: AuthReason) -> AuthResult { AuthResult(ok: false, reason: reason) }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(from data: Data) -> AuthResult? {
        try? JSONDecoder().decode(AuthResult.self, from: data)
    }
}
