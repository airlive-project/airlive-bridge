// OutputSettings.swift — Bridge output latency presets.
//
// Ported from AirliveStudioApp/Sources/OutputSettings.swift, trimmed to only
// `LatencyPreset` — the +0/+120/+200/+400 ms jitter-buffer presets that the
// operator applies to a channel's downstream output.  Studio's resolution /
// bitrate / recording-folder machinery is YouTube-streamer-specific and not
// part of Bridge's foundation; it can be added per-output later if needed.

import Foundation

/// System latency presets, expressed in MILLISECONDS (not frames — a 30 fps and
/// a 60 fps camera held to the same delay must line up; frame-count presets
/// silently desync mixed-rate sources).
///
/// Every value is a REAL shipping industry standard, not an invented round
/// number:
///   • 0   — WebRTC playout-delay `min=0` ("render ASAP"); OBS
///           `async_unbuffered`.
///   • 120 — SRT's default `SRTO_LATENCY` (the industry's standard
///           fixed-latency default); also ≈ NDI's ~5-frame buffer.
///   • 200 — top of WebRTC's "interactive streaming" target band
///           (100–200 ms).
///   • 400 — WebRTC's "buffer against glitches" / one-way target.
enum LatencyPreset: Int, CaseIterable, Identifiable {
    case lowest = 0      // WebRTC min=0 / OBS unbuffered — wired / strong 5 GHz
    case normal = 120    // SRT default — the standard fixed-latency baseline
    case smooth = 200    // WebRTC interactive upper bound — busy Wi-Fi
    case safe   = 400    // WebRTC buffer-against-glitches — hostile network

    var id: Int { rawValue }

    /// Picker label.  The value is shown as "+N ms" because it is the buffer
    /// ADDED on top of the pipeline's own unavoidable latency (capture →
    /// encode → network → decode → display) — there is no true 0 ms total, so
    /// "Lowest (+0 ms)" = "add nothing, show on decode", not "zero latency".
    /// Honest by construction.
    var label: String {
        switch self {
        case .lowest: return "Lowest (+0 ms)"
        case .normal: return "Normal (+120 ms)"
        case .smooth: return "Smooth (+200 ms)"
        case .safe:   return "Safe (+400 ms)"
        }
    }

    /// Same value as seconds, for the receiver's PTS / jitter-buffer math.
    var seconds: Double { Double(rawValue) / 1000.0 }
}
