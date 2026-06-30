// BridgeProfile.swift — a saved Bridge setup (channels + outputs + mode).
//
// Serialises the operator's whole configuration to a portable `.airliveprofile`
// JSON so a show can be reopened exactly as it was built: every channel (kind,
// name, order, capture-device id, delay + extra-delay, preview toggle) and every
// program output (kind, label, config, RTSP port).
//
// What is deliberately NOT saved:
//   • LIVE state — connections and which outputs are running.  A loaded profile
//     rebuilds channels as fresh receiver slots (the iPhone reconnects by the
//     PRESERVED channel id) and brings outputs back OFF; the operator connects
//     phones / toggles outputs on exactly as before.  A restored output must
//     never auto-publish.
//   • The Bridge password — it lives in the Keychain, Bridge-global, independent
//     of any profile.  A profile file must be safe to share without leaking a
//     secret, so no password (or even a "require" flag) goes in it.

import Foundation
import UniformTypeIdentifiers

/// File extension + document type for the profile file.
enum BridgeProfileDocument {
    static let fileExtension = "airliveprofile"
    /// A dynamic UTType derived from the extension (falls back to JSON if the
    /// system can't synthesise one).  Used by the open/save panels.
    static var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .json }
}

/// A persisted Bridge configuration.  `version` lets a future format change stay
/// backward-readable; today only v1 exists.
struct BridgeProfile: Codable {
    var version = 1
    var mode: String                      // AppMode.rawValue ("multiview" / "solo")
    var channels: [ChannelConfig]
    var outputs: [OutputConfig]

    /// One channel's persisted layout (no live connection).
    struct ChannelConfig: Codable {
        var id: UUID                      // preserved so a phone reconnects to the same slot
        var name: String
        var kind: String                  // ChannelKind.rawValue
        var captureDeviceID: String?      // .capture channels only
        var delayRaw: Int                 // LatencyPreset.rawValue (the enum is Int-backed)
        var extraDelayMs: Int
        var previewEnabled: Bool
    }

    /// One program output's persisted layout (restored OFF).
    struct OutputConfig: Codable {
        var kind: String                  // OutputKind.rawValue
        var label: String
        var config: String                // transport config (e.g. SRT destination)
        var port: Int?                    // RTSP serving port (nil for the others)
    }

    // MARK: - File I/O

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> BridgeProfile {
        try JSONDecoder().decode(BridgeProfile.self, from: Data(contentsOf: url))
    }
}
