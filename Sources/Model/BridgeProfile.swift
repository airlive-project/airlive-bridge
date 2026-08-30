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

/// A persisted Bridge configuration.
///
/// EVERY field below decodes leniently — a missing key falls back to its default instead of
/// throwing.  Swift's synthesised decoder does the opposite: one absent key and the WHOLE
/// profile fails to read, which here means the operator's channels, their names, their device
/// links and every output's configuration silently vanish and the app comes up looking like a
/// clean install.  That is not hypothetical — this schema has already grown fields, updates now
/// install themselves, and a newer build will inevitably read an older file.  A profile that
/// loads with one setting at its default beats a profile that does not load at all.
struct BridgeProfile: Codable {
    var version = 1
    var mode: String                      // AppMode.rawValue ("multiview" / "solo")
    var channels: [ChannelConfig]
    var outputs: [OutputConfig]

    init(version: Int = 1, mode: String, channels: [ChannelConfig], outputs: [OutputConfig]) {
        self.version = version; self.mode = mode; self.channels = channels; self.outputs = outputs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "multiview"
        channels = try c.decodeIfPresent([ChannelConfig].self, forKey: .channels) ?? []
        outputs = try c.decodeIfPresent([OutputConfig].self, forKey: .outputs) ?? []
    }

    /// One channel's persisted layout (no live connection).
    struct ChannelConfig: Codable {
        var id: UUID                      // preserved so a phone reconnects to the same slot
        var name: String
        var kind: String                  // ChannelKind.rawValue
        var captureDeviceID: String?      // .capture channels only
        var delayRaw: Int                 // LatencyPreset.rawValue (the enum is Int-backed)
        var extraDelayMs: Int
        var previewEnabled: Bool

        init(id: UUID, name: String, kind: String, captureDeviceID: String?,
             delayRaw: Int, extraDelayMs: Int, previewEnabled: Bool) {
            self.id = id; self.name = name; self.kind = kind
            self.captureDeviceID = captureDeviceID
            self.delayRaw = delayRaw; self.extraDelayMs = extraDelayMs
            self.previewEnabled = previewEnabled
        }

        /// `id` and `kind` are the only fields a channel cannot be reconstructed without;
        /// everything else falls back rather than taking the profile down with it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Camera"
            captureDeviceID = try c.decodeIfPresent(String.self, forKey: .captureDeviceID)
            delayRaw = try c.decodeIfPresent(Int.self, forKey: .delayRaw) ?? LatencyPreset.normal.rawValue
            extraDelayMs = try c.decodeIfPresent(Int.self, forKey: .extraDelayMs) ?? 0
            previewEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewEnabled) ?? true
        }
    }

    /// One program output's persisted layout (restored OFF).
    struct OutputConfig: Codable {
        var kind: String                  // OutputKind.rawValue
        var label: String
        var config: String                // transport config (e.g. SRT destination)
        var port: Int?                    // RTSP serving port (nil for the others)

        init(kind: String, label: String, config: String, port: Int?) {
            self.kind = kind; self.label = label; self.config = config; self.port = port
        }

        /// Only `kind` is load-bearing — an output with no kind is not an output.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? kind.uppercased()
            config = try c.decodeIfPresent(String.self, forKey: .config) ?? ""
            port = try c.decodeIfPresent(Int.self, forKey: .port)
        }
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
